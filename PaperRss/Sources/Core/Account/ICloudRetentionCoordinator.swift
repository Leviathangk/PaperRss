import Foundation

/// Executes at most one reviewed article per call. Construction and ordinary
/// sync cannot enable it. The scheduler requires a separately reviewed finite job.
actor ICloudRetentionCoordinator {
    let repository: ICloudRecordRepository
    private var running = false
    private var lifecycle = 0

    init(repository: ICloudRecordRepository) { self.repository = repository }
    func stop() { lifecycle &+= 1 }

    func executeNext(approvalID: String, using transport: any ICloudRetentionExecutionTransport,
                     isCurrent: @escaping @Sendable () async throws -> Bool = { true }) async throws -> ICloudRetentionJob {
        guard !running else { throw ICloudRetentionJobError.jobChanged }
        running = true
        defer { running = false }
        let epoch = lifecycle
        var job = try await repository.retentionJob(approvalID: approvalID)
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        guard let attempt = job.nextAttempt else { return job }
        // Share the account's kernel lease with reset execution. Cancellation
        // does not release it while a server request is still awaited.
        let lease = try ICloudCloudResetLease(repository: repository)
        defer { withExtendedLifetime(lease) {} }
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        try await transport.prepareServerClock()
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        let snapshot = try await transport.fetch(articleRecordName: attempt.articleRecordName)
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        guard snapshot.generation == job.approval.generation else { throw ICloudRetentionError.wrongGeneration }
        let protection = try await repository.maintenanceProtection()
        let writer = try await repository.retentionWriterVersion()
        let decision = try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: snapshot,
            articleRecordName: attempt.articleRecordName, protection: protection,
            operationID: attempt.operationID, observedClock: writer.counter, deviceID: writer.deviceID)
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        switch decision {
        case .alreadyAccepted(let count):
            guard attempt.stage == .submitted, attempt.processedRecords == count else { throw ICloudRetentionJobError.needsReview }
            try receiveGuards(snapshot.records.values.map { .init(envelope: $0.envelope, systemFields: $0.systemFields) })
            return try await finish(job, attempt: attempt, stage: .accepted)
        case .noCandidate:
            return try await finish(job, attempt: attempt, stage: attempt.stage == .submitted ? .needsReview : .skipped)
        case .prepared(let batch):
            if attempt.stage == .submitted {
                guard attempt.proposalDigest == batch.proposalDigest, attempt.processedRecords == batch.processedRecordCount else {
                    return try await finish(job, attempt: attempt, stage: .needsReview)
                }
            } else {
                var next = job
                let index = next.attempts.firstIndex { $0.operationID == attempt.operationID }!
                next.attempts[index].stage = .submitted
                next.attempts[index].proposalDigest = batch.proposalDigest
                next.attempts[index].processedRecords = batch.processedRecordCount
                job = try await repository.storeRetentionJob(next, replacing: job)
            }
            try await check(job, epoch: epoch, isCurrent: isCurrent)
            let latestProtection = try await repository.maintenanceProtection()
            guard !latestProtection.hasUnresolvedChanges,
                  Set(latestProtection.recordNames.map(ICloudMaintenancePlanner.articleKey)).isDisjoint(with:
                    batch.recordNamesToDelete.map(ICloudMaintenancePlanner.articleKey)),
                  !latestProtection.recordNames.contains(batch.recordsToSave.first { $0.envelope.kind == .retention }!.envelope.feedRecordName!) else {
                throw ICloudRetentionError.unresolvedChanges
            }
            try await check(job, epoch: epoch, isCurrent: isCurrent)
            let receipts = try await transport.submit(batch)
            try await check(job, epoch: epoch, isCurrent: isCurrent)
            // Never accept an omitted, substituted or partial fake/SDK receipt.
            guard receipts.count == batch.recordsToSave.count,
                  Set(receipts.map(\.envelope.recordName)) == Set(batch.recordsToSave.map(\.envelope.recordName)),
                  receipts.allSatisfy({ receipt in batch.recordsToSave.contains { $0.envelope == receipt.envelope } }) else {
                throw ICloudRetentionError.incompleteSnapshot
            }
            try receiveGuards(receipts)
            return try await finish(job, attempt: job.attempts.first { $0.operationID == attempt.operationID }!, stage: .accepted)
        }
    }

    private func check(_ job: ICloudRetentionJob, epoch: Int, isCurrent: @Sendable () async throws -> Bool) async throws {
        try Task.checkCancellation()
        guard epoch == lifecycle, try await isCurrent() else { throw CancellationError() }
        guard try await repository.retentionJob(approvalID: job.approval.approvalID) == job else { throw ICloudRetentionJobError.jobChanged }
        try Task.checkCancellation()
        guard epoch == lifecycle else { throw CancellationError() }
    }
    private func finish(_ job: ICloudRetentionJob, attempt: ICloudRetentionJob.Attempt,
                        stage: ICloudRetentionJob.Attempt.Stage) async throws -> ICloudRetentionJob {
        var next = job
        next.attempts[next.attempts.firstIndex { $0.operationID == attempt.operationID }!].stage = stage
        return try await repository.storeRetentionJob(next, replacing: job)
    }
    private func receiveGuards(_ records: [ICloudReceivedRecord]) throws {
        // Floors first are handled atomically by receive; new local intents are
        // rebased. The cleaner does not remove local articles, states or AI.
        try repository.receive(records.filter { [.retention, .retentionPolicy, .retentionQuota].contains($0.envelope.kind) })
    }
}
