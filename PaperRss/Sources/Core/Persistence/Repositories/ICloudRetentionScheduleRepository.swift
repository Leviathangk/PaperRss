import Foundation
import GRDB

extension ICloudRecordRepository {
    func retentionScheduleState(approvalID: String) async throws -> ICloudRetentionScheduleState {
        try await database.readAsync { db in try self.retentionSchedule(approvalID: approvalID, in: db) }
    }
    func setRetentionScheduleEnabled(_ enabled: Bool, approvalID: String) async throws -> ICloudRetentionScheduleState {
        try await database.writeAsync { db in
            let row = try self.retentionJobScope(in: db)
            let job = try self.approvedScheduledJob(approvalID: approvalID, scope: row)
            if enabled { try self.requireMaintenanceExecution(job.approval, scope: row) }
            guard !enabled || (job.approval.allowsClockMaintenance && !job.isFinished) else { throw ICloudRetentionJobError.approvalMismatch }
            try db.execute(sql: "UPDATE icloud_sync_scope SET retention_schedule_enabled=? WHERE account_id=?",
                           arguments: [enabled, self.accountID])
            return try self.retentionSchedule(approvalID: approvalID, in: db)
        }
    }
    func scheduleRetentionWake(approvalID: String, for error: (any Error)?, now: Date) async throws -> Date? {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw ICloudRetentionJobError.invalidJob }
        return try await database.writeAsync { db in
            let state = try self.retentionSchedule(approvalID: approvalID, in: db)
            guard state.enabled else { throw ICloudRetentionJobError.approvalMismatch }
            if let deadline = state.deadline { return deadline } // Do not consume attempts or postpone an existing wait.
            let attempt = error == nil ? 0 : min(30, state.attempt) + 1
            guard let delay = error.map({ ICloudRetentionSchedulingPolicy.delay(for: $0, attempt: attempt) }) ?? ICloudRetentionSchedulingPolicy.interval else { return nil }
            guard delay.isFinite, delay > 0, delay <= ICloudBootstrapRetryPolicy.maximumDelay,
                  state.revision < Int64.max else { throw ICloudRetentionJobError.invalidJob }
            let deadline = now.addingTimeInterval(delay)
            guard deadline.timeIntervalSince1970.isFinite else { throw ICloudRetentionJobError.invalidJob }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET retention_wake_at=?,retention_wake_delay=?,retention_wake_attempt=?,
                    retention_wake_revision=retention_wake_revision+1 WHERE account_id=?;
                """, arguments: [deadline.timeIntervalSince1970, delay, attempt, self.accountID])
            return deadline
        }
    }
    func clearRetentionWake(approvalID: String, expectedRevision: Int64) async throws {
        try await database.writeAsync { db in
            let state = try self.retentionSchedule(approvalID: approvalID, in: db)
            guard state.revision == expectedRevision else { throw ICloudRetentionJobError.jobChanged }
            guard state.revision < Int64.max else { throw ICloudRetentionJobError.invalidJob }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET retention_wake_at=NULL,retention_wake_delay=NULL,
                    retention_wake_revision=retention_wake_revision+1 WHERE account_id=?;
                """, arguments: [self.accountID])
        }
    }
    private func retentionSchedule(approvalID: String, in db: Database) throws -> ICloudRetentionScheduleState {
        let scope = try retentionJobScope(in: db)
        _ = try approvedScheduledJob(approvalID: approvalID, scope: scope)
        let date: Double? = scope["retention_wake_at"], delay: Double? = scope["retention_wake_delay"]
        let revision: Int64 = scope["retention_wake_revision"], attempt: Int = scope["retention_wake_attempt"]
        guard (date == nil) == (delay == nil), revision >= 0, (0...31).contains(attempt),
              date.map({ $0.isFinite && $0 >= 0 }) ?? true,
              delay.map({ $0.isFinite && $0 > 0 && $0 <= ICloudBootstrapRetryPolicy.maximumDelay }) ?? true else {
            throw ICloudRetentionJobError.invalidJob
        }
        return .init(enabled: scope["retention_schedule_enabled"], deadline: date.map(Date.init(timeIntervalSince1970:)),
                     minimumWait: delay, attempt: attempt, revision: revision)
    }
    private func approvedScheduledJob(approvalID: String, scope: Row) throws -> ICloudRetentionJob {
        guard let data: Data = scope["retention_job"] else { throw ICloudRetentionJobError.approvalMismatch }
        let job = try ICloudRetentionJob.decode(data)
        try validateRetentionApproval(job.approval, scope: scope)
        guard job.approval.approvalID == approvalID else { throw ICloudRetentionJobError.jobChanged }
        return job
    }
}
