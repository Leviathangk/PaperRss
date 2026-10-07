@preconcurrency import CloudKit
import Foundation

/// This boundary is injectable only in Core tests. Production must check its
/// entitlement before creating an SDK implementation or a CKContainer.
protocol ICloudArchiveMetadataSDK: Sendable {
    func fingerprint() async throws -> String
    func root(desiredKeys: [CKRecord.FieldKey]?) async throws -> (record: CKRecord?, changeTag: String?)
    func zones() async throws -> [CKRecordZone.ID]
    func legacySnapshotExists(desiredKeys: [CKRecord.FieldKey]) async throws -> Bool
}

struct ICloudArchiveCloudKitTransport: ICloudArchiveCloudReading {
    let database: LibraryDatabase
    let accountID: String

    func observe() async throws -> ICloudArchiveCloudObservation {
        guard ICloudSyncEngineDriver.isEntitled else { throw ICloudEngineError.notEntitled }
        return try await observeAfterEntitlementCheck(using: ArchiveSDK())
    }

    /// No root mutation, legacy snapshot fields/assets, engine or article query.
    /// The source is still bound to its old user; only its context is checked,
    /// while the system fingerprint is observed independently for the target.
    func observeAfterEntitlementCheck(using sdk: any ICloudArchiveMetadataSDK) async throws -> ICloudArchiveCloudObservation {
        let coordinator = ICloudArchiveRecoveryCoordinator(database: database, accountID: accountID, transport: self)
        let source = try await coordinator.snapshot()
        try Task.checkCancellation()
        let fingerprint = try await sdk.fingerprint()
        guard !fingerprint.isEmpty, fingerprint.utf8.count <= 256 else { throw ICloudRecordError.accountChanged }
        try await validate(source, fingerprint: fingerprint, coordinator: coordinator, sdk: sdk)
        // nil means all fields. A projection could conceal incompatible keys.
        let result = try await sdk.root(desiredKeys: nil)
        try await validate(source, fingerprint: fingerprint, coordinator: coordinator, sdk: sdk)
        let root: ICloudResidueRootObservation
        if let record = result.record {
            if let tag = result.changeTag, !tag.isEmpty, let value = try? ICloudCloudRootCodec.decode(record) {
                root = .found(value, changeTag: tag)
            } else { root = .incompatible }
        } else { root = .missing }
        let zones = try await sdk.zones()
        try await validate(source, fingerprint: fingerprint, coordinator: coordinator, sdk: sdk)
        var legacySnapshotExists: Bool?
        if root == .missing, !zones.contains(where: { ICloudGenerationZone.isOwnedDataZoneName($0.zoneName) }) {
            // Only the fixed legacy record's existence is needed. Never fetch
            // its fields or asset, and never turn a failed lookup into absence.
            legacySnapshotExists = try await sdk.legacySnapshotExists(desiredKeys: [])
            try await validate(source, fingerprint: fingerprint, coordinator: coordinator, sdk: sdk)
        }
        return .init(fingerprint: fingerprint, root: root, zones: zones, legacySnapshotExists: legacySnapshotExists)
    }

    private func validate(_ source: ICloudArchiveSource, fingerprint: String,
                          coordinator: ICloudArchiveRecoveryCoordinator,
                          sdk: any ICloudArchiveMetadataSDK) async throws {
        try Task.checkCancellation()
        guard try await coordinator.snapshot() == source else { throw ICloudArchiveRecoveryError.staleReview }
        guard try await sdk.fingerprint() == fingerprint else { throw ICloudRecordError.accountChanged }
        try Task.checkCancellation()
        guard try await coordinator.snapshot() == source else { throw ICloudArchiveRecoveryError.staleReview }
    }

    private struct ArchiveSDK: ICloudArchiveMetadataSDK {
        func fingerprint() async throws -> String { try await ICloudSyncEngineDriver.systemUserFingerprint() }
        func root(desiredKeys: [CKRecord.FieldKey]?) async throws -> (record: CKRecord?, changeTag: String?) {
            let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
            let id = ICloudCloudRootCodec.recordID
            let results = try await database.records(for: [id], desiredKeys: desiredKeys)
            guard let result = results[id] else { throw ICloudRecordError.persistenceFailed }
            switch result {
            case .success(let record): return (record, record.recordChangeTag)
            case .failure(let error):
                if let cloud = error as? CKError, cloud.code == .unknownItem || cloud.code == .zoneNotFound { return (nil, nil) }
                throw error
            }
        }
        func zones() async throws -> [CKRecordZone.ID] {
            try await CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase.allRecordZones().map(\.zoneID)
        }
        func legacySnapshotExists(desiredKeys: [CKRecord.FieldKey]) async throws -> Bool {
            let database = CKContainer(identifier: ICloudSyncEngineDriver.containerIdentifier).privateCloudDatabase
            let id = ICloudRootCloudKitTransport.legacySnapshotID
            let results = try await database.records(for: [id], desiredKeys: desiredKeys)
            guard let result = results[id] else { throw ICloudRecordError.persistenceFailed }
            switch result {
            case .success: return true
            case .failure(let error):
                if let cloud = error as? CKError, cloud.code == .unknownItem || cloud.code == .zoneNotFound { return false }
                throw error
            }
        }
    }
}
