@preconcurrency import CloudKit
import Foundation

/// The SDK mutation path requires a persisted, submitted concrete attempt.
/// Provider constructs it only for separately approved finite jobs; normal
/// account setup cannot grant cleanup or clock-maintenance permission.
struct ICloudRetentionCloudKitTransport: ICloudRetentionExecutionTransport {
    let repository: ICloudRecordRepository
    let approvalID: String

    private func context() async throws -> (CKDatabase, ICloudRetentionJob) {
        try Task.checkCancellation()
        guard ICloudSyncEngineDriver.isEntitled else { throw ICloudEngineError.notEntitled }
        let before = try await repository.retentionJob(approvalID: approvalID)
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        guard fingerprint == before.approval.systemFingerprint else { throw ICloudRecordError.accountChanged }
        guard try await repository.retentionJob(approvalID: approvalID) == before else { throw ICloudRetentionJobError.jobChanged }
        let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
        let record = try await database.record(for: ICloudCloudRootCodec.recordID)
        guard try ICloudCloudRootCodec.decode(record) == .init(generation: before.approval.generation, phase: .ready, protocolVersion: 3),
              try await repository.retentionJob(approvalID: approvalID) == before else { throw ICloudRecordError.recoveryRequired }
        try Task.checkCancellation()
        return (database, before)
    }

    func prepareServerClock() async throws {
        let (database, job) = try await context()
        guard job.approval.allowsClockMaintenance, job.nextAttempt != nil else { throw ICloudRetentionJobError.approvalMismatch }
        let names: Set<String> = [ICloudRetentionQuota.recordName]
        let before = try await ICloudRetentionCloudKitMetadataTransport(repository: repository).fetch(names: names)
        let writer = try await repository.retentionWriterVersion()
        let prepared = try ICloudRetentionQuotaClock.prepare(snapshot: before, writer: writer)
        let record = try ICloudRecordCodec.encode(prepared.envelope, systemFields: prepared.systemFields, generation: before.generation)
        if prepared.systemFields != nil, record.recordChangeTag?.isEmpty != false { throw ICloudRetentionError.malformedSnapshot }
        let (_, current) = try await context()
        guard current == job else { throw ICloudRetentionJobError.jobChanged }
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard result.deleteResults.isEmpty, Set(result.saveResults.keys) == [record.recordID] else { throw ICloudRetentionError.incompleteSnapshot }
        let proof = try ICloudRetentionPointSnapshot.decode(result.saveResults, requestedNames: names, generation: before.generation)
        guard proof.records[ICloudRetentionQuota.recordName]?.envelope == prepared.envelope else { throw ICloudRetentionError.malformedSnapshot }
        let (_, after) = try await context()
        guard after == job else { throw ICloudRetentionJobError.jobChanged }
        // Re-fetch before cleanup; the returned SDK modification date alone is
        // time evidence. An uncertain clock save changes no quota reservations.
    }

