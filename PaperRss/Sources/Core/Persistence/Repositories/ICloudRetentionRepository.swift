import Foundation
import GRDB

extension ICloudRecordRepository {
    func outgoingRecordGroups(recordNames: Set<String>? = nil) throws -> [ICloudRecordSaveGroup] {
        let prepared = try outgoingRecords(recordNames: recordNames)
        return try database.read { db in
            try requireScope(in: db)
            guard try usesRetentionProtocol(in: db) else {
                guard !prepared.contains(where: { [.retention, .retentionPolicy, .retentionQuota].contains($0.envelope.kind) }) else {
                    throw ICloudRetentionError.unsupportedProtocol
                }
                return prepared.map { .init(records: [$0]) }
            }
            let generation = try requireRetentionGeneration(in: db)
            var library: [ICloudRecordSaveGroup] = [], grouped: [String: [ICloudPreparedRecord]] = [:]
            var guards: [String: ICloudPreparedRecord] = [:]
            for record in prepared {
                if record.envelope.kind == .retention {
                    _ = try ICloudRetentionFence(envelope: record.envelope, generation: generation)
                    guards[record.envelope.recordName] = record
                } else if record.envelope.kind == .retentionQuota {
                    // Ordinary sync may receive the shared ledger but must
                    // never replay a stale quota proposal as a normal save.
                    throw ICloudRetentionError.malformedSnapshot
                } else if record.envelope.kind == .retentionPolicy {
                    library.append(.init(records: [record]))
                } else if record.envelope.zone == .articles {
                    let identity = try ICloudRetentionFence(generation: generation, article: record.envelope)
                    grouped[identity.recordName, default: []].append(record)
                    if guards[identity.recordName] == nil {
                        if let stored = try cached(identity.recordName, zone: .articles, in: db) {
                            _ = try identity.merged(with: ICloudRetentionFence(envelope: stored.envelope, generation: generation))
                            guards[identity.recordName] = stored
                        } else {
                            guards[identity.recordName] = .init(envelope: try identity.envelope(), systemFields: nil, origins: [], isPending: true)
                        }
                    }
                } else if try retentionPermitsSettingsSend(record.envelope, in: db) {
                    library.append(.init(records: [record]))
                }
            }
            return library + guards.keys.sorted().map { name in
                .init(records: [guards[name]!] + (grouped[name] ?? []).sorted { $0.envelope.recordName < $1.envelope.recordName })
            }
        }
    }

