import Foundation
import GRDB

extension ICloudRecordRepository {
    /// No extra journal: the desired monotone policy is derived from the
    /// durable settings intent and its confirmed wire-cache snapshot.
    func prepareRetentionUnreadPolicy(in db: Database) throws {
        guard try usesRetentionProtocol(in: db),
              let settings = try cached("settings-v1:library", zone: .library, in: db),
              let field = settings.envelope.fields["sync_unread_content"],
              case .flag(let enabled) = field.value else { return }
        let generation = try requireRetentionGeneration(in: db)
        let desired: ICloudRetentionUnreadPolicy
        if enabled {
            // Protect before even supplying the Library save to CKSyncEngine.
            desired = try .init(generation: generation, protectedVersion: field.version)
        } else {
            // A local off switch, speculative body cancellation or old ACK
            // cannot release server protection for an unaccepted Library value.
            guard settings.isConfirmed && !settings.isPending else { return }
            desired = try .init(generation: generation, releasedVersion: field.version)
        }
        let envelope = try desired.envelope()
        let previous = try cached(ICloudRetentionUnreadPolicy.recordName, zone: .articles, in: db)
        let merged = try previous?.envelope.merged(with: envelope) ?? envelope
        guard merged != previous?.envelope else { return }
        try save(merged, systemFields: previous?.systemFields, origins: [], pending: true, in: db)
    }

    func retentionPermitsSettingsSend(_ settings: ICloudRecordEnvelope, in db: Database) throws -> Bool {
        guard settings.kind == .settings, try usesRetentionProtocol(in: db),
              let field = settings.fields["sync_unread_content"], field.value == .flag(true) else { return true }
        guard let stored = try cached(ICloudRetentionUnreadPolicy.recordName, zone: .articles, in: db),
              stored.isConfirmed && !stored.isPending else { return false }
        let policy = try ICloudRetentionUnreadPolicy(envelope: stored.envelope, generation: requireRetentionGeneration(in: db))
        return policy.protects(field.version)
    }
}
