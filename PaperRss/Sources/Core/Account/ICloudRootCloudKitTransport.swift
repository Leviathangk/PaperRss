@preconcurrency import CloudKit
import CoreFoundation
import Foundation

enum ICloudCloudRootCodec {
    static let schemaVersion = 2
    static let zoneID = CKRecordZone.ID(zoneName: "PaperRssControl-v1", ownerName: CKCurrentUserDefaultName)
    static let recordID = CKRecord.ID(recordName: "library-root-v1", zoneID: zoneID)
    static let recordType = "PaperRssLibraryRootV1"
    private static let keys: Set<String> = ["schemaVersion", "generation", "phase"]

    static func encode(_ root: ICloudCloudRoot) throws -> CKRecord {
        try root.validate()
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["schemaVersion"] = root.protocolVersion as NSNumber
        record["generation"] = root.generation as NSString
        record["phase"] = root.phase.rawValue as NSString
        return record
    }

    static func decode(_ record: CKRecord) throws -> ICloudCloudRoot {
        guard record.recordType == recordType, record.recordID == recordID,
              Set(record.allKeys()) == keys,
              let version = record["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else { throw ICloudRootError.malformedRoot }
        guard [schemaVersion, ICloudCloudRoot.retentionProtocolVersion].contains(version.intValue),
              version.doubleValue == Double(version.intValue) else {
            throw ICloudRootError.unsupportedVersion
        }
        guard let generation = record["generation"] as? String,
              let phaseName = record["phase"] as? String, let phase = ICloudCloudRoot.Phase(rawValue: phaseName)
        else { throw ICloudRootError.malformedRoot }
        let root = ICloudCloudRoot(generation: generation, phase: phase, protocolVersion: version.intValue)
        try root.validate()
        return root
    }
}

/// Constructed only after the driver's entitlement and system-account checks.
/// No delete operation or legacy adoption is exposed by this transport.
struct ICloudRootCloudKitTransport: ICloudRootTransport {
    // The former whole-library prototype used this default-zone record.
    // Inspect system fields only; never download or migrate its CKAsset here.
    static let legacySnapshotID = CKRecord.ID(recordName: "paper-rss-library-v1")
    let database: CKDatabase
    var validateMutation: @Sendable () async throws -> Void = {}

    func lookupRoot() async throws -> ICloudRootLookup {
        do {
            let record = try await database.record(for: ICloudCloudRootCodec.recordID)
            return .found(try ICloudCloudRootCodec.decode(record))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            let zones = try await database.allRecordZones()
            let hasData = zones.contains { ICloudGenerationZone.isOwnedDataZoneName($0.zoneID.zoneName) }
            if hasData { return .missing(hasExistingData: true) }
            let legacy = try await database.records(for: [Self.legacySnapshotID], desiredKeys: [])
            guard let result = legacy[Self.legacySnapshotID] else { throw ICloudRecordError.persistenceFailed }
            switch result {
            case .success:
                return .missing(hasExistingData: true)
            case .failure(let error):
                if let cloud = error as? CKError, cloud.code == .unknownItem || cloud.code == .zoneNotFound {
                    return .missing(hasExistingData: false)
                }
                throw error
            }
        }
    }

    func createRoot(proposal: String) async throws -> ICloudCloudRoot {
        try await validateMutation()
        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: ICloudCloudRootCodec.zoneID)], deleting: [])
        guard let zone = zones.saveResults[ICloudCloudRootCodec.zoneID] else { throw ICloudRecordError.persistenceFailed }
        _ = try zone.get()
        try Task.checkCancellation()
        try await validateMutation()
        let desired = try ICloudCloudRootCodec.encode(.init(generation: proposal, phase: .ready))
        do {
            let result = try await database.modifyRecords(saving: [desired], deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[desired.recordID] else { throw ICloudRecordError.persistenceFailed }
            return try ICloudCloudRootCodec.decode(saved.get())
        } catch let error as CKError {
            guard let winner = try Self.conflictWinner(error) else { throw error }
            return winner
        }
    }

    static func conflictWinner(_ error: CKError) throws -> ICloudCloudRoot? {
        let conflict: CKError?
        if error.code == .serverRecordChanged { conflict = error }
        else if error.code == .partialFailure {
            conflict = error.partialErrorsByItemID?[ICloudCloudRootCodec.recordID] as? CKError
        } else { conflict = nil }
        guard let conflict, conflict.code == .serverRecordChanged else { return nil }
        guard let server = conflict.serverRecord else { throw ICloudRootError.malformedRoot }
        return try ICloudCloudRootCodec.decode(server)
    }
}
