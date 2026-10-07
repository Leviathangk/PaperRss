import Foundation

public struct ICloudRetentionOutcomeReviewResult: Sendable, Equatable {
    public let checkedOperations: Int
    public let confirmedOperations: Int
    public let unresolvedOperations: Int
    public let remainingOperations: Int
}

enum ICloudRetentionOutcomeEvidence: Sendable {
    case unresolved
    case confirmed([ICloudReceivedRecord])
}

enum ICloudRetentionOutcomeVerifier {
    static func inspect(job: ICloudRetentionJob, attempt: ICloudRetentionJob.Attempt,
                        snapshot: ICloudRetentionPointSnapshot) throws -> ICloudRetentionOutcomeEvidence {
        try job.validate()
        guard job.attempts.contains(attempt), attempt.stage == .submitted || attempt.stage == .needsReview else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        let names = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: attempt.articleRecordName)
        try snapshot.validate(requested: names, generation: job.approval.generation)
        guard let quotaRecord = snapshot.records[ICloudRetentionQuota.recordName] else { return .unresolved }
        let quota = try ICloudRetentionQuotaSnapshot(metadata: quotaRecord, generation: snapshot.generation)
        guard let reservation = quota.quota.reservations.first(where: { $0.operationID == attempt.operationID }) else {
            // Expiration, query absence and an empty article group say nothing
            // definitive about this original request's outcome.
            return .unresolved
        }
        guard reservation.processedRecords == attempt.processedRecords else { throw ICloudRetentionError.malformedSnapshot }
        let fenceName = "retention-v1:" + attempt.articleRecordName.dropFirst("article-v1:".count)
        guard let marker = snapshot.records[fenceName],
              case .text(let nonce) = marker.envelope.fields["writer_nonce"]?.value,
              UUID(uuidString: nonce)?.uuidString == nonce else { throw ICloudRetentionError.incompleteSnapshot }
        let fence = try ICloudRetentionFence(envelope: marker.envelope, generation: snapshot.generation)
        guard fence.readFloor != nil || fence.starredFloor != nil || fence.contentFloor != nil else {
            throw ICloudRetentionError.incompleteSnapshot
        }
        if let policy = snapshot.records[ICloudRetentionUnreadPolicy.recordName] {
            _ = try ICloudRetentionUnreadPolicy(envelope: policy.envelope, generation: snapshot.generation)
        }
        return .confirmed(snapshot.records.values.filter {
            [.retention, .retentionPolicy, .retentionQuota].contains($0.envelope.kind)
        }.map { .init(envelope: $0.envelope, systemFields: $0.systemFields) })
    }
}

protocol ICloudRetentionOutcomeReading: Sendable {
    func fetch(attempt: ICloudRetentionJob.Attempt) async throws -> ICloudRetentionPointSnapshot
}

/// This adapter exposes only point reads. It cannot refresh a quota clock,
/// submit a cleanup group, repair a record, bootstrap zones or download assets.
struct ICloudRetentionOutcomeCloudKitReader: ICloudRetentionOutcomeReading {
    let repository: ICloudRecordRepository
    let approvalID: String

    func fetch(attempt: ICloudRetentionJob.Attempt) async throws -> ICloudRetentionPointSnapshot {
        try Task.checkCancellation()
        let job = try await repository.retentionJob(approvalID: approvalID, requiresExecutionAuthorization: false)
        guard job.attempts.contains(attempt), attempt.stage == .submitted || attempt.stage == .needsReview else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        let snapshot = try await ICloudRetentionCloudKitMetadataTransport(repository: repository).fetch(
            names: ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: attempt.articleRecordName))
        try Task.checkCancellation()
        guard try await repository.retentionJob(approvalID: approvalID, requiresExecutionAuthorization: false) == job else {
            throw ICloudRetentionJobError.jobChanged
        }
        return snapshot
    }
}

actor ICloudRetentionOutcomeReviewer {
    private let repository: ICloudRecordRepository
    private var running = false
    private var lifecycle = 0
    private var cursor: (approvalID: String, operationID: String)?
    init(repository: ICloudRecordRepository) { self.repository = repository }
    func stop() { lifecycle &+= 1 }

    func review(approvalID: String, using reader: any ICloudRetentionOutcomeReading,
                isCurrent: @escaping @Sendable () async throws -> Bool = { true }) async throws -> ICloudRetentionOutcomeReviewResult {
        guard !running else { throw ICloudRetentionJobError.jobChanged }
        running = true; defer { running = false }
        let epoch = lifecycle
        var job = try await repository.retentionJob(approvalID: approvalID, requiresExecutionAuthorization: false)
        try await check(job, epoch: epoch, isCurrent: isCurrent)
        let attempts = job.attempts.filter { $0.stage == .submitted || $0.stage == .needsReview }
        guard !attempts.isEmpty else { return .init(checkedOperations: 0, confirmedOperations: 0, unresolvedOperations: 0, remainingOperations: 0) }
        let ordered: [ICloudRetentionJob.Attempt]
        if let cursor, cursor.approvalID == approvalID,
           let index = job.attempts.firstIndex(where: { $0.operationID == cursor.operationID }) {
            let later = job.attempts.dropFirst(index + 1).filter { $0.stage == .submitted || $0.stage == .needsReview }
            ordered = later.isEmpty ? attempts : Array(later)
        } else { ordered = attempts }
        let lease = try ICloudCloudResetLease(repository: repository)
        defer { withExtendedLifetime(lease) {} }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var checked = 0, confirmed = 0
        for attempt in ordered.prefix(10) {
            guard ContinuousClock.now < deadline else { break }
            try await check(job, epoch: epoch, isCurrent: isCurrent)
            let snapshot = try await reader.fetch(attempt: attempt)
            try await check(job, epoch: epoch, isCurrent: isCurrent)
            let evidence = try ICloudRetentionOutcomeVerifier.inspect(job: job, attempt: attempt, snapshot: snapshot)
            checked += 1
            if case .confirmed(let guards) = evidence {
                // Receive floors before the CAS stage update. A crash/failure
                // keeps the old attempt for an idempotent read-only recheck.
                try repository.receive(guards)
                try await check(job, epoch: epoch, isCurrent: isCurrent)
                job = try await repository.acceptReviewedRetentionOutcome(expected: job, attempt: attempt, snapshot: snapshot)
                confirmed += 1
            }
            cursor = (approvalID, attempt.operationID)
        }
        return .init(checkedOperations: checked, confirmedOperations: confirmed,
                     unresolvedOperations: checked - confirmed, remainingOperations: attempts.count - checked)
    }

    private func check(_ job: ICloudRetentionJob, epoch: Int,
                       isCurrent: @Sendable () async throws -> Bool) async throws {
        try Task.checkCancellation()
        guard epoch == lifecycle, try await isCurrent() else { throw CancellationError() }
        guard try await repository.retentionJob(approvalID: job.approval.approvalID, requiresExecutionAuthorization: false) == job,
              !(try await repository.retentionScheduleState(approvalID: job.approval.approvalID).enabled) else {
            throw ICloudRetentionJobError.jobChanged
        }
        try Task.checkCancellation()
        guard epoch == lifecycle else { throw CancellationError() }
    }
}
