import Foundation
import GRDB

extension ICloudRecordRepository {
    /// Read-only protection. Unprepared journal intents count, and local stars
    /// remain protected even if the query's index has not caught up with an ACK.
    func maintenanceProtection() async throws -> ICloudMaintenanceProtection {
        try await database.readAsync { db in
            try self.requireScope(in: db)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else {
                throw ICloudRecordError.unavailableScope
            }
            var protection = ICloudMaintenanceProtection()
            protection.recordNames = Set(try String.fetchAll(db, sql: """
                SELECT record_name FROM icloud_records WHERE account_id = ? AND is_pending = 1
                UNION
                SELECT m.record_name FROM icloud_record_mappings m
                    JOIN icloud_sync_changes c ON c.account_id = m.account_id AND c.kind = m.kind AND c.entity_id = m.entity_id
                    WHERE c.account_id = ? AND c.is_pending = 1
                UNION
                SELECT m.record_name FROM icloud_record_mappings m
                    JOIN icloud_content_changes c ON c.account_id = m.account_id AND c.item_id = m.entity_id AND m.kind = 'content'
                    WHERE c.account_id = ? AND c.is_pending = 1;
                """, arguments: [self.accountID, self.accountID, self.accountID]))
            // A feed intent may not have a mapping until outgoing preparation.
            // Protect its cloud children by canonical identity in that case too.
            let feeds = try String.fetchAll(db, sql: """
                SELECT json_extract(payload_json, '$.feed_url') FROM icloud_sync_changes
                WHERE account_id = ? AND kind = 'feed' AND is_pending = 1;
                """, arguments: [self.accountID])
            for feed in feeds {
                if let url = URL(string: feed), let name = try? ICloudSyncIdentity.feedRecordName(feedURL: url) {
                    protection.recordNames.insert(name)
                } else { protection.hasUnresolvedChanges = true }
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT json_extract(payload_json, '$.feed_url') AS feed_url,
                    json_extract(payload_json, '$.source_item_id') AS source_item_id
                    FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1 AND kind IN ('read', 'starred')
                UNION
                SELECT f.feed_url, i.source_item_id FROM items i
                    JOIN feeds f ON f.id = i.feed_id JOIN article_states st ON st.item_id = i.id
                    JOIN icloud_sync_scope s ON s.account_id = i.account_id
                    LEFT JOIN icloud_content_changes c ON c.account_id = i.account_id AND c.item_id = i.id
                    WHERE i.account_id = ? AND (
                        st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1) OR c.is_pending = 1
                    );
                """, arguments: [self.accountID, self.accountID])
            for row in rows {
                let feed: String? = row["feed_url"]
                let source: String? = row["source_item_id"]
                if let feed, let url = URL(string: feed),
                   let name = try? ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source) {
                    protection.recordNames.insert("read-v1:" + name.dropFirst("article-v1:".count))
                } else {
                    // Without the opaque GUID we cannot prove an old cloud
                    // body is unrelated to this local article. Hold the preview.
                    protection.hasUnresolvedChanges = true
                }
            }
            if try Bool.fetchOne(db, sql: "SELECT settings_pending FROM icloud_sync_scope WHERE account_id = ?",
                                 arguments: [self.accountID]) == true {
                protection.hasUnresolvedChanges = true
            }
            return protection
        }
    }
}
