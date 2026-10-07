@preconcurrency import CloudKit
import Foundation

enum ICloudGenerationZoneClassification: Sendable, Equatable {
    case current(ICloudRecordZone), otherGeneration(ICloudRecordZone), legacy(ICloudRecordZone), unrelated
}

/// Physical zones, as well as record IDs, belong to an epoch. A delayed
/// deleteZone for an old epoch can never name a replacement library's zone.
enum ICloudGenerationZone {
    private static let separator = "-epoch-"

    static func id(_ zone: ICloudRecordZone, generation: String) throws -> CKRecordZone.ID {
        try ICloudCloudRoot(generation: generation, phase: .ready).validate()
        return .init(zoneName: zone.rawValue + separator + generation, ownerName: CKCurrentUserDefaultName)
    }

    static func classify(_ id: CKRecordZone.ID, generation: String?) throws -> ICloudGenerationZoneClassification {
        if let generation { try ICloudCloudRoot(generation: generation, phase: .ready).validate() }
        guard id.ownerName == CKCurrentUserDefaultName else { return .unrelated }
        if let legacy = ICloudRecordZone(rawValue: id.zoneName) { return .legacy(legacy) }
        for zone in ICloudRecordZone.allCases {
            let prefix = zone.rawValue + separator
            guard id.zoneName.hasPrefix(prefix) else { continue }
            let epoch = String(id.zoneName.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: epoch), uuid.uuidString == epoch else {
                throw ICloudRecordError.identityMismatch
            }
            return epoch == generation ? .current(zone) : .otherGeneration(zone)
        }
        return .unrelated
    }

    /// Conservative discovery when the root is missing: malformed owned names
    /// still represent existing data that needs review, never an empty library.
    static func isOwnedDataZoneName(_ name: String) -> Bool {
        ICloudRecordZone.allCases.contains { name == $0.rawValue || name.hasPrefix($0.rawValue + separator) }
    }

    static func currentZone(_ id: CKRecordZone.ID, generation: String) throws -> ICloudRecordZone? {
        if case .current(let zone) = try classify(id, generation: generation) { return zone }
        return nil
    }

    static func fetchOptions(_ options: CKSyncEngine.FetchChangesOptions,
                             generation: String) throws -> CKSyncEngine.FetchChangesOptions {
        let allowed = try ICloudRecordZone.allCases.map { try id($0, generation: generation) } + [ICloudCloudRootCodec.zoneID]
        var result = options
        result.scope = .zoneIDs(allowed.filter { options.scope.contains($0) })
        result.prioritizedZoneIDs = options.prioritizedZoneIDs.filter { result.scope.contains($0) }
        return result
    }

    /// Normal sync can create only current data zones. Destructive zone work
    /// belongs to the separately approved reset workflow, never restored SDK
    /// checkpoint intentions from another epoch or an old protocol version.
    static func obsoleteDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange],
                                        generation: String) throws -> [CKSyncEngine.PendingDatabaseChange] {
        try changes.filter {
            switch $0 {
            case .saveZone(let zone):
                return try currentZone(zone.zoneID, generation: generation) == nil
            case .deleteZone:
                return true
            @unknown default:
                return true
            }
        }
    }

    static func obsoleteRecordChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange],
                                      generation: String) throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try changes.filter {
            switch $0 {
            case .saveRecord(let id):
                guard try currentZone(id.zoneID, generation: generation) != nil else { return true }
                if case .current = try ICloudGenerationIdentity.classify(id.recordName, generation: generation) { return false }
                return true
            case .deleteRecord:
                return true
            @unknown default:
                return true
            }
        }
    }

    static func foreignZoneCount(_ ids: [CKRecordZone.ID], generation: String) throws -> Int {
        try ids.reduce(into: 0) { count, id in
            switch try classify(id, generation: generation) {
            case .otherGeneration, .legacy: count += 1
            case .current, .unrelated: break
            }
        }
    }
}
