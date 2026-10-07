@preconcurrency import CloudKit
import Foundation

/// Read-only, inert on construction. Never starts CKSyncEngine, queries old
/// record bodies, creates zones, adopts a root, or mutates the local scope.
struct ICloudCloudResidueCloudKitTransport: ICloudResidueMetadataReading {
    let repository: ICloudRecordRepository
    static let rootKeys = ["schemaVersion", "generation", "phase"]
    static let legacyKeys: [CKRecord.FieldKey] = []

    func metadata(for context: ICloudResidueContext) async throws -> ICloudResidueMetadata {
        let database = try await verifiedDatabase(context)
        async let root = Self.rootMetadata(database)
        async let zones = database.allRecordZones()
        async let legacy = Self.legacySnapshotExists(database)
        let (rootValue, zoneValues, legacyValue) = try await (root, zones, legacy)
        try Task.checkCancellation()
        _ = try await verifiedDatabase(context)
        return .init(root: rootValue, zones: zoneValues.map(\.zoneID), hasLegacySnapshot: legacyValue)
    }

    private func verifiedDatabase(_ context: ICloudResidueContext) async throws -> CKDatabase {
        try Task.checkCancellation()
        guard try await validatedContext(for: context) == context else { throw ICloudCloudResetError.operationChanged }
        let fingerprint = try await ICloudSyncEngineDriver.systemUserFingerprint()
        try Task.checkCancellation()
        guard fingerprint == context.systemFingerprint else { throw ICloudRecordError.accountChanged }
        guard try await validatedContext(for: context) == context else { throw ICloudCloudResetError.operationChanged }
        return CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
    }

    private func validatedContext(for context: ICloudResidueContext) async throws -> ICloudResidueContext {
        // The public residue scan still rejects accountChanged. Only the
        // explicit original-account recovery can construct this context.
        if context.pauseReason == "accountChanged" { return try await repository.sameAccountResumeContext() }
        return try await repository.cloudResidueContext()
    }

    private static func rootMetadata(_ database: CKDatabase) async throws -> ICloudResidueRootObservation {
        let results = try await database.records(for: [ICloudCloudRootCodec.recordID], desiredKeys: rootKeys)
        guard let result = results[ICloudCloudRootCodec.recordID] else { throw ICloudRecordError.persistenceFailed }
        switch result {
        case .success(let record): return projectedRoot(record)
        case .failure(let error):
            if isMissing(error) { return .missing }
            throw error
        }
    }

    /// A projection only; not a substitute for the sync channel's full-record
    /// compatibility validation and never used to authorize a root mutation.
    static func projectedRoot(_ record: CKRecord) -> ICloudResidueRootObservation {
        guard let tag = record.recordChangeTag, !tag.isEmpty,
              let root = try? ICloudCloudRootCodec.decode(record) else { return .incompatible }
        return .found(root, changeTag: tag)
    }

    private static func legacySnapshotExists(_ database: CKDatabase) async throws -> Bool {
        let id = ICloudRootCloudKitTransport.legacySnapshotID
        let results = try await database.records(for: [id], desiredKeys: legacyKeys)
        guard let result = results[id] else { throw ICloudRecordError.persistenceFailed }
        switch result {
        case .success(let record):
            try validateLegacyMetadata(record)
            return true
        case .failure(let error):
            if isMissing(error) { return false }
            throw error
        }
    }

    static func validateLegacyMetadata(_ record: CKRecord) throws {
        guard record.recordID == ICloudRootCloudKitTransport.legacySnapshotID, record.allKeys().isEmpty else {
            throw ICloudRecordError.identityMismatch
        }
    }

    private static func isMissing(_ error: any Error) -> Bool {
        guard let cloud = error as? CKError else { return false }
        return cloud.code == .unknownItem || cloud.code == .zoneNotFound
    }
}
