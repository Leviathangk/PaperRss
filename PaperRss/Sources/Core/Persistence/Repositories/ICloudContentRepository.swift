import Foundation
import GRDB

extension ICloudRecordRepository {
    func syncUnreadContent() throws -> Bool {
        try database.read { db in
            try requireScope(in: db, permitsPause: true)
            return try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) ?? false
        }
    }

    func setSyncUnreadContent(_ enabled: Bool) throws {
        try database.write { db in
            try updateSyncUnreadContent(enabled, in: db)
        }
    }

    func setSyncUnreadContentAsync(_ enabled: Bool) async throws {
        try await database.writeAsync { db in
            try self.updateSyncUnreadContent(enabled, in: db)
        }
    }

    private func updateSyncUnreadContent(_ enabled: Bool, in db: Database) throws {
        try requireScope(in: db, permitsPause: true)
        let previous = try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])
        guard previous != enabled else { return }
        try db.execute(sql: """
            UPDATE icloud_sync_scope SET sync_unread_content = ?, logical_clock = logical_clock + 1,
                settings_revision = settings_revision + 1, settings_pending = 1 WHERE account_id = ?;
            UPDATE icloud_sync_scope SET settings_counter = logical_clock WHERE account_id = ?;
            """, arguments: [enabled, accountID, accountID])
        if enabled { try ICloudContentSchema.captureEligible(accountID: accountID, requeue: true, in: db) }
    }

    func prepareSettings(in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ? AND settings_pending = 1",
                                        arguments: [accountID]) else { return }
        let counter: Int64 = row["settings_counter"]
        let origin = ICloudRecordOrigin(kind: .settings, entityID: accountID, revision: row["settings_revision"])
        let envelope = try ICloudRecordEnvelope(kind: .settings, recordName: "settings-v1:library", fields: [
            "sync_unread_content": .init(value: .flag(row["sync_unread_content"]),
                version: .init(counter: counter, deviceID: counter == 0 ? "" : row["device_id"]))
        ])
        let previous = try cached(envelope.recordName, zone: .library, in: db)
        if previous?.origins.contains(origin) == true { return }
        let merged = try previous?.envelope.merged(with: envelope) ?? envelope
        if merged == previous?.envelope { try acknowledge([origin], in: db); return }
        try save(merged, systemFields: previous?.systemFields, origins: [origin], pending: true, in: db)
    }

    func applySettings(_ envelope: ICloudRecordEnvelope, in db: Database) throws {
        guard case .flag(let value) = envelope.fields["sync_unread_content"]?.value else { throw ICloudRecordError.malformedRecord }
        let previous = try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])
        try db.execute(sql: "UPDATE icloud_sync_scope SET sync_unread_content = ? WHERE account_id = ?", arguments: [value, accountID])
        if value, previous != value { try ICloudContentSchema.captureEligible(accountID: accountID, requeue: true, in: db) }
    }

    private struct ContentSnapshot {
        let itemID: String
        let feedURL: String
        let sourceID: String
        let revision: Int64
        let content: ICloudArticleContent
    }

    /// Compress outside the SQLite writer. Installing a prepared body checks
    /// its revision so a newer RSS refresh stays pending and is not overwritten.
    func prepareContentRecords(limit: Int, recordNames: Set<String>? = nil, incoming: [ICloudRecordEnvelope]? = nil) throws {
        let incomingBodies = incoming?.filter { $0.kind == .content }
        if incomingBodies?.isEmpty == true { return }
        let snapshots: [ContentSnapshot] = try database.write { db in
            try requireScope(in: db)
            if incoming == nil { try ICloudContentSchema.captureEligible(accountID: accountID, in: db) }
            // Cancel unsent content when policy no longer permits it. Cloud
            // cleanup is separate; no reader state or local body is erased.
            if incoming == nil { try db.execute(sql: """
                UPDATE icloud_content_changes SET is_pending = 0
                WHERE account_id = ? AND is_pending = 1 AND NOT EXISTS (
                    SELECT 1 FROM items i JOIN article_states st ON st.item_id = i.id
                    JOIN feeds f ON f.id = i.feed_id JOIN icloud_sync_scope s ON s.account_id = i.account_id
                    WHERE i.id = icloud_content_changes.item_id AND i.account_id = icloud_content_changes.account_id
                      AND f.is_deleted = 0 AND (st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1))
                );
                UPDATE icloud_records SET is_pending = 0 WHERE account_id = ? AND is_pending = 1
                    AND json_extract(envelope_json, '$.kind') = 'content' AND NOT EXISTS (
                        SELECT 1 FROM icloud_record_mappings m JOIN icloud_content_changes c
                        ON c.account_id = m.account_id AND c.item_id = m.entity_id
                        WHERE m.account_id = icloud_records.account_id AND m.kind = 'content'
                        AND m.record_name = icloud_records.record_name AND c.is_pending = 1
                    );
                """, arguments: [accountID, accountID]) }
            var arguments: StatementArguments = [accountID]
            var scope = ""
            if let incomingBodies {
                scope = "AND i.source_item_id IN (\(Array(repeating: "?", count: incomingBodies.count).joined(separator: ",")))"
                arguments += StatementArguments(incomingBodies.compactMap(\.sourceItemID))
            } else if let recordNames {
                let names = recordNames.sorted()
                if names.isEmpty { return [] }
                scope = """
                    AND EXISTS (SELECT 1 FROM icloud_record_mappings m
                        WHERE m.account_id = c.account_id AND m.entity_id = c.item_id AND m.kind = 'content'
                        AND m.record_name IN (\(Array(repeating: "?", count: names.count).joined(separator: ","))))
                    """
                arguments += StatementArguments(names)
            }
            let limitClause = incoming != nil || recordNames != nil ? "" : "LIMIT ?"
            if !limitClause.isEmpty { arguments += [limit] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.item_id, c.revision, c.version_counter, c.device_id, f.feed_url, i.source_item_id
                FROM icloud_content_changes c JOIN items i ON i.id = c.item_id AND i.account_id = c.account_id
                JOIN feeds f ON f.id = i.feed_id
                WHERE c.account_id = ? AND c.is_pending = 1 AND c.deferred_reason IS NULL
                    AND length(trim(i.source_item_id)) > 0 \(scope)
                ORDER BY c.version_counter, c.item_id \(limitClause);
                """, arguments: arguments)
            return try rows.compactMap { row in
                let url: String = row["feed_url"], source: String = row["source_item_id"]
                let name = try contentName(feedURL: url, source: source)
                if let incomingBodies, !incomingBodies.contains(where: { $0.recordName == name }) { return nil }
                if let recordNames, !recordNames.contains(name) { return nil }
                let item: String = row["item_id"]
                let revision: Int64 = row["revision"]
                let origin = ICloudRecordOrigin(kind: .content, entityID: item, revision: revision)
                let identity = try ICloudRecordEnvelope(kind: .content, recordName: name,
                    feedURL: ICloudSyncIdentity.canonicalFeedURL(URL(string: url)!), sourceItemID: source,
                    fields: ["payload_hash": .init(value: .null, version: .init(counter: row["version_counter"], deviceID: row["device_id"]))])
                guard let version = try retentionContentVersion(identity, origin: origin, in: db) else { return nil }
                if let cached = try cached(name, zone: .articles, in: db), cached.origins.contains(origin),
                   cached.envelope.fields["payload_hash"]?.version == version { return nil }
                guard let article = try ArticleRecord.fetchOne(db, key: item) else { return nil }
                return ContentSnapshot(itemID: item, feedURL: url, sourceID: source, revision: revision,
                    content: .init(article))
            }
        }
        for snapshot in snapshots {
            let body: Data
            do { body = try ICloudArticleContentCodec.encode(snapshot.content) }
            catch {
                try database.write { db in
                    try db.execute(sql: "UPDATE icloud_content_changes SET deferred_reason = 'contentTooLarge' WHERE account_id = ? AND item_id = ? AND revision = ?",
                                   arguments: [accountID, snapshot.itemID, snapshot.revision])
                }
                continue
            }
            try database.write { db in
                try requireScope(in: db)
                guard let change = try Row.fetchOne(db, sql: """
                    SELECT revision, version_counter, device_id FROM icloud_content_changes
                    WHERE account_id = ? AND item_id = ? AND is_pending = 1;
                    """, arguments: [accountID, snapshot.itemID]), change["revision"] as Int64 == snapshot.revision else { return }
                let name = try contentName(feedURL: snapshot.feedURL, source: snapshot.sourceID)
                var envelope = try ICloudRecordEnvelope(kind: .content, recordName: name,
                    feedURL: ICloudSyncIdentity.canonicalFeedURL(URL(string: snapshot.feedURL)!),
                    sourceItemID: snapshot.sourceID,
                    fields: ["payload_hash": .init(value: .text(ICloudArticleContentCodec.hash(body)),
                        version: .init(counter: change["version_counter"], deviceID: change["device_id"]))])
                let origin = ICloudRecordOrigin(kind: .content, entityID: snapshot.itemID, revision: snapshot.revision)
                guard let version = try retentionContentVersion(envelope, origin: origin, in: db) else { return }
                envelope.fields["payload_hash"] = .init(value: envelope.fields["payload_hash"]!.value, version: version)
                _ = try mapping(kind: .content, entity: snapshot.itemID, suggested: name, in: db)
                let previous = try cached(name, zone: .articles, in: db)
                if let previous, previous.isConfirmed,
                   previous.envelope.fields["payload_hash"]?.value == envelope.fields["payload_hash"]?.value,
                   try !retentionSuppresses(previous.envelope, in: db) {
                    try acknowledge([origin], in: db)
                    return
                }
                let merged = try previous?.envelope.merged(with: envelope) ?? envelope
                if merged == previous?.envelope { try acknowledge([origin], in: db); return }
                var origins = previous?.origins.filter { $0.kind != .content || $0.entityID != snapshot.itemID } ?? []
                origins.append(origin)
                try save(merged, systemFields: previous?.systemFields, origins: origins, pending: true, bodyData: body, in: db)
            }
        }
    }

    private func contentName(feedURL: String, source: String) throws -> String {
        guard let url = URL(string: feedURL), let name = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source)
        else { throw ICloudRecordError.identityMismatch }
        return "content-v1:" + name.dropFirst("article-v1:".count)
    }

    func deferredContentCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_content_changes WHERE account_id = ? AND is_pending = 1 AND deferred_reason IS NOT NULL",
                             arguments: [accountID]) ?? 0
        }
    }

    func validateBody(_ envelope: ICloudRecordEnvelope, data: Data?) throws {
        guard envelope.kind == .content else {
            guard data == nil else { throw ICloudRecordError.malformedRecord }; return
        }
        switch envelope.fields["payload_hash"]?.value {
        case .text(let hash):
            guard let data else { throw ICloudRecordError.malformedRecord }
            _ = try ICloudArticleContentCodec.decode(data, expectedHash: hash)
        case .null:
            guard data == nil else { throw ICloudRecordError.malformedRecord }
        default: throw ICloudRecordError.malformedRecord
        }
    }

    func restoreContent(_ envelope: ICloudRecordEnvelope, in db: Database) throws -> Bool {
        guard case .text(let hash) = envelope.fields["payload_hash"]?.value else { return true }
        guard let url = envelope.feedURL, let parsed = URL(string: url), let source = envelope.sourceItemID else {
            throw ICloudRecordError.identityMismatch
        }
        let feedName = try ICloudSyncIdentity.feedRecordName(feedURL: parsed)
        if try cached(feedName, zone: .library, in: db)?.envelope.fields["deleted"]?.value == .flag(true) { return true }
        guard let feedID = try liveEntity(kind: .feed, name: feedName, in: db) else { return false }
        let suffix = envelope.recordName.dropFirst("content-v1:".count)
        let star = try liveCloudFlag(kind: .starred, suffix: suffix, in: db)
        let read = try liveCloudFlag(kind: .read, suffix: suffix, in: db)
        let syncUnread = try Bool.fetchOne(db, sql: "SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) ?? false
        // Retained content alone is not evidence of an unread or starred
        // article. Wait for an eligible state; expired or orphaned content
        // must not resurrect old read/unstarred articles as unread.
        guard star == .flag(true) || (syncUnread && read == .flag(false)) else { return false }
        guard let data = try cached(envelope.recordName, zone: .articles, in: db)?.bodyData else { throw ICloudRecordError.malformedRecord }
        let content = try ICloudArticleContentCodec.decode(data, expectedHash: hash)
        let now = Date().timeIntervalSince1970
        var entities = try localEntities(for: envelope, in: db)
        if entities.isEmpty {
            let itemID = "\(feedID)|\(source)".stableDigest
            if let existing = try ItemRecord.fetchOne(db, key: itemID),
               existing.accountID != accountID || existing.feedID != feedID || existing.sourceItemID != source { return false }
            try ItemRecord(id: itemID, accountID: accountID, externalID: itemID, feedID: feedID,
                createdAt: now, updatedAt: now, sourceItemID: source).save(db)
            try ArticleStateRecord(itemID: itemID, dateArrived: now, updatedAt: now).save(db)
            _ = try mapping(kind: .content, entity: itemID, suggested: envelope.recordName, in: db)
            entities = [itemID]
        }
        for itemID in entities {
            let existing = try ArticleRecord.fetchOne(db, key: itemID)
            // Cloud content fills gaps. Normal RSS refresh remains the source
            // of updates for an existing body, including newer local refreshes
            // made while an older body upload was in flight.
            if let existing, existing.contentHTML?.isEmpty == false || !existing.summary.isEmpty { continue }
            var article = existing ?? ArticleRecord(itemID: itemID, title: content.title)
            article.title = content.title; article.author = content.author; article.url = content.url
            article.publishedAt = content.publishedAt; article.summary = content.summary
            article.contentHTML = content.contentHTML; article.contentUpdatedAt = now
            try article.save(db)
        }
        try replayStates(for: envelope, in: db)
        return true
    }
}
