import GRDB

/// Archival is explicit; this migration archives no account and changes no
/// scope. Persistent guards also reject a late provider/cache/AI write after
/// the archive transaction has committed, regardless of the calling UI.
enum ICloudLocalArchiveSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE accounts ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0
                CHECK (is_archived IN (0, 1) AND
                       (is_archived = 0 OR (is_enabled = 0 AND type = 'iCloud')));
            DROP INDEX idx_accounts_single_icloud;
            CREATE UNIQUE INDEX idx_accounts_single_icloud ON accounts(type)
                WHERE type = 'iCloud' AND is_archived = 0;
            CREATE TRIGGER archive_accounts_insert BEFORE INSERT ON accounts
                WHEN NEW.is_archived = 1 OR EXISTS (
                    SELECT 1 FROM accounts WHERE id = NEW.id AND is_archived = 1)
                BEGIN SELECT RAISE(ABORT, 'readonly local archive'); END;
            CREATE TRIGGER archive_accounts_transition BEFORE UPDATE OF is_archived ON accounts
                WHEN NEW.is_archived = 1 AND OLD.is_archived = 0 AND NOT EXISTS (
                    SELECT 1 FROM icloud_sync_scope WHERE account_id = OLD.id
                    AND capture_enabled = 0 AND suppress_capture = 1 AND pause_reason IS NOT NULL)
                BEGIN SELECT RAISE(ABORT, 'archive scope must be suspended'); END;
            CREATE TRIGGER archive_accounts_update BEFORE UPDATE ON accounts
                WHEN OLD.is_archived = 1
                BEGIN SELECT RAISE(ABORT, 'readonly local archive'); END;
            CREATE TRIGGER archive_accounts_delete BEFORE DELETE ON accounts
                WHEN OLD.is_archived = 1
                BEGIN SELECT RAISE(ABORT, 'readonly local archive'); END;
            """)

        for table in ["feeds", "folders", "items", "account_sync_state",
                      "icloud_sync_scope", "icloud_sync_changes", "icloud_record_mappings",
                      "icloud_records", "icloud_content_changes"] {
            try guardTable(table, in: db) { archived("\($0).account_id") }
        }
        for table in ["articles", "article_states", "article_caches"] {
            try guardTable(table, in: db) { archived(itemAccount("\($0).item_id")) }
        }
        for table in ["ai_artifacts", "article_state_outbox", "translation_article_exemptions"] {
            try guardTable(table, in: db) {
                var condition = "\(archived("\($0).account_id")) OR \(archived(itemAccount("\($0).item_id")))"
                if table == "ai_artifacts" { condition += " OR \(archived(itemAccount("\($0).subject_key")))" }
                return condition
            }
        }
        try guardTable("translation_feed_lists", in: db) {
            "\(archived("\($0).account_id")) OR \(archived(parentAccount("feeds", id: "\($0).feed_id")))"
        }
        try guardTable("feed_folders", in: db) {
            "\(archived(parentAccount("feeds", id: "\($0).feed_id"))) OR \(archived(parentAccount("folders", id: "\($0).folder_id")))"
        }
        try guardTable("source_language_hints", in: db) { row in
            [ ("article", "items"), ("feed", "feeds"), ("folder", "folders") ].map { scope, table in
                "(\(row).scope = '\(scope)' AND \(archived(parentAccount(table, id: "\(row).entity_id"))))"
            }.joined(separator: " OR ")
        }
    }

    private static func archived(_ account: String) -> String {
        "EXISTS (SELECT 1 FROM accounts WHERE id = \(account) AND is_archived = 1)"
    }
    private static func itemAccount(_ id: String) -> String { parentAccount("items", id: id) }
    private static func parentAccount(_ table: String, id: String) -> String {
        "(SELECT account_id FROM \(table) WHERE id = \(id))"
    }
    private static func guardTable(_ table: String, in db: Database,
                                   predicate: (String) -> String) throws {
        let keys = try db.primaryKey(table).columns
        for (operation, rows) in [("INSERT", ["NEW"]), ("UPDATE", ["OLD", "NEW"]), ("DELETE", ["OLD"])] {
            var condition = rows.map { "(\(predicate($0)))" }.joined(separator: " OR ")
            if operation == "INSERT" {
                // REPLACE does not reliably fire DELETE triggers when recursive
                // triggers are off. Protect an existing archived primary key.
                let matchingKey = keys.map { "existing.\($0) IS NEW.\($0)" }.joined(separator: " AND ")
                condition += " OR EXISTS (SELECT 1 FROM \(table) existing WHERE \(matchingKey) AND (\(predicate("existing"))))"
            }
            try db.execute(sql: """
                CREATE TRIGGER archive_\(table)_\(operation.lowercased()) BEFORE \(operation) ON \(table)
                    WHEN \(condition)
                    BEGIN SELECT RAISE(ABORT, 'readonly local archive'); END;
                """)
        }
    }
}
