import Foundation

/// A concrete conditional batch is still not an approval or an executed delete.
/// All three article IDs must have a point-read result; query omissions are not
/// sufficient. The future executor must recheck its durable approval and local
/// protection, then submit these saves/deletes atomically in the Articles zone.
struct ICloudRetentionAtomicBatch: Sendable {
    let generation: String
    let operationID: String
    let recordsToSave: [ICloudPreparedRecord]
    let recordNamesToDelete: [String]
    let processedRecordCount: Int
    let proposalDigest: String
}

enum ICloudRetentionBatchDecision: Sendable {
    case noCandidate
    case alreadyAccepted(processedRecords: Int)
    case prepared(ICloudRetentionAtomicBatch)
}

enum ICloudRetentionAtomicBatchPlanner {
    static func requestedNames(articleRecordName: String) throws -> Set<String> {
        let prefix = "article-v1:"
        guard articleRecordName.hasPrefix(prefix) else { throw ICloudRetentionError.malformedSnapshot }
        let hash = articleRecordName.dropFirst(prefix.count)
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ICloudRetentionError.malformedSnapshot
        }
        return ["read-v1:" + hash, "starred-v1:" + hash, "content-v1:" + hash,
                "retention-v1:" + hash, ICloudRetentionQuota.recordName, ICloudRetentionUnreadPolicy.recordName]
    }

    static func prepare(snapshot: ICloudRetentionPointSnapshot, articleRecordName: String,
                        protection: ICloudMaintenanceProtection, operationID: String,
                        observedClock: Int64, deviceID: String) throws -> ICloudRetentionBatchDecision {
        let expected = try requestedNames(articleRecordName: articleRecordName)
        try ICloudCloudRoot(generation: snapshot.generation, phase: .ready, protocolVersion: 3).validate()
        guard UUID(uuidString: operationID)?.uuidString == operationID, observedClock >= 0,
              UUID(uuidString: deviceID) != nil else { throw ICloudRetentionError.malformedSnapshot }
        try snapshot.validate(requested: expected, generation: snapshot.generation)
        let articles = snapshot.records.values.filter { [.read, .starred, .content].contains($0.envelope.kind) }
        if let metadata = snapshot.records[ICloudRetentionQuota.recordName] {
            let quota = try ICloudRetentionQuotaSnapshot(metadata: metadata, generation: snapshot.generation)
            if let accepted = quota.quota.reservations.first(where: { $0.operationID == operationID }) {
                let hash = articleRecordName.dropFirst("article-v1:".count)
                guard let marker = snapshot.records["retention-v1:" + hash], hasServerNonce(marker.envelope) else {
                    throw ICloudRetentionError.incompleteSnapshot
                }
                _ = try ICloudRetentionFence(envelope: marker.envelope, generation: snapshot.generation)
                return .alreadyAccepted(processedRecords: accepted.processedRecords)
            }
        }
        if articles.isEmpty { return .noCandidate }
        guard let quotaRecord = snapshot.records[ICloudRetentionQuota.recordName] else {
            throw ICloudRetentionError.incompleteSnapshot // Initialize only through the approved executor.
        }
        let quota = try ICloudRetentionQuotaSnapshot(metadata: quotaRecord, generation: snapshot.generation)
        let hash = articleRecordName.dropFirst("article-v1:".count)
        guard let marker = snapshot.records["retention-v1:" + hash], hasServerNonce(marker.envelope) else {
            throw ICloudRetentionError.incompleteSnapshot // Do not repair a broken writer contract by deleting data.
        }
        let fence = try ICloudRetentionFence(envelope: marker.envelope, generation: snapshot.generation)
        let policyRecord = snapshot.records[ICloudRetentionUnreadPolicy.recordName]
        let policy = try policyRecord.map { try ICloudRetentionUnreadPolicy(envelope: $0.envelope, generation: snapshot.generation) }
        let candidates = try ICloudRetentionPlanner.candidates(records: Array(articles), generation: snapshot.generation,
            isComplete: true, syncUnreadContent: policy?.allowsUnreadRemoval != true,
            protection: protection, existingFences: [fence], serverNow: quota.serverDate)
        guard let candidate = candidates.first else { return .noCandidate }
        guard candidates.count == 1 else { throw ICloudRetentionError.malformedSnapshot }
        var saves: [ICloudPreparedRecord] = [
            .init(envelope: try candidate.fence.envelope().stampedRetentionSave(),
                  systemFields: marker.systemFields, origins: [], isPending: true)
        ]
        if candidate.requiresUnreadPolicyGuard {
            guard let policyRecord, policy?.allowsUnreadRemoval == true, hasServerNonce(policyRecord.envelope) else {
                throw ICloudRetentionError.incompleteSnapshot
            }
            saves.append(.init(envelope: try policyRecord.envelope.stampedRetentionSave(),
                               systemFields: policyRecord.systemFields, origins: [], isPending: true))
        }
        let allocated = try quota.quota.allocating(candidate.processedRecordCount, operationID: operationID, serverDate: quota.serverDate)
        saves.append(try quota.preparing(allocated, observedClock: observedClock, deviceID: deviceID))
        guard saves.count + candidate.recordsToRemove.count == candidate.processedRecordCount,
              !candidate.recordsToRemove.isEmpty,
              Set(candidate.recordsToRemove).count == candidate.recordsToRemove.count,
              candidate.recordsToRemove.allSatisfy({ snapshot.records[$0] != nil }) else {
            throw ICloudRetentionError.malformedSnapshot
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Retain only a digest of the observed delete targets, never their
        // GUID/URL envelope, tags or opaque server fields in the durable job.
        let proof = try candidate.recordsToRemove.sorted().flatMap { name -> [String] in
            let metadata = snapshot.records[name]!
            return [name, try encoder.encode(metadata.envelope).base64EncodedString(), metadata.changeTag!,
                    String(metadata.creationDate!.timeIntervalSince1970), String(metadata.modificationDate!.timeIntervalSince1970)]
        }
        return .prepared(.init(generation: snapshot.generation, operationID: operationID,
            recordsToSave: saves, recordNamesToDelete: candidate.recordsToRemove,
            processedRecordCount: candidate.processedRecordCount,
            proposalDigest: ICloudSyncIdentity.digest(proof)))
    }

    private static func hasServerNonce(_ record: ICloudRecordEnvelope) -> Bool {
        guard case .text(let nonce) = record.fields["writer_nonce"]?.value,
              UUID(uuidString: nonce)?.uuidString == nonce else { return false }
        return true
    }
}
