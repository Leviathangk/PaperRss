import Foundation
import GRDB

public enum ICloudSyncChangeKind: String, Codable, Sendable, CaseIterable {
    case feed, folder, membership, read, starred
}

/// Local queue addresses are not CloudKit record names. The transport must map
/// them through portable source identities / folder mappings before sending.
public struct ICloudSyncChange: Sendable, Equatable {
    public let accountID: String
    public let kind: ICloudSyncChangeKind
    public let entityID: String
    public let revision: Int64
    public let payloadJSON: String
    public let isTombstone: Bool
}

public enum ICloudSyncRepositoryError: Error, Equatable {
    case unsupportedAccount
    case inactiveScope
    case remoteBatchRequired
    case wrongAccount
    case missingItem
}

/// Durable, opt-in capture foundation. P1 deliberately has no network entry
/// point and never creates a scope merely by opening/migrating a database.
public final class ICloudSyncRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Development integration API; the final UI will activate an independent
    /// iCloud account, rather than silently converting local-default.
    public func setCaptureEnabled(accountID: String, enabled: Bool) throws {
        try database.write { db in
            guard let type = try String.fetchOne(db, sql: "SELECT type FROM accounts WHERE id = ?", arguments: [accountID]),
                  type == AccountType.local.rawValue || type == AccountType.iCloud.rawValue else {
                throw ICloudSyncRepositoryError.unsupportedAccount
            }
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope (account_id, capture_enabled)
                VALUES (?, ?)
                ON CONFLICT(account_id) DO UPDATE SET capture_enabled = excluded.capture_enabled;
                """, arguments: [accountID, enabled])
            try ICloudRecordSchema.ensureDeviceIdentity(accountID: accountID, in: db)
            if enabled {
                try ICloudSyncSchema.captureBaseline(accountID: accountID, in: db)
            }
        }
    }

    public func pendingChanges(accountID: String, limit: Int = 150) throws -> [ICloudSyncChange] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT account_id, kind, entity_id, revision, payload_json, is_tombstone
                FROM icloud_sync_changes
                WHERE account_id = ? AND is_pending = 1
                ORDER BY changed_at, kind, entity_id LIMIT ?;
                """, arguments: [accountID, limit]).map { row in
                // The migration CHECK constraint guarantees a supported kind.
                ICloudSyncChange(
                    accountID: row["account_id"],
                    kind: ICloudSyncChangeKind(rawValue: row["kind"])!,
                    entityID: row["entity_id"], revision: row["revision"],
                    payloadJSON: row["payload_json"], isTombstone: row["is_tombstone"]
                )
            }
        }
    }

    /// Confirm only the exact immutable snapshot accepted by the server.
    /// Retain revisions after confirmation to prevent the ABA problem.
    @discardableResult
    public func acknowledge(_ change: ICloudSyncChange) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE icloud_sync_changes SET is_pending = 0
                WHERE account_id = ? AND kind = ? AND entity_id = ?
                  AND revision = ? AND is_pending = 1;
                """, arguments: [change.accountID, change.kind.rawValue, change.entityID, change.revision])
            return db.changesCount == 1
        }
    }

    public func engineState(accountID: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])
        }
    }

    /// The future engine uses this boundary to commit received records and a
    /// corresponding checkpoint together. Failures also roll back suppression.
    /// Internal: no View receives a raw GRDB Database.
    @discardableResult
    func applyRemoteBatch<T>(
        accountID: String, engineState: Data?, apply: (Database) throws -> T
    ) throws -> T {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT capture_enabled FROM icloud_sync_scope WHERE account_id = ?;
                """, arguments: [accountID]) == true else {
                throw ICloudSyncRepositoryError.inactiveScope
            }
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 1 WHERE account_id = ?", arguments: [accountID])
            let result = try apply(db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 0 WHERE account_id = ?", arguments: [accountID])
            if let engineState {
                try db.execute(sql: "UPDATE icloud_sync_scope SET engine_state = ? WHERE account_id = ?", arguments: [engineState, accountID])
            }
            return result
        }
    }

    /// Pending read and starred intents are protected independently, matching
    /// NetNewsWire's receive behavior. Missing items fail the batch so a cursor
    /// cannot advance until the caller durably stores an incoming identity.
    @discardableResult
    func applyRemoteArticleState(
        accountID: String, itemID: String, isRead: Bool?, isStarred: Bool?, in db: Database
    ) throws -> Bool {
        guard try Bool.fetchOne(db, sql: "SELECT suppress_capture FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]) == true else {
            throw ICloudSyncRepositoryError.remoteBatchRequired
        }
        guard let owner = try String.fetchOne(db, sql: "SELECT account_id FROM items WHERE id = ?", arguments: [itemID]) else {
            throw ICloudSyncRepositoryError.missingItem
        }
        guard owner == accountID else { throw ICloudSyncRepositoryError.wrongAccount }
        let now = Date().timeIntervalSince1970
        var state = try ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db) ??
            ArticleStateRecord(itemID: itemID, isRead: false, isStarred: false, dateArrived: now, updatedAt: now)
        let acceptsRead = try isRead != nil && !hasPendingChange(accountID: accountID, kind: .read, entityID: itemID, in: db)
        let acceptsStarred = try isStarred != nil && !hasPendingChange(accountID: accountID, kind: .starred, entityID: itemID, in: db)
        guard acceptsRead || acceptsStarred else { return true }
        if let isRead, acceptsRead { state.isRead = isRead }
        if let isStarred, acceptsStarred { state.isStarred = isStarred }
        state.updatedAt = now
        try state.save(db)
        if acceptsRead {
            try ICloudSyncSchema.recordRemoteStateSnapshot(accountID: accountID, itemID: itemID, kind: "read", in: db)
        }
        if acceptsStarred {
            try ICloudSyncSchema.recordRemoteStateSnapshot(accountID: accountID, itemID: itemID, kind: "starred", in: db)
        }
        return true
    }

    private func hasPendingChange(
        accountID: String, kind: ICloudSyncChangeKind, entityID: String, in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT is_pending FROM icloud_sync_changes
            WHERE account_id = ? AND kind = ? AND entity_id = ?;
            """, arguments: [accountID, kind.rawValue, entityID]) ?? false
    }
}
