import Foundation
import GRDB

/// 负责将本地离线/异步状态突变 (ArticleStateOutbox) 可靠推送到 FreshRSS 远端。
///
/// 遵循 Architecture Contract (Section 9, 12 / INV-07, INV-08)。
/// 严格遵守 In-flight Race 保护机制：成功时仅根据当时的 (item_id, state_key, revision) 原子删除。
public actor ArticleStateOutboxProcessor {
    private let accountID: String
    private let database: LibraryDatabase
    private let apiClient: ReaderAPIClient
    private var isProcessing = false
    private var needsAnotherPass = false
    private var forceNextPass = false

    public init(
        accountID: String,
        database: LibraryDatabase,
        apiClient: ReaderAPIClient
    ) {
        self.accountID = accountID
        self.database = database
        self.apiClient = apiClient
    }

    public struct ProcessResult: Sendable, Equatable {
        public var processedCount: Int
        public var successCount: Int
        public var failureCount: Int

        public init(processedCount: Int = 0, successCount: Int = 0, failureCount: Int = 0) {
            self.processedCount = processedCount
            self.successCount = successCount
            self.failureCount = failureCount
        }
    }

    /// 处理当前就绪的待出站状态记录。
    @discardableResult
    public func processOutbox(forceAll: Bool = false) async throws -> ProcessResult {
        // Actors can reenter while a request is suspended. Coalesce callers rather
        // than sending the same snapshot concurrently (possibly out of order).
        if isProcessing {
            needsAnotherPass = true
            forceNextPass = forceNextPass || forceAll
            return ProcessResult()
        }
        isProcessing = true
        defer { isProcessing = false }
        var result = ProcessResult()
        var force = forceAll
        repeat {
            needsAnotherPass = false
            forceNextPass = false
            let pass = try await processPass(forceAll: force)
            result.processedCount += pass.processedCount
            result.successCount += pass.successCount
            result.failureCount += pass.failureCount
            force = forceNextPass
        } while needsAnotherPass
        return result
    }

    private func accountIsEnabled() throws -> Bool {
        try database.read { db in
            guard let account = try AccountRecord.fetchOne(db, key: self.accountID) else { return false }
            return account.isEnabled && !account.isArchived
        }
    }

    private func processPass(forceAll: Bool) async throws -> ProcessResult {
        guard try accountIsEnabled() else { return ProcessResult() }
        try Task.checkCancellation()
        let now = Date().timeIntervalSince1970
        let readyRows = try database.read { db in
            var query = ArticleStateOutboxRecord.filter(Column("account_id") == self.accountID)
            if !forceAll {
                query = query.filter(Column("next_attempt_at") == nil || Column("next_attempt_at") <= now)
            }
            return try query.order(Column("updated_at").asc).fetchAll(db)
        }
        guard !readyRows.isEmpty else { return ProcessResult() }

        var result = ProcessResult()
        // Keep each batch within the API client's single-request limit so partial
        // success is acknowledged immediately, without replaying earlier batches.
        for stateKey in ["read", "starred"] {
            for desiredValue in [true, false] {
                let group = readyRows.filter { $0.stateKey == stateKey && $0.desiredValue == desiredValue }
                for start in stride(from: 0, to: group.count, by: 50) {
                    try Task.checkCancellation()
                    guard try accountIsEnabled() else { return result }
                    let snapshot = Array(group[start..<min(start + 50, group.count)])
                    // Revalidate just before sending: an earlier network await may
                    // have allowed a newer local intent to replace this snapshot.
                    let batch: [(ArticleStateOutboxRecord, String?)] = try database.read { db in
                        try snapshot.compactMap { row in
                            guard let current = try ArticleStateOutboxRecord
                                .filter(Column("account_id") == self.accountID && Column("item_id") == row.itemID && Column("state_key") == row.stateKey)
                                .fetchOne(db), current.revision == row.revision else { return nil }
                            let externalID = try ItemRecord
                                .filter(Column("account_id") == self.accountID && Column("id") == row.itemID)
                                .fetchOne(db)?.externalID
                            return (row, externalID)
                        }
                    }
                    var validRows: [ArticleStateOutboxRecord] = []
                    var externalIDs: [String] = []
                    for (row, externalID) in batch {
                        result.processedCount += 1
                        guard let externalID, !externalID.isEmpty else {
                            result.failureCount += 1
                            try recordFailure([row], message: "Missing item or external_id")
                            continue
                        }
                        validRows.append(row)
                        externalIDs.append(externalID)
                    }
                    guard !validRows.isEmpty else { continue }
                    do {
                        if stateKey == "read" {
                            try await apiClient.markRead(itemIDs: externalIDs, isRead: desiredValue)
                        } else {
                            try await apiClient.markStarred(itemIDs: externalIDs, isStarred: desiredValue)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result.failureCount += validRows.count
                        try recordFailure(validRows, message: error.localizedDescription)
                        continue
                    }
                    result.successCount += try database.write { db in
                        var deleted = 0
                        for row in validRows {
                            deleted += try ArticleStateOutboxRecord
                                .filter(Column("account_id") == self.accountID && Column("item_id") == row.itemID && Column("state_key") == row.stateKey && Column("revision") == row.revision)
                                .deleteAll(db)
                        }
                        return deleted
                    }
                }
            }
        }
        return result
    }

    private func recordFailure(_ rows: [ArticleStateOutboxRecord], message: String) throws {
        try database.write { db in
            for row in rows {
                guard var current = try ArticleStateOutboxRecord
                    .filter(Column("account_id") == self.accountID && Column("item_id") == row.itemID && Column("state_key") == row.stateKey)
                    .fetchOne(db), current.revision == row.revision else { continue }
                current.attemptCount += 1
                current.nextAttemptAt = Date().timeIntervalSince1970 + min(pow(2.0, Double(min(current.attemptCount, 6))), 60.0)
                current.lastError = message
                current.updatedAt = Date().timeIntervalSince1970
                try current.save(db)
            }
        }
    }
}
