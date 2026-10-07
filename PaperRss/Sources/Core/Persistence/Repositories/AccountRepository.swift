import Foundation
import GRDB

/// 管理账号主数据与同步状态的持久化仓库。
///
/// 遵循 Architecture Contract (Section 13.1 / INV-01, INV-02)。
public final class AccountRepository: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Database-Scoped Primitives (for Migration & Atomic Transactions)

    public func fetchAllAccounts(in db: Database) throws -> [AccountRecord] {
        try AccountRecord.order(Column("created_at").asc).fetchAll(db)
    }

    public func fetchAccount(id: String, in db: Database) throws -> AccountRecord? {
        try AccountRecord.filter(Column("id") == id).fetchOne(db)
    }

    public func saveAccount(_ record: AccountRecord, in db: Database) throws {
        try record.save(db)
    }

    public func updateAccountEnabled(id: String, isEnabled: Bool, in db: Database) throws {
        guard try fetchAccount(id: id, in: db)?.isArchived != true else {
            throw ICloudArchiveRecoveryError.readonlyArchive
        }
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE accounts SET is_enabled = ?, updated_at = ? WHERE id = ?;",
            arguments: [isEnabled ? 1 : 0, now, id]
        )
    }

    public func deleteAccount(id: String, in db: Database) throws {
        try validateAccountRemoval(id: id, in: db)
        _ = try AccountRecord.filter(Column("id") == id).deleteAll(db)
    }

    private func validateAccountRemoval(id: String, in db: Database) throws {
        guard try fetchAccount(id: id, in: db)?.isArchived != true else {
            throw ICloudArchiveRecoveryError.readonlyArchive
        }
        guard try fetchAccount(id: id, in: db)?.type == AccountType.iCloud.rawValue,
              try db.tableExists("icloud_sync_scope"),
              try db.columns(in: "icloud_sync_scope").contains(where: { $0.name == "cloud_reset_operation" }) else { return }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM icloud_sync_scope WHERE account_id = ? AND cloud_reset_operation IS NOT NULL);
            """, arguments: [id]) == true {
            // Keep approval and recovery evidence until its separate review has
            // decided how to retain/export/remove this account's old cache.
            throw ICloudCloudResetError.operationInProgress
        }
    }

    public func fetchSyncState(accountID: String, in db: Database) throws -> AccountSyncStateRecord? {
        try AccountSyncStateRecord.filter(Column("account_id") == accountID).fetchOne(db)
    }

    public func saveSyncState(_ record: AccountSyncStateRecord, in db: Database) throws {
        try record.save(db)
    }

    // MARK: - Async Public APIs

    public func fetchAllAccounts() async throws -> [AccountRecord] {
        try database.read { db in
            try fetchAllAccounts(in: db)
        }
    }

    public func fetchAccount(id: String) async throws -> AccountRecord? {
        try database.read { db in
            try fetchAccount(id: id, in: db)
        }
    }

    public func updateAccountEnabled(id: String, isEnabled: Bool) async throws {
        try database.write { db in
            try updateAccountEnabled(id: id, isEnabled: isEnabled, in: db)
        }
    }

    public func saveAccount(_ record: AccountRecord) async throws {
        try database.write { db in
            try saveAccount(record, in: db)
        }
    }

    public func saveAccountAtomicWithDuplicateCheck(_ record: AccountRecord) async throws {
        try database.write { db in
            if let accountType = AccountType(rawValue: record.type),
               let variant = accountType.readerVariant,
               let ep = record.endpointURL,
               let un = record.username {
                let canonical = (URL(string: ep).map { ReaderAPIClient.canonicalBaseURL(for: $0, variant: variant).absoluteString }) ?? ep
                let existing = try AccountRecord
                    .filter(Column("type") == record.type && Column("username") == un)
                    .fetchAll(db)
                    .first { acc in
                        guard let existingEP = acc.endpointURL else { return false }
                        let existingCanonical = (URL(string: existingEP).map { ReaderAPIClient.canonicalBaseURL(for: $0, variant: variant).absoluteString }) ?? existingEP
                        return existingCanonical == canonical
                    }
                if let existing {
                    throw ReaderAPIError.accountAlreadyExists("\(un) @ \(canonical) (ID: \(existing.id))")
                }
            }
            try saveAccount(record, in: db)
        }
    }

    public func deleteAccount(id: String) async throws {
        try database.write { db in
            try deleteAccount(id: id, in: db)
        }
    }

    public func validateAccountRemoval(id: String) async throws {
        try await database.readAsync { try self.validateAccountRemoval(id: id, in: $0) }
    }

    public func fetchSyncState(accountID: String) async throws -> AccountSyncStateRecord? {
        try database.read { db in
            try fetchSyncState(accountID: accountID, in: db)
        }
    }

    public func saveSyncState(_ record: AccountSyncStateRecord) async throws {
        try database.write { db in
            try saveSyncState(record, in: db)
        }
    }
}
