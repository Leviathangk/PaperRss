import Foundation

/// An administrative clock CAS changes no historical article, retirement floor
/// or reservation. It requires a separate explicit approval bit: these metadata
/// saves are disclosed outside the 400-record historical cleanup batch budget.
/// Without it, a full or stale ledger must stop; a local clock cannot renew it.
enum ICloudRetentionQuotaClock {
    static func prepare(snapshot: ICloudRetentionPointSnapshot, writer: ICloudFieldVersion,
                        stamp: String = UUID().uuidString) throws -> ICloudPreparedRecord {
        try ICloudCloudRoot(generation: snapshot.generation, phase: .ready, protocolVersion: 3).validate()
        guard snapshot.requestedNames == [ICloudRetentionQuota.recordName],
              Set(snapshot.records.keys).isDisjoint(with: snapshot.missingNames),
              Set(snapshot.records.keys).union(snapshot.missingNames) == snapshot.requestedNames,
              writer.counter >= 0, writer.counter < Int64.max, UUID(uuidString: writer.deviceID) != nil,
              UUID(uuidString: stamp)?.uuidString == stamp else { throw ICloudRetentionError.malformedSnapshot }
        if let metadata = snapshot.records[ICloudRetentionQuota.recordName] {
            let current = try ICloudRetentionQuotaSnapshot(metadata: metadata, generation: snapshot.generation)
            return try current.preparing(current.quota.clockProbe(stamp: stamp), observedClock: writer.counter, deviceID: writer.deviceID)
        }
        // Conditional creation is allowed only from this point-read proof.
        return .init(envelope: try ICloudRetentionQuota(clockStamp: stamp)
            .envelope(version: .init(counter: writer.counter + 1, deviceID: writer.deviceID)),
            systemFields: nil, origins: [], isPending: true)
    }
}
