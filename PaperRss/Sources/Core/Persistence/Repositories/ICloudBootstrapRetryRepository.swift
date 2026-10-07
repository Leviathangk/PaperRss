import Foundation
import GRDB

extension ICloudRecordRepository {
    func bootstrapRetryState() async throws -> ICloudBootstrapRetryState {
        try await database.readAsync { db in
            try self.requireScope(in: db)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else {
                throw ICloudRecordError.unavailableScope
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT root_retry_at, root_retry_attempt, root_retry_revision
                FROM icloud_sync_scope WHERE account_id = ?;
                """, arguments: [self.accountID])!
            let timestamp: Double? = row["root_retry_at"]
            if let timestamp, !timestamp.isFinite { throw ICloudRecordError.persistenceFailed }
            return .init(deadline: timestamp.map(Date.init(timeIntervalSince1970:)),
                attempt: row["root_retry_attempt"], revision: row["root_retry_revision"])
        }
    }

    /// Repeated foreground requests reuse the same waiting window. They cannot
    /// keep pushing retryAfter into the future or consume another attempt.
    func scheduleBootstrapRetry(for error: any Error, now: Date) async throws -> Date? {
        try await database.writeAsync { db in
            try self.requireScope(in: db)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else {
                throw ICloudRecordError.unavailableScope
            }
            let row = try Row.fetchOne(db, sql: "SELECT root_retry_at, root_retry_attempt FROM icloud_sync_scope WHERE account_id = ?",
                                       arguments: [self.accountID])!
            if let timestamp: Double = row["root_retry_at"], timestamp > now.timeIntervalSince1970 {
                guard timestamp.isFinite else { throw ICloudRecordError.persistenceFailed }
                return Date(timeIntervalSince1970: timestamp)
            }
            let attempt = min(30, row["root_retry_attempt"] as Int) + 1
            guard let delay = ICloudBootstrapRetryPolicy.delay(for: error, attempt: attempt) else { return nil }
            let deadline = now.addingTimeInterval(delay)
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET root_retry_at = ?, root_retry_attempt = ?,
                    root_retry_revision = root_retry_revision + 1 WHERE account_id = ?;
                """, arguments: [deadline.timeIntervalSince1970, attempt, self.accountID])
            return deadline
        }
    }

    func clearBootstrapRetry(expectedRevision: Int64? = nil) async throws {
        try await database.writeAsync { db in
            try self.requireScope(in: db)
            guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else { return }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET root_retry_at = NULL, root_retry_attempt = 0,
                    root_retry_revision = root_retry_revision + 1
                WHERE account_id = ? AND (root_retry_at IS NOT NULL OR root_retry_attempt != 0)
                    AND (? IS NULL OR root_retry_revision = ?);
                """, arguments: [self.accountID, expectedRevision, expectedRevision])
        }
    }
}
