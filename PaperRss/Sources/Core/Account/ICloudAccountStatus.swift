import Foundation
import GRDB

public enum ICloudAccountCreationAvailability: Sendable, Equatable {
    case ready, alreadyExists, unsupportedBuild
}

/// A local, read-only view of sync work. Network success is independent of
/// unresolved historical identities, deferred content and durable inbox rows.
public struct ICloudAccountSyncSnapshot: Sendable, Equatable {
    public let syncUnreadContent: Bool
    public let pendingChanges: Int
    public let missingArticleIdentities: Int
    public let deferredBodies: Int
    public let waitingArticleStates: Int
    public let waitingRelationships: Int
    public let waitingBodies: Int
    public let isPaused: Bool
}

extension ICloudRecordRepository {
    func accountSnapshot() async throws -> ICloudAccountSyncSnapshot {
        try await database.readAsync { db in
            try self.requireScope(in: db, permitsPause: true)
            let scope = try Row.fetchOne(db, sql: "SELECT sync_unread_content, pause_reason FROM icloud_sync_scope WHERE account_id = ?",
                                         arguments: [self.accountID])!
            let pending = try Int.fetchOne(db, sql: """
                WITH eligible_content AS (
                    SELECT c.*, i.source_item_id FROM icloud_content_changes c
                    JOIN items i ON i.id = c.item_id AND i.account_id = c.account_id
                    JOIN article_states st ON st.item_id = i.id JOIN feeds f ON f.id = i.feed_id
                    JOIN icloud_sync_scope s ON s.account_id = c.account_id
                    WHERE c.account_id = ? AND c.is_pending = 1 AND c.deferred_reason IS NULL
                      AND length(trim(i.source_item_id)) > 0 AND f.is_deleted = 0
                      AND (st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1))
                )
                SELECT COUNT(*) FROM (
                    SELECT COALESCE(m.record_name, 'local:' || c.kind || ':' || c.entity_id) AS identity
                    FROM icloud_sync_changes c LEFT JOIN icloud_record_mappings m
                        ON m.account_id = c.account_id AND m.kind = c.kind AND m.entity_id = c.entity_id
                    WHERE c.account_id = ? AND c.is_pending = 1 AND
                        (c.kind NOT IN ('read', 'starred') OR length(trim(json_extract(c.payload_json, '$.source_item_id'))) > 0)
                    UNION
                    SELECT COALESCE(m.record_name, 'local:content:' || c.item_id)
                    FROM eligible_content c LEFT JOIN icloud_record_mappings m
                        ON m.account_id = c.account_id AND m.kind = 'content' AND m.entity_id = c.item_id
                    UNION
                    SELECT 'settings-v1:library' FROM icloud_sync_scope
                        WHERE account_id = ? AND settings_pending = 1
                    UNION
                    SELECT record_name FROM icloud_records r
                    WHERE r.account_id = ? AND r.is_pending = 1 AND (
                        json_extract(r.envelope_json, '$.kind') != 'content' OR EXISTS (
                            SELECT 1 FROM eligible_content c JOIN icloud_record_mappings m
                                ON m.account_id = c.account_id AND m.entity_id = c.item_id AND m.kind = 'content'
                            WHERE m.record_name = r.record_name
                        ))
                );
                """, arguments: [self.accountID, self.accountID, self.accountID, self.accountID]) ?? 0
            let missing = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT entity_id) FROM icloud_sync_changes
                WHERE account_id = ? AND is_pending = 1 AND kind IN ('read', 'starred')
                  AND COALESCE(length(trim(json_extract(payload_json, '$.source_item_id'))), 0) = 0;
                """, arguments: [self.accountID]) ?? 0
            let deferred = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM icloud_content_changes c JOIN items i ON i.id = c.item_id AND i.account_id = c.account_id
                JOIN article_states st ON st.item_id = i.id JOIN feeds f ON f.id = i.feed_id
                JOIN icloud_sync_scope s ON s.account_id = c.account_id
                WHERE c.account_id = ? AND c.is_pending = 1 AND c.deferred_reason IS NOT NULL
                  AND length(trim(i.source_item_id)) > 0 AND f.is_deleted = 0
                  AND (st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1));
                """, arguments: [self.accountID]) ?? 0
            let inbox = try Row.fetchOne(db, sql: """
                SELECT COUNT(CASE WHEN json_extract(envelope_json, '$.kind') IN ('read', 'starred') THEN 1 END) AS states,
                    COUNT(CASE WHEN json_extract(envelope_json, '$.kind') = 'membership' THEN 1 END) AS relationships,
                    COUNT(CASE WHEN json_extract(envelope_json, '$.kind') = 'content' THEN 1 END) AS bodies
                FROM icloud_records WHERE account_id = ? AND needs_apply = 1;
                """, arguments: [self.accountID])!
            return .init(syncUnreadContent: scope["sync_unread_content"], pendingChanges: pending,
                missingArticleIdentities: missing, deferredBodies: deferred,
                waitingArticleStates: inbox["states"], waitingRelationships: inbox["relationships"],
                waitingBodies: inbox["bodies"], isPaused: scope["pause_reason"] as String? != nil)
        }
    }
}
