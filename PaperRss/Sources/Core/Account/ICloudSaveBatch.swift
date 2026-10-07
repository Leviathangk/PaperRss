@preconcurrency import CloudKit
import Foundation

struct ICloudRecordSaveGroup: Sendable {
    let records: [ICloudPreparedRecord]
}

struct ICloudPreparedSaveBatch: Sendable {
    let records: [ICloudPreparedRecord]
    let atomicByZone: Bool
}

/// SDK scope and batch limits must never separate an article from its guard.
/// A single large asset group has the same first-record exception as before,
/// but now with a hard ceiling and its guard included.
enum ICloudSaveBatchPlanner {
    static let recordLimit = 150
    static let byteLimit = 2 * 1024 * 1024
    static let maximumSingleGroupBytes = 4 * 1024 * 1024

    static func select(_ groups: [ICloudRecordSaveGroup], generation: String, requiresArticleGuards: Bool,
                       scope: CKSyncEngine.SendChangesOptions.Scope = .all,
                       unavailable: Set<CKRecord.ID> = [], maximumRecords: Int = recordLimit,
                       maximumBytes: Int = byteLimit) throws -> ICloudPreparedSaveBatch {
        guard maximumRecords > 0, maximumRecords <= recordLimit, maximumBytes > 0, maximumBytes <= byteLimit else {
            throw ICloudRecordError.malformedRecord
        }
        var selected: [ICloudPreparedRecord] = [], selectedIDs: Set<CKRecord.ID> = [], bytes = 0
        for group in groups {
            guard !group.records.isEmpty else { continue }
            try validate(group, generation: generation, requiresArticleGuards: requiresArticleGuards)
            let ids = try group.records.map { try ICloudRecordCodec.recordID($0.envelope, generation: generation) }
            guard ids.allSatisfy({ scope.contains(.saveRecord($0)) && !unavailable.contains($0) }),
                  group.records.count <= maximumRecords - selected.count else { continue }
            guard selectedIDs.isDisjoint(with: ids) else { throw ICloudRecordError.malformedRecord }
            let records = try group.records.map { record -> ICloudPreparedRecord in
                guard record.envelope.kind == .retention || record.envelope.kind == .retentionPolicy else { return record }
                return .init(envelope: try record.envelope.stampedRetentionSave(), systemFields: record.systemFields,
                             origins: record.origins, isPending: true)
            }
            var size = 0
            for record in records {
                let envelopeBytes = try JSONEncoder().encode(record.envelope).count
                guard envelopeBytes <= ICloudRecordCodec.maximumEnvelopeBytes,
                      (record.bodyData?.count ?? 0) <= ICloudArticleContentCodec.maximumCompressedBytes else {
                    throw ICloudRecordError.malformedRecord
                }
                size += envelopeBytes + (record.bodyData?.count ?? 0)
            }
            guard size <= maximumSingleGroupBytes else { throw ICloudRecordError.malformedRecord }
            let fits = size <= maximumBytes - bytes
            let singleLargeGroup = selected.isEmpty && maximumBytes == byteLimit && size > byteLimit
            guard fits || singleLargeGroup else { continue }
            selected += records; selectedIDs.formUnion(ids); bytes += size
            if bytes >= maximumBytes { break }
        }
        return .init(records: selected, atomicByZone: requiresArticleGuards)
    }

    static func validateSavedReceipts(_ ids: Set<CKRecord.ID>, inFlight: [CKRecord.ID: ICloudPreparedRecord],
                                      generation: String, requiresArticleGuards: Bool) throws {
        guard requiresArticleGuards else { return }
        for id in ids {
            guard let sent = inFlight[id] else { throw ICloudRecordError.persistenceFailed }
            guard [.read, .starred, .content].contains(sent.envelope.kind) else { continue }
            let guardEnvelope = try ICloudRetentionFence(generation: generation, article: sent.envelope).envelope()
            let guardID = try ICloudRecordCodec.recordID(guardEnvelope, generation: generation)
            guard ids.contains(guardID), let companion = inFlight[guardID], companion.envelope.kind == .retention else {
                throw ICloudRecordError.persistenceFailed
            }
        }
    }

    private static func validate(_ group: ICloudRecordSaveGroup, generation: String, requiresArticleGuards: Bool) throws {
        for record in group.records { try record.envelope.validate() }
        let articles = group.records.filter { [.read, .starred, .content].contains($0.envelope.kind) }
        let guards = group.records.filter { $0.envelope.kind == .retention }
        guard requiresArticleGuards else {
            guard !group.records.contains(where: { [.retention, .retentionPolicy, .retentionQuota].contains($0.envelope.kind) }) else {
                throw ICloudRetentionError.unsupportedProtocol
            }
            return
        }
        guard !articles.isEmpty || !guards.isEmpty else { return }
        guard guards.count == 1, group.records.count <= 4,
              Set(group.records.map(\.envelope.kind)).count == group.records.count,
              group.records.allSatisfy({ $0.envelope.zone == .articles }) else {
            throw ICloudRecordError.malformedRecord
        }
        let fence = try ICloudRetentionFence(envelope: guards[0].envelope, generation: generation)
        for article in articles {
            _ = try fence.merged(with: ICloudRetentionFence(generation: generation, article: article.envelope))
            guard try !fence.suppresses(article.envelope) else { throw ICloudRecordError.malformedRecord }
        }
    }
}