    func fetch(articleRecordName: String) async throws -> ICloudRetentionPointSnapshot {
        let (_, job) = try await context()
        guard job.nextAttempt?.articleRecordName == articleRecordName else { throw ICloudRetentionJobError.approvalMismatch }
        let snapshot = try await ICloudRetentionCloudKitMetadataTransport(repository: repository)
            .fetch(names: ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: articleRecordName))
        let (_, after) = try await context()
        guard job == after else { throw ICloudRetentionJobError.jobChanged }
        return snapshot
    }

    func submit(_ batch: ICloudRetentionAtomicBatch) async throws -> [ICloudReceivedRecord] {
        let (database, job) = try await context()
        let records = try Self.records(batch, job: job)
        let ids = try batch.recordNamesToDelete.map {
            CKRecord.ID(recordName: try ICloudGenerationIdentity.recordName($0, generation: batch.generation),
                        zoneID: try ICloudGenerationZone.id(.articles, generation: batch.generation))
        }
        // Local pending intent is rechecked by the coordinator and immediately
        // before this SDK submit. Edits during the await remain captured; the
        // returned floor rebases those intents instead of acknowledging them.
        let protection = try await repository.maintenanceProtection()
        let articleKey = ICloudMaintenancePlanner.articleKey(job.nextAttempt!.articleRecordName)
        guard !protection.hasUnresolvedChanges,
              !protection.recordNames.map(ICloudMaintenancePlanner.articleKey).contains(articleKey),
              !protection.recordNames.contains(batch.recordsToSave.first { $0.envelope.kind == .retention }!.envelope.feedRecordName!) else {
            throw ICloudRetentionError.unresolvedChanges
        }
        guard try await repository.retentionJob(approvalID: approvalID) == job else { throw ICloudRetentionJobError.jobChanged }
        try Task.checkCancellation()
        let result = try await database.modifyRecords(saving: records, deleting: ids,
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        let receipts = try Self.receipts(result.saveResults, deletions: result.deleteResults, batch: batch)
        let (_, after) = try await context()
        guard after == job else { throw ICloudRetentionJobError.jobChanged }
        return receipts
    }

    static func records(_ batch: ICloudRetentionAtomicBatch, job: ICloudRetentionJob) throws -> [CKRecord] {
        try job.validate()
        guard let attempt = job.nextAttempt, attempt.stage == .submitted,
              batch.generation == job.approval.generation, attempt.operationID == batch.operationID,
              attempt.proposalDigest == batch.proposalDigest, attempt.processedRecords == batch.processedRecordCount,
              (1...3).contains(batch.recordNamesToDelete.count), (2...3).contains(batch.recordsToSave.count),
              batch.processedRecordCount == batch.recordNamesToDelete.count + batch.recordsToSave.count,
              Set(batch.recordNamesToDelete).count == batch.recordNamesToDelete.count,
              Set(batch.recordsToSave.map(\.envelope.recordName)).count == batch.recordsToSave.count else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        let hash = attempt.articleRecordName.dropFirst("article-v1:".count)
        let deletes: Set<String> = ["read-v1:" + hash, "starred-v1:" + hash, "content-v1:" + hash]
        let guardNames: Set<String> = ["retention-v1:" + hash, ICloudRetentionQuota.recordName]
        let names = Set(batch.recordsToSave.map(\.envelope.recordName))
        guard Set(batch.recordNamesToDelete).isSubset(of: deletes), guardNames.isSubset(of: names),
              names.isSubset(of: guardNames.union([ICloudRetentionUnreadPolicy.recordName])) else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        for record in batch.recordsToSave { try record.envelope.validate() }
        guard let quotaRecord = batch.recordsToSave.first(where: { $0.envelope.kind == .retentionQuota }),
              batch.recordsToSave.contains(where: { $0.envelope.kind == .retention }) else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        let budget = try ICloudRetentionQuota(envelope: quotaRecord.envelope)
        guard budget.contains(operationID: batch.operationID, processedRecords: batch.processedRecordCount) else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        return try batch.recordsToSave.map { prepared in
            guard prepared.origins.isEmpty, prepared.bodyData == nil, prepared.envelope.zone == .articles,
                  [.retention, .retentionPolicy, .retentionQuota].contains(prepared.envelope.kind),
                  let fields = prepared.systemFields, !fields.isEmpty, fields.count <= 64 * 1_024 else {
                throw ICloudRetentionError.malformedSnapshot
            }
            if prepared.envelope.kind != .retentionQuota {
                guard case .text(let nonce) = prepared.envelope.fields["writer_nonce"]?.value,
                      UUID(uuidString: nonce)?.uuidString == nonce else { throw ICloudRetentionError.malformedSnapshot }
            }
            let record = try ICloudRecordCodec.encode(prepared.envelope, systemFields: fields, generation: batch.generation)
            guard let tag = record.recordChangeTag, !tag.isEmpty, tag.utf8.count <= 4_096 else {
                throw ICloudRetentionError.malformedSnapshot // A fresh CKRecord is not a CAS guard.
            }
            return record
        }
    }

    static func receipts(_ saves: [CKRecord.ID: Result<CKRecord, any Error>],
                         deletions: [CKRecord.ID: Result<Void, any Error>],
                         batch: ICloudRetentionAtomicBatch) throws -> [ICloudReceivedRecord] {
        guard Set(batch.recordsToSave.map(\.envelope.recordName)).count == batch.recordsToSave.count,
              Set(batch.recordNamesToDelete).count == batch.recordNamesToDelete.count else {
            throw ICloudRetentionError.malformedSnapshot
        }
        let expected = try Dictionary(uniqueKeysWithValues: batch.recordsToSave.map {
            (try ICloudRecordCodec.recordID($0.envelope, generation: batch.generation), $0.envelope)
        })
        let deleted = try Set(batch.recordNamesToDelete.map {
            CKRecord.ID(recordName: try ICloudGenerationIdentity.recordName($0, generation: batch.generation),
                        zoneID: try ICloudGenerationZone.id(.articles, generation: batch.generation))
        })
        guard Set(saves.keys) == Set(expected.keys), Set(deletions.keys) == deleted else {
            throw ICloudRetentionError.incompleteSnapshot
        }
        for result in deletions.values { try result.get() }
        return try saves.map { id, result in
            let record = try result.get()
            let received = try ICloudRecordCodec.received(record, generation: batch.generation)
            guard record.recordID == id, received.envelope == expected[id],
                  let tag = record.recordChangeTag, !tag.isEmpty,
                  let created = record.creationDate, let modified = record.modificationDate,
                  created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 >= 0,
                  modified.timeIntervalSince1970.isFinite, modified >= created else {
                throw ICloudRetentionError.malformedSnapshot
            }
            return received
        }
    }
}
