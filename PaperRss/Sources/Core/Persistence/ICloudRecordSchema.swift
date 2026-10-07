import Foundation
import GRDB

/// Transport metadata never joins the reader projection or stores credentials.
enum ICloudRecordSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE icloud_sync_scope ADD COLUMN device_id TEXT NOT NULL DEFAULT '';
            ALTER TABLE icloud_sync_scope ADD COLUMN logical_clock INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE icloud_sync_scope ADD COLUMN user_fingerprint TEXT;
            ALTER TABLE icloud_sync_scope ADD COLUMN pause_reason TEXT;
            ALTER TABLE icloud_sync_scope ADD COLUMN initialized_zones INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE icloud_sync_changes ADD COLUMN is_user_intent INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE icloud_sync_changes ADD COLUMN field_versions_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(field_versions_json));

            CREATE TABLE icloud_record_mappings (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                record_name TEXT NOT NULL,
                PRIMARY KEY (account_id, kind, entity_id)
            );
            CREATE INDEX idx_icloud_mapping_record ON icloud_record_mappings(account_id, kind, record_name);

            CREATE TABLE icloud_records (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                zone TEXT NOT NULL,
                record_name TEXT NOT NULL,
                envelope_json TEXT NOT NULL CHECK (json_valid(envelope_json)),
                system_fields BLOB,
                origins_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(origins_json)),
                is_pending INTEGER NOT NULL DEFAULT 0,
                needs_apply INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (account_id, zone, record_name)
            );
            CREATE INDEX idx_icloud_records_pending ON icloud_records(account_id, is_pending);
            CREATE INDEX idx_icloud_records_inbox ON icloud_records(account_id, needs_apply);
            CREATE INDEX idx_icloud_records_source ON icloud_records(account_id, json_extract(envelope_json, '$.sourceItemID'))
                WHERE zone = 'PaperRssArticles-v1';
            CREATE INDEX idx_items_icloud_source ON items(account_id, source_item_id, feed_id)
                WHERE source_item_id IS NOT NULL;
            CREATE UNIQUE INDEX idx_accounts_single_icloud ON accounts(type) WHERE type = 'iCloud';
            """)
        for accountID in try String.fetchAll(db, sql: "SELECT account_id FROM icloud_sync_scope") {
            try ensureDeviceIdentity(accountID: accountID, in: db)
        }
        for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'icloud_%'") {
            // Names are controlled by migration v14.
            try db.execute(sql: "DROP TRIGGER \"\(name)\"")
        }
        try ICloudSyncSchema.installTriggers(in: db, versioned: true)
        try installVersionTriggers(in: db)
        for action in ["INSERT", "UPDATE OF source_item_id"] {
            try db.execute(sql: """
                CREATE TRIGGER icloud_materialize_\(action == "INSERT" ? "insert" : "identity")
                AFTER \(action) ON items WHEN NEW.source_item_id IS NOT NULL
                    \(action == "INSERT" ? "" : "AND NEW.source_item_id IS NOT OLD.source_item_id")
                BEGIN
                    UPDATE icloud_records SET needs_apply = 1
                    WHERE account_id = NEW.account_id AND zone = 'PaperRssArticles-v1'
                      AND json_extract(envelope_json, '$.sourceItemID') = NEW.source_item_id;
                END;
                """)
        }
        // Already captured development changes are stamped without activating
        // any scope or reclassifying a user's local account as iCloud.
        try db.execute(sql: """
            UPDATE icloud_sync_changes SET payload_json = payload_json WHERE is_pending = 1;
            """)
    }

    static func ensureDeviceIdentity(accountID: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE icloud_sync_scope SET device_id = ?
            WHERE account_id = ? AND device_id = '';
            """, arguments: [UUID().uuidString.lowercased(), accountID])
    }

    private static func installVersionTriggers(in db: Database) throws {
        let keys: [ICloudSyncChangeKind: [String]] = [
            .feed: ["feed_url", "title", "site_url", "sort_order", "deleted"],
            .folder: ["name", "sort_order", "deleted"],
            .membership: ["deleted"], .read: ["value"], .starred: ["value"]
        ]
        for isInsert in [true, false] {
            let version: String = """
                json_object('counter', CASE WHEN NEW.is_user_intent = 1 THEN
                    (SELECT logical_clock FROM icloud_sync_scope WHERE account_id = NEW.account_id)
                    ELSE 0 END,
                    'deviceID', CASE WHEN NEW.is_user_intent = 1 THEN
                    (SELECT device_id FROM icloud_sync_scope WHERE account_id = NEW.account_id)
                    ELSE '' END)
                """
            let cases: [String] = ICloudSyncChangeKind.allCases.map { kind -> String in
                let pairs = keys[kind]!.map { key -> String in
                    let unchanged: String
                    if isInsert {
                        unchanged = "0"
                    } else if key == "deleted" {
                        unchanged = "NEW.is_tombstone IS OLD.is_tombstone"
                    } else {
                        unchanged = "json_extract(NEW.payload_json, '$.\(key)') IS json_extract(OLD.payload_json, '$.\(key)')"
                    }
                    let previous = isInsert ? "NULL" : "json_extract(OLD.field_versions_json, '$.\(key)')"
                    return """
                        '$.\(key)', json(CASE WHEN (\(unchanged))
                            \(isInsert ? "" : "AND NOT (NEW.kind IN ('read', 'starred') AND OLD.is_user_intent = 0 AND NEW.is_user_intent = 1)")
                            AND \(previous) IS NOT NULL
                            THEN \(previous) ELSE \(version) END)
                        """
                }.joined(separator: ", ")
                return "WHEN '\(kind.rawValue)' THEN json_set(\(isInsert ? "'{}'" : "OLD.field_versions_json"), \(pairs))"
            }
            // For UPDATE start with OLD metadata, retaining only schema keys.
            let expression = cases.joined(separator: "\n")
            try db.execute(sql: """
                CREATE TRIGGER icloud_versions_\(isInsert ? "insert" : "update")
                AFTER \(isInsert ? "INSERT" : "UPDATE OF payload_json, is_tombstone, is_pending, is_user_intent") ON icloud_sync_changes
                WHEN NEW.is_pending = 1 AND EXISTS (
                    SELECT 1 FROM icloud_sync_scope
                    WHERE account_id = NEW.account_id AND capture_enabled = 1 AND suppress_capture = 0
                )
                BEGIN
                    UPDATE icloud_sync_scope SET logical_clock = logical_clock + 1
                    WHERE account_id = NEW.account_id;
                    UPDATE icloud_sync_changes SET field_versions_json = CASE NEW.kind
                        \(expression)
                    END
                    WHERE account_id = NEW.account_id AND kind = NEW.kind AND entity_id = NEW.entity_id;
                END;
                """)
        }
    }
}
