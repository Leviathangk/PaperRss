import Foundation
import GRDB

enum ICloudContentSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE icloud_sync_scope ADD COLUMN sync_unread_content INTEGER NOT NULL DEFAULT 0 CHECK(sync_unread_content IN (0, 1));
            ALTER TABLE icloud_sync_scope ADD COLUMN settings_revision INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE icloud_sync_scope ADD COLUMN settings_pending INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE icloud_sync_scope ADD COLUMN settings_counter INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE icloud_records ADD COLUMN body_data BLOB;
            ALTER TABLE icloud_records ADD COLUMN is_confirmed INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE icloud_content_changes (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                item_id TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK(revision > 0),
                is_pending INTEGER NOT NULL DEFAULT 1,
                version_counter INTEGER NOT NULL DEFAULT 0,
                device_id TEXT NOT NULL DEFAULT '',
                deferred_reason TEXT,
                PRIMARY KEY(account_id, item_id)
            );
            CREATE INDEX icloud_content_pending ON icloud_content_changes(account_id, is_pending, deferred_reason);
            """)
        for event in ["INSERT", "UPDATE OF revision"] {
            let suffix = event == "INSERT" ? "insert" : "update"
            try db.execute(sql: """
                CREATE TRIGGER icloud_content_version_\(suffix) AFTER \(event) ON icloud_content_changes
                WHEN NEW.is_pending = 1
                BEGIN
                    UPDATE icloud_sync_scope SET logical_clock = logical_clock + 1 WHERE account_id = NEW.account_id;
                    UPDATE icloud_content_changes SET
                        version_counter = (SELECT logical_clock FROM icloud_sync_scope WHERE account_id = NEW.account_id),
                        device_id = (SELECT device_id FROM icloud_sync_scope WHERE account_id = NEW.account_id)
                    WHERE account_id = NEW.account_id AND item_id = NEW.item_id;
                END;
                """)
        }
        let events: [(String, String, String, String)] = [
            ("article_insert", "INSERT", "articles", ""),
            ("article_update", "UPDATE OF title, author, url, published_at, summary, content_html", "articles",
             "AND (NEW.title IS NOT OLD.title OR NEW.author IS NOT OLD.author OR NEW.url IS NOT OLD.url OR NEW.published_at IS NOT OLD.published_at OR NEW.summary IS NOT OLD.summary OR NEW.content_html IS NOT OLD.content_html)"),
            ("state_insert", "INSERT", "article_states", ""),
            ("state_update", "UPDATE OF is_read, is_starred", "article_states",
             "AND ((NEW.is_starred = 1 AND OLD.is_starred = 0) OR (NEW.is_starred = 0 AND NEW.is_read = 0 AND OLD.is_read = 1))")
        ]
        for (name, event, table, difference) in events {
            try db.execute(sql: """
                CREATE TRIGGER icloud_content_\(name) AFTER \(event) ON \(table)
                WHEN EXISTS (
                    SELECT 1 FROM items i JOIN icloud_sync_scope s ON s.account_id = i.account_id
                    JOIN accounts a ON a.id = s.account_id
                    WHERE i.id = NEW.item_id AND a.type = 'iCloud'
                    AND s.capture_enabled = 1 AND s.suppress_capture = 0
                ) \(difference)
                BEGIN
                    \(enqueueSQL(itemFilter: "AND i.id = NEW.item_id", conflict: true));
                END;
                """)
        }
        try db.execute(sql: """
            CREATE TRIGGER icloud_content_identity AFTER UPDATE OF source_item_id ON items
            WHEN NEW.source_item_id IS NOT OLD.source_item_id
            AND EXISTS (SELECT 1 FROM icloud_sync_scope s JOIN accounts a ON a.id = s.account_id
                WHERE s.account_id = NEW.account_id AND a.type = 'iCloud' AND s.capture_enabled = 1 AND s.suppress_capture = 0)
            BEGIN
                \(enqueueSQL(itemFilter: "AND i.id = NEW.id", conflict: true));
            END;
            """)
    }

    /// Metadata only: no HTML copy, serialization or compression while the
    /// user marks a large group of articles as read.
    private static func enqueueSQL(itemFilter: String, conflict: Bool) -> String {
        """
        INSERT INTO icloud_content_changes(account_id, item_id, revision, is_pending)
        SELECT i.account_id, i.id, 1, 1 FROM items i
        JOIN articles ar ON ar.item_id = i.id JOIN article_states st ON st.item_id = i.id
        JOIN feeds f ON f.id = i.feed_id JOIN icloud_sync_scope s ON s.account_id = i.account_id
        JOIN accounts a ON a.id = s.account_id
        WHERE a.type = 'iCloud' AND f.is_deleted = 0 AND s.capture_enabled = 1
          AND (st.is_starred = 1 OR (st.is_read = 0 AND s.sync_unread_content = 1)) \(itemFilter)
        ON CONFLICT(account_id, item_id) \(conflict ? "DO UPDATE SET revision = revision + 1, is_pending = 1, deferred_reason = NULL" : "DO NOTHING")
        """
    }

    static func captureEligible(accountID: String, itemID: String? = nil, requeue: Bool = false, in db: Database) throws {
        var arguments: StatementArguments = [accountID]
        if let itemID { arguments += [itemID] }
        try db.execute(sql: enqueueSQL(itemFilter: "AND i.account_id = ? \(itemID == nil ? "" : "AND i.id = ?")", conflict: requeue), arguments: arguments)
    }
}