    func isPendingRetentionGuard(_ name: String, in db: Database) throws -> Bool {
        let suffix = name.dropFirst("retention-v1:".count)
        let related = ["read-v1:" + suffix, "starred-v1:" + suffix, "content-v1:" + suffix]
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM icloud_records WHERE account_id = ? AND record_name IN (?, ?, ?, ?) AND is_pending = 1)
                OR EXISTS (SELECT 1 FROM icloud_record_mappings m JOIN icloud_sync_changes c
                    ON c.account_id = m.account_id AND c.kind = m.kind AND c.entity_id = m.entity_id
                    WHERE m.account_id = ? AND m.record_name IN (?, ?, ?) AND c.is_pending = 1)
                OR EXISTS (SELECT 1 FROM icloud_record_mappings m JOIN icloud_content_changes c
                    ON c.account_id = m.account_id AND c.item_id = m.entity_id
                    WHERE m.account_id = ? AND m.kind = 'content' AND m.record_name = ? AND c.is_pending = 1);
            """, arguments: [accountID, name, related[0], related[1], related[2],
                               accountID, related[0], related[1], related[2], accountID, related[2]]) ?? false
    }

    func usesRetentionProtocol() throws -> Bool {
        try database.read { db in
            try requireScope(in: db)
            return try usesRetentionProtocol(in: db)
        }
    }

    func usesRetentionProtocol(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT cloud_protocol_version = 3 AND cloud_generation IS NOT NULL
            FROM icloud_sync_scope WHERE account_id = ?;
            """, arguments: [accountID]) ?? false
    }

    func requireRetentionGeneration(in db: Database) throws -> String {
        guard try usesRetentionProtocol(in: db),
              let generation = try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope WHERE account_id = ?",
                                                  arguments: [accountID]) else {
            throw ICloudRetentionError.unsupportedProtocol
        }
        return generation
    }

    func retentionFence(for article: ICloudRecordEnvelope, in db: Database) throws -> ICloudRetentionFence? {
        guard [.read, .starred, .content].contains(article.kind), try usesRetentionProtocol(in: db) else { return nil }
        let generation = try requireRetentionGeneration(in: db)
        let identity = try ICloudRetentionFence(generation: generation, article: article)
        guard let stored = try cached(identity.recordName, zone: .articles, in: db) else { return nil }
        return try identity.merged(with: ICloudRetentionFence(envelope: stored.envelope, generation: generation))
    }

    func retentionSuppresses(_ article: ICloudRecordEnvelope, in db: Database) throws -> Bool {
        try retentionFence(for: article, in: db)?.suppresses(article) ?? false
    }

    /// A new device cannot apply an article page until a server fence is known.
    /// A speculative guard created for a local save is not receive evidence.
    func retentionCanApply(_ article: ICloudRecordEnvelope, in db: Database) throws -> Bool {
        guard [.read, .starred, .content].contains(article.kind), try usesRetentionProtocol(in: db) else { return true }
        guard let fence = try retentionFence(for: article, in: db),
              let stored = try cached(fence.recordName, zone: .articles, in: db),
              stored.isConfirmed || stored.systemFields != nil else { return false }
        return try !fence.suppresses(article)
    }

    func retentionStateVersion(_ article: ICloudRecordEnvelope, origin: ICloudRecordOrigin,
                               isUserIntent: Bool, in db: Database) throws -> ICloudFieldVersion? {
        let current = article.fields["value"]!.version
        guard let fence = try retentionFence(for: article, in: db), try fence.suppresses(article) else { return current }
        guard isUserIntent else { return nil }
        let scope = try Row.fetchOne(db, sql: "SELECT logical_clock, device_id FROM icloud_sync_scope WHERE account_id = ?",
                                    arguments: [accountID])!
        let version = try fence.versionForPendingIntent(kind: article.kind, current: current,
            observedClock: scope["logical_clock"], deviceID: scope["device_id"])
        let encoded = String(decoding: try JSONEncoder().encode(["value": version]), as: UTF8.self)
        // Do not change revision or payload: late receipts still identify the
        // original send, while this logical version records its rebase.
        try db.execute(sql: """
            UPDATE icloud_sync_changes SET field_versions_json = ?
            WHERE account_id = ? AND kind = ? AND entity_id = ? AND revision = ?
                AND is_pending = 1 AND is_user_intent = 1;
            UPDATE icloud_sync_scope SET logical_clock = MAX(logical_clock, ?) WHERE account_id = ?;
            """, arguments: [encoded, accountID, origin.kind.rawValue, origin.entityID, origin.revision, version.counter, accountID])
        return version
    }

    /// Local eligibility alone is insufficient once its cloud state retired.
    /// Prepare real state intents first; an old acknowledged star cannot make
    /// a body eligible again merely because RSS or a cache row still exists.
    func retentionPermitsContentPreparation(_ content: ICloudRecordEnvelope, in db: Database) throws -> Bool {
        guard let fence = try retentionFence(for: content, in: db) else { return true }
        for kind in [ICloudRecordKind.read, .starred] {
            let name = "\(kind.rawValue)-v1:" + content.recordName.dropFirst("content-v1:".count)
            let state = try cached(name, zone: .articles, in: db)?.envelope ?? ICloudRecordEnvelope(
                kind: kind, recordName: name, feedURL: content.feedURL, sourceItemID: content.sourceItemID,
                fields: ["value": .init(value: .flag(false), version: .bootstrap)])
            try preparePendingLocal(for: state, in: db)
        }
        let suffix = content.recordName.dropFirst("content-v1:".count)
        if let star = try cached("starred-v1:" + suffix, zone: .articles, in: db)?.envelope,
           try !fence.suppresses(star), star.fields["value"]?.value == .flag(true) { return true }
        if try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) == true,
           let read = try cached("read-v1:" + suffix, zone: .articles, in: db)?.envelope,
           try !fence.suppresses(read), read.fields["value"]?.value == .flag(false) { return true }
        return false
    }

    func retentionContentVersion(_ content: ICloudRecordEnvelope, origin: ICloudRecordOrigin,
                                 in db: Database) throws -> ICloudFieldVersion? {
        let current = content.fields["payload_hash"]!.version
        guard let fence = try retentionFence(for: content, in: db) else { return current }
        guard try retentionPermitsContentPreparation(content, in: db) else { return nil }
        let scope = try Row.fetchOne(db, sql: "SELECT logical_clock, device_id FROM icloud_sync_scope WHERE account_id = ?",
                                    arguments: [accountID])!
        let version = try fence.versionForPendingIntent(kind: .content, current: current,
            observedClock: scope["logical_clock"], deviceID: scope["device_id"])
        if version != current {
            try db.execute(sql: """
                UPDATE icloud_content_changes SET version_counter = ?, device_id = ?
                WHERE account_id = ? AND item_id = ? AND revision = ? AND is_pending = 1;
                UPDATE icloud_sync_scope SET logical_clock = MAX(logical_clock, ?) WHERE account_id = ?;
                """, arguments: [version.counter, version.deviceID, accountID, origin.entityID, origin.revision, version.counter, accountID])
        }
        return version
    }

    func reconcileRetentionFence(_ envelope: ICloudRecordEnvelope, in db: Database) throws {
        let generation = try requireRetentionGeneration(in: db)
        let fence = try ICloudRetentionFence(envelope: envelope, generation: generation)
        for kind in [ICloudRecordKind.read, .starred, .content] {
            let name = "\(kind.rawValue)-v1:" + fence.recordName.dropFirst("retention-v1:".count)
            guard let old = try cached(name, zone: .articles, in: db) else { continue }
            if kind == .content {
                for entity in try localEntities(for: old.envelope, in: db) {
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT revision, version_counter, device_id FROM icloud_content_changes
                        WHERE account_id = ? AND item_id = ? AND is_pending = 1;
                        """, arguments: [accountID, entity]) else { continue }
                    let origin = ICloudRecordOrigin(kind: .content, entityID: entity, revision: row["revision"])
                    var local = old.envelope
                    local.fields["payload_hash"] = .init(value: old.envelope.fields["payload_hash"]!.value,
                        version: .init(counter: row["version_counter"], deviceID: row["device_id"]))
                    guard let version = try retentionContentVersion(local, origin: origin, in: db),
                          old.origins.contains(origin) else { continue }
                    local.fields["payload_hash"] = .init(value: local.fields["payload_hash"]!.value, version: version)
                    let merged = try old.envelope.merged(with: local)
                    if merged != old.envelope {
                        try save(merged, systemFields: old.systemFields, origins: old.origins,
                                 pending: true, bodyData: old.bodyData, in: db)
                    }
                }
            } else { try preparePendingLocal(for: old.envelope, in: db) }
            if let latest = try cached(name, zone: .articles, in: db), try fence.suppresses(latest.envelope) {
                try db.execute(sql: """
                    UPDATE icloud_records SET is_pending = 0, needs_apply = 0
                    WHERE account_id = ? AND zone = ? AND record_name = ?;
                    """, arguments: [accountID, ICloudRecordZone.articles.rawValue, name])
            }
        }
    }

    func liveCloudFlag(kind: ICloudRecordKind, suffix: Substring, in db: Database) throws -> ICloudFieldValue? {
        guard let state = try cached("\(kind.rawValue)-v1:" + suffix, zone: .articles, in: db),
              try retentionCanApply(state.envelope, in: db) else { return nil }
        return state.envelope.fields["value"]?.value
    }

    func retentionNeedsBodyRequeue(for state: ICloudRecordEnvelope, entity: String, in db: Database) throws -> Bool {
        guard let fence = try retentionFence(for: state, in: db), fence.contentFloor != nil else { return false }
        let qualifies: Bool
        if state.kind == .starred { qualifies = state.fields["value"]?.value == .flag(true) }
        else {
            let enabled = try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) == true
            qualifies = state.fields["value"]?.value == .flag(false) && enabled
        }
        guard qualifies,
              try Bool.fetchOne(db, sql: "SELECT is_pending FROM icloud_content_changes WHERE account_id = ? AND item_id = ?",
                                arguments: [accountID, entity]) != true else { return false }
        let name = "content-v1:" + fence.recordName.dropFirst("retention-v1:".count)
        guard let body = try cached(name, zone: .articles, in: db) else { return true }
        return try fence.suppresses(body.envelope)
    }
}
