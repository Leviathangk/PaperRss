import GRDB

/// All capture happens on the business writer's transaction, including bulk SQL
/// and direct Record.save paths. No scope is created or enabled by migration.
enum ICloudSyncSchema {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE items ADD COLUMN source_item_id TEXT;

            CREATE TABLE icloud_sync_scope (
                account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                capture_enabled INTEGER NOT NULL DEFAULT 0 CHECK (capture_enabled IN (0, 1)),
                suppress_capture INTEGER NOT NULL DEFAULT 0 CHECK (suppress_capture IN (0, 1)),
                engine_state BLOB
            );

            CREATE TABLE icloud_sync_changes (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK (kind IN ('feed', 'folder', 'membership', 'read', 'starred')),
                entity_id TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK (revision > 0),
                payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
                is_tombstone INTEGER NOT NULL CHECK (is_tombstone IN (0, 1)),
                is_pending INTEGER NOT NULL CHECK (is_pending IN (0, 1)),
                changed_at REAL NOT NULL,
                PRIMARY KEY (account_id, kind, entity_id)
            );
            CREATE INDEX idx_icloud_sync_pending
            ON icloud_sync_changes(account_id, is_pending, changed_at);
            """)
        try installTriggers(in: db)
    }

    static func installTriggers(in db: Database, versioned: Bool = false) throws {
        for structure in structures {
            let insert = enqueue(
                account: structure.account("NEW"), kind: structure.kind,
                entity: structure.entity("NEW"), payload: structure.payload("NEW"),
                tombstone: structure.tombstone("NEW"), intent: versioned ? "1" : nil
            )
            let update = enqueue(
                account: structure.account("NEW"), kind: structure.kind,
                entity: structure.entity("NEW"), payload: structure.payload("NEW"),
                tombstone: structure.tombstone("NEW"), condition: structure.changed,
                intent: versioned ? "1" : nil
            )
            let account = structure.account("OLD")
            let entity = structure.entity("OLD")
            // During FK cascades a parent row may already be gone. Keep the
            // previous white-listed snapshot rather than querying deleted data.
            let previousPayload = """
                COALESCE(
                    (SELECT payload_json FROM icloud_sync_changes
                     WHERE account_id = \(account) AND kind = '\(structure.kind)' AND entity_id = \(entity)),
                    \(structure.payload("OLD"))
                )
                """
            let delete = enqueue(
                account: account, kind: structure.kind, entity: entity,
                payload: previousPayload, tombstone: "1", intent: versioned ? "1" : nil
            )
            try db.execute(sql: """
                CREATE TRIGGER icloud_\(structure.kind)_insert AFTER INSERT ON \(structure.table)
                BEGIN \(insert); END;
                CREATE TRIGGER icloud_\(structure.kind)_update AFTER UPDATE ON \(structure.table)
                BEGIN \(update); END;
                CREATE TRIGGER icloud_\(structure.kind)_delete BEFORE DELETE ON \(structure.table)
                BEGIN \(delete); END;
                """)
        }

        // Relationship primary keys can also be changed by a direct UPDATE.
        let relationship = structures[2]
        let membershipChanged = "NEW.feed_id IS NOT OLD.feed_id OR NEW.folder_id IS NOT OLD.folder_id"
        try db.execute(sql: """
            CREATE TRIGGER icloud_membership_rekey BEFORE UPDATE ON feed_folders
            BEGIN \(enqueue(
                account: relationship.account("OLD"), kind: "membership",
                entity: relationship.entity("OLD"), payload: relationship.payload("OLD"),
                tombstone: "1", condition: membershipChanged, intent: versioned ? "1" : nil
            )); END;
            """)

        for (kind, column) in stateFields {
            let snapshot = statePayload(kind: kind, row: "NEW")
            try db.execute(sql: """
                CREATE TRIGGER icloud_\(kind)_insert AFTER INSERT ON article_states
                BEGIN \(enqueue(account: stateAccount(row: "NEW"), kind: kind,
                    entity: "NEW.item_id", payload: snapshot,
                    intent: versioned ? "CASE WHEN NEW.\(column) = 0 THEN 0 ELSE 1 END" : nil)); END;
                CREATE TRIGGER icloud_\(kind)_update AFTER UPDATE OF \(column) ON article_states
                BEGIN \(enqueue(account: stateAccount(row: "NEW"), kind: kind,
                    entity: "NEW.item_id", payload: snapshot,
                    condition: "NEW.\(column) IS NOT OLD.\(column)",
                    intent: versioned ? "1" : nil)); END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER icloud_\(kind)_identity AFTER UPDATE OF source_item_id ON items
                BEGIN \(enqueue(
                    account: "NEW.account_id", kind: kind, entity: "s.item_id",
                    payload: statePayload(kind: kind, row: "s"),
                    source: "article_states s",
                    condition: "s.item_id = NEW.id AND NEW.source_item_id IS NOT OLD.source_item_id",
                    intent: versioned ? """
                        COALESCE((SELECT is_user_intent FROM icloud_sync_changes
                                  WHERE account_id = NEW.account_id AND kind = '\(kind)' AND entity_id = s.item_id),
                                 CASE WHEN s.\(column) = 0 THEN 0 ELSE 1 END)
                        """ : nil
                )); END;
                """)
        }
        // Deleting a local body/cache or expiring an Item is not a user change
        // to read/starred. Structural tombstones handle subscription deletion.
    }

    static func captureBaseline(accountID: String, in db: Database) throws {
        for structure in structures {
            try db.execute(sql: enqueue(
                account: structure.account("r"), kind: structure.kind,
                entity: structure.entity("r"), payload: structure.payload("r"),
                tombstone: structure.tombstone("r"), source: "\(structure.table) r",
                condition: "\(structure.account("r")) = ?", onlyIfSnapshotChanged: true, intent: "1"
            ), arguments: [accountID])
        }
        for (kind, column) in stateFields {
            try db.execute(sql: enqueue(
                account: stateAccount(row: "s"), kind: kind,
                entity: "s.item_id", payload: statePayload(kind: kind, row: "s"),
                source: "article_states s", condition: "\(stateAccount(row: "s")) = ?",
                onlyIfSnapshotChanged: true,
                intent: "CASE WHEN s.\(column) = 0 THEN 0 ELSE 1 END"
            ), arguments: [accountID])
        }
        // A developer can suspend capture. Re-enable must also reconcile
        // deletions made while it was suspended, using retained snapshots.
        for structure in structures {
            let stillExists = """
                EXISTS (SELECT 1 FROM \(structure.table) r
                        WHERE \(structure.entity("r")) = c.entity_id
                          AND \(structure.account("r")) = c.account_id)
                """
            try db.execute(sql: """
                UPDATE icloud_sync_changes AS c
                SET revision = revision + 1, is_tombstone = 1, is_pending = 1, is_user_intent = 1,
                    changed_at = (julianday('now') - 2440587.5) * 86400.0
                WHERE account_id = ? AND kind = '\(structure.kind)'
                  AND is_tombstone = 0 AND NOT \(stillExists);
                """, arguments: [accountID])
        }
    }

    static func recordRemoteStateSnapshot(
        accountID: String, itemID: String, kind: String, in db: Database
    ) throws {
        // Keep a clean snapshot so a later baseline does not echo this remote
        // change. A pending field is never overwritten.
        try db.execute(sql: """
            INSERT INTO icloud_sync_changes
                (account_id, kind, entity_id, revision, payload_json, is_tombstone, is_pending, changed_at)
            SELECT ?, '\(kind)', s.item_id, 1, \(statePayload(kind: kind, row: "s")), 0, 0,
                   (julianday('now') - 2440587.5) * 86400.0
            FROM article_states s WHERE s.item_id = ?
            ON CONFLICT(account_id, kind, entity_id) DO UPDATE SET
                revision = icloud_sync_changes.revision + 1,
                payload_json = excluded.payload_json, changed_at = excluded.changed_at
            WHERE icloud_sync_changes.is_pending = 0
              AND icloud_sync_changes.payload_json IS NOT excluded.payload_json;
            """, arguments: [accountID, itemID])
    }

    static func recordRemoteSnapshot(
        accountID: String, kind: ICloudSyncChangeKind, entityID: String,
        versionsJSON: String, tombstone: Bool, in db: Database
    ) throws {
        let payload: String
        if let structure = structures.first(where: { $0.kind == kind.rawValue }) {
            payload = """
                (SELECT \(structure.payload("r")) FROM \(structure.table) r
                 WHERE \(structure.account("r")) = :account AND \(structure.entity("r")) = :entity)
                """
        } else {
            payload = """
                (SELECT \(statePayload(kind: kind.rawValue, row: "s")) FROM article_states s
                 WHERE s.item_id = :entity AND \(stateAccount(row: "s")) = :account)
                """
        }
        try db.execute(sql: """
            INSERT INTO icloud_sync_changes
                (account_id, kind, entity_id, revision, payload_json, is_tombstone,
                 is_pending, changed_at, is_user_intent, field_versions_json)
            SELECT :account, :kind, :entity, 1, \(payload), :deleted, 0,
                   (julianday('now') - 2440587.5) * 86400.0, 0, :versions
            WHERE \(payload) IS NOT NULL
            ON CONFLICT(account_id, kind, entity_id) DO UPDATE SET
                payload_json = excluded.payload_json, is_tombstone = excluded.is_tombstone,
                field_versions_json = excluded.field_versions_json, is_user_intent = 0
            WHERE icloud_sync_changes.is_pending = 0;
            """, arguments: ["account": accountID, "kind": kind.rawValue, "entity": entityID,
                             "deleted": tombstone, "versions": versionsJSON])
        if tombstone {
            try db.execute(sql: """
                UPDATE icloud_sync_changes SET is_tombstone = 1, field_versions_json = ?, is_user_intent = 0
                WHERE account_id = ? AND kind = ? AND entity_id = ? AND is_pending = 0;
                """, arguments: [versionsJSON, accountID, kind.rawValue, entityID])
        }
    }

    private struct Structure {
        let table: String
        let kind: String
        let account: (String) -> String
        let entity: (String) -> String
        let payload: (String) -> String
        let tombstone: (String) -> String
        let changed: String
    }

    private static var structures: [Structure] {
        [
            Structure(
                table: "feeds", kind: "feed", account: { "\($0).account_id" },
                entity: { "\($0).id" },
                payload: { r in """
                    json_object('feed_id', \(r).id, 'feed_url', \(r).feed_url,
                                'title', \(r).title, 'site_url', \(r).site_url,
                                'sort_order', \(r).sort_order)
                    """ },
                tombstone: { "\($0).is_deleted" },
                changed: """
                    NEW.feed_url IS NOT OLD.feed_url OR NEW.title IS NOT OLD.title
                    OR NEW.site_url IS NOT OLD.site_url OR NEW.sort_order IS NOT OLD.sort_order
                    OR NEW.is_deleted IS NOT OLD.is_deleted
                    """
            ),
            Structure(
                table: "folders", kind: "folder", account: { "\($0).account_id" },
                entity: { "\($0).id" },
                payload: { r in """
                    json_object('folder_id', \(r).id, 'name', \(r).name, 'sort_order', \(r).sort_order)
                    """ },
                tombstone: { "\($0).is_deleted" },
                changed: """
                    NEW.name IS NOT OLD.name OR NEW.sort_order IS NOT OLD.sort_order
                    OR NEW.is_deleted IS NOT OLD.is_deleted
                    """
            ),
            Structure(
                table: "feed_folders", kind: "membership",
                account: { r in """
                    COALESCE(
                        (SELECT account_id FROM feeds WHERE id = \(r).feed_id),
                        (SELECT account_id FROM icloud_sync_changes
                         WHERE kind = 'membership' AND entity_id = json_array(\(r).feed_id, \(r).folder_id))
                    )
                    """ },
                entity: { "json_array(\($0).feed_id, \($0).folder_id)" },
                payload: { r in """
                    json_object('feed_id', \(r).feed_id, 'folder_id', \(r).folder_id)
                    """ },
                tombstone: { _ in "0" },
                changed: "NEW.feed_id IS NOT OLD.feed_id OR NEW.folder_id IS NOT OLD.folder_id"
            )
        ]
    }

    private static var stateFields: [(String, String)] {
        [("read", "is_read"), ("starred", "is_starred")]
    }

    private static func stateAccount(row: String) -> String {
        "(SELECT account_id FROM items WHERE id = \(row).item_id)"
    }

    private static func statePayload(kind: String, row: String) -> String {
        let column = kind == "read" ? "is_read" : "is_starred"
        return """
            json_object(
                'item_id', \(row).item_id, 'value', \(row).\(column),
                'source_item_id', (SELECT source_item_id FROM items WHERE id = \(row).item_id),
                'feed_url', (SELECT f.feed_url FROM items i JOIN feeds f ON f.id = i.feed_id
                             WHERE i.id = \(row).item_id)
            )
            """
    }

    /// SQL arguments below are schema-owned expressions, never user strings.
    private static func enqueue(
        account: String, kind: String, entity: String, payload: String,
        tombstone: String = "0", source: String? = nil, condition: String = "1",
        onlyIfSnapshotChanged: Bool = false, intent: String? = nil
    ) -> String {
        """
        INSERT INTO icloud_sync_changes
            (account_id, kind, entity_id, revision, payload_json, is_tombstone, is_pending, changed_at\(intent == nil ? "" : ", is_user_intent"))
        SELECT \(account), '\(kind)', \(entity), 1, \(payload), \(tombstone), 1,
               (julianday('now') - 2440587.5) * 86400.0\(intent.map { ", \($0)" } ?? "")
        \(source.map { "FROM \($0)" } ?? "")
        WHERE (\(condition)) AND EXISTS (
            SELECT 1 FROM icloud_sync_scope
            WHERE account_id = \(account) AND capture_enabled = 1 AND suppress_capture = 0
        )
        ON CONFLICT(account_id, kind, entity_id) DO UPDATE SET
            revision = icloud_sync_changes.revision + 1,
            payload_json = excluded.payload_json, is_tombstone = excluded.is_tombstone,
            is_pending = 1, changed_at = excluded.changed_at\(intent == nil ? "" : ", is_user_intent = excluded.is_user_intent")
        \(onlyIfSnapshotChanged ? """
        WHERE icloud_sync_changes.payload_json IS NOT excluded.payload_json
           OR icloud_sync_changes.is_tombstone IS NOT excluded.is_tombstone
        """ : "")
        """
    }
}
