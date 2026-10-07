@preconcurrency import CloudKit
import Foundation
import GRDB

/// Point-read proof for one bounded group, not a successful query-index scan.
/// Missing IDs are accepted only from per-ID unknownItem results. Asset fields
/// are never requested, materialized or handed to the cleanup planner.
struct ICloudRetentionPointSnapshot: Sendable {
    let generation: String
    let requestedNames: Set<String>
    let records: [String: ICloudCloudRecordMetadata]
    let missingNames: Set<String>

    func validate(requested expected: Set<String>, generation expectedGeneration: String) throws {
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
        guard generation == expectedGeneration else { throw ICloudRetentionError.wrongGeneration }
        guard requestedNames == expected, Set(records.keys).isDisjoint(with: missingNames),
              Set(records.keys).union(missingNames) == expected else { throw ICloudRetentionError.incompleteSnapshot }
        for (name, metadata) in records {
            try metadata.envelope.validate()
            guard metadata.envelope.recordName == name, metadata.envelope.zone == .articles,
                  let fields = metadata.systemFields, !fields.isEmpty, fields.count <= 64 * 1_024,
                  let tag = metadata.changeTag, !tag.isEmpty, tag.utf8.count <= 4_096,
                  let created = metadata.creationDate, let modified = metadata.modificationDate,
                  created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 >= 0,
                  modified.timeIntervalSince1970.isFinite, modified >= created else {
                throw ICloudRetentionError.malformedSnapshot
            }
        }
    }

    static func decode(_ results: [CKRecord.ID: Result<CKRecord, any Error>],
                       requestedNames: Set<String>, generation: String) throws -> Self {
        let expected = try requestedIDs(requestedNames, generation: generation)
        guard Set(results.keys) == Set(expected.keys) else { throw ICloudRetentionError.incompleteSnapshot }
        var records: [String: ICloudCloudRecordMetadata] = [:], missing: Set<String> = []
        for (id, result) in results {
            let name = expected[id]!
            switch result {
            case .failure(let error):
                guard let error = error as? CKError, error.code == .unknownItem else { throw error }
                missing.insert(name)
            case .success(let record):
                guard record.recordID == id, let tag = record.recordChangeTag,
                      !tag.isEmpty, tag.utf8.count <= 4_096,
                      let created = record.creationDate, let modified = record.modificationDate,
                      created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 >= 0,
                      modified.timeIntervalSince1970.isFinite, modified >= created,
                      Set(record.allKeys()) == ["envelope"] else {
                    throw ICloudRetentionError.malformedSnapshot
                }
                let envelope = try ICloudRecordCodec.decode(record, generation: generation)
                let fields = ICloudRecordCodec.systemFields(record)
                guard fields.count <= 64 * 1_024 else { throw ICloudRetentionError.malformedSnapshot }
                records[name] = .init(envelope: envelope, creationDate: created, modificationDate: modified,
                                      systemFields: fields, changeTag: tag)
            }
        }
        return .init(generation: generation, requestedNames: requestedNames, records: records, missingNames: missing)
    }

    static func requestedIDs(_ requestedNames: Set<String>, generation: String) throws -> [CKRecord.ID: String] {
        guard !requestedNames.isEmpty, requestedNames.count <= 6 else { throw ICloudRetentionError.malformedSnapshot }
        var expected: [CKRecord.ID: String] = [:]
        for name in requestedNames {
            guard validName(name) else { throw ICloudRetentionError.malformedSnapshot }
            let id = CKRecord.ID(recordName: try ICloudGenerationIdentity.recordName(name, generation: generation),
                                 zoneID: try ICloudGenerationZone.id(.articles, generation: generation))
            expected[id] = name
        }
        return expected
    }

    private static func validName(_ name: String) -> Bool {
        if name == ICloudRetentionUnreadPolicy.recordName || name == ICloudRetentionQuota.recordName { return true }
        for prefix in ["read-v1:", "starred-v1:", "content-v1:", "retention-v1:"] where name.hasPrefix(prefix) {
            let hash = name.dropFirst(prefix.count)
            return hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
        }
        return false
    }
}

struct ICloudRetentionQuotaSnapshot: Sendable {
    let generation: String
    let quota: ICloudRetentionQuota
    let version: ICloudFieldVersion
    let systemFields: Data
    let changeTag: String
    let serverDate: Date

    init(metadata: ICloudCloudRecordMetadata, generation: String) throws {
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
        guard metadata.envelope.kind == .retentionQuota,
              let date = metadata.modificationDate, let created = metadata.creationDate,
              date >= created, created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 >= 0,
              let tag = metadata.changeTag, !tag.isEmpty,
              let fields = metadata.systemFields, !fields.isEmpty, fields.count <= 64 * 1_024 else {
            throw ICloudRetentionError.malformedSnapshot
        }
        quota = try .init(envelope: metadata.envelope)
        try quota.validate(serverDate: date)
        version = metadata.envelope.fields["ledger"]!.version
        self.generation = generation; serverDate = date; systemFields = fields; changeTag = tag
    }

    func preparing(_ quota: ICloudRetentionQuota, observedClock: Int64, deviceID: String) throws -> ICloudPreparedRecord {
        guard observedClock >= 0, max(observedClock, version.counter) < Int64.max, UUID(uuidString: deviceID) != nil else {
            throw ICloudRetentionError.clockOverflow
        }
        try self.quota.validateTransition(to: quota, serverDate: serverDate)
        let next = ICloudFieldVersion(counter: max(observedClock, version.counter) + 1, deviceID: deviceID)
        return .init(envelope: try quota.envelope(version: next), systemFields: systemFields, origins: [], isPending: true)
    }
}

/// Inert adapter. No call site is installed in ordinary sync or a scheduler.
/// It can be used only after the v3 cleanup approval/lifecycle gate is complete.
struct ICloudRetentionCloudKitMetadataTransport: Sendable {
    let repository: ICloudRecordRepository

    private struct Context: Equatable {
        let generation: String
        let fingerprint: String
    }

    private func context() async throws -> Context {
        guard ICloudSyncEngineDriver.isEntitled else { throw ICloudEngineError.notEntitled }
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        let binding = try await repository.rootBinding()
        guard binding.protocolVersion == 3, let generation = binding.generation,
              try repository.usesRetentionProtocol() else { throw ICloudRetentionError.unsupportedProtocol }
        let bound = try repository.database.read { db in
            try repository.requireScope(in: db)
            return try String.fetchOne(db, sql: "SELECT user_fingerprint FROM icloud_sync_scope WHERE account_id = ?",
                                       arguments: [repository.accountID])
        }
        guard fingerprint == bound else { throw ICloudRecordError.accountChanged }
        let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
        let record = try await database.record(for: ICloudCloudRootCodec.recordID)
        guard try ICloudCloudRootCodec.decode(record) == .init(generation: generation, phase: .ready, protocolVersion: 3) else {
            throw ICloudRecordError.recoveryRequired
        }
        try Task.checkCancellation()
        return .init(generation: generation, fingerprint: fingerprint)
    }

    func fetch(names: Set<String>) async throws -> ICloudRetentionPointSnapshot {
        try Task.checkCancellation()
        let before = try await context()
        let ids = Array(try ICloudRetentionPointSnapshot.requestedIDs(names, generation: before.generation).keys)
        let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
        let results = try await database.records(for: ids, desiredKeys: ["envelope"])
        let snapshot = try ICloudRetentionPointSnapshot.decode(results, requestedNames: names, generation: before.generation)
        guard try await context() == before else { throw ICloudRecordError.accountChanged }
        return snapshot
    }
}
