import Foundation
import GRDB

extension ICloudRecordRepository {
    func beginRetentionJob(_ approval: ICloudRetentionApproval, replacingCompletedApprovalID: String? = nil) async throws -> ICloudRetentionJob {
        try approval.validate()
        return try await database.writeAsync { db in
            let scope = try self.retentionJobScope(in: db)
            try self.validateRetentionApproval(approval, scope: scope)
            try self.requireMaintenanceExecution(approval, scope: scope)
            if approval.maintenanceApprovalID == nil, try self.maintenanceState(scope: scope)?.schedule.enabled == true {
                throw ICloudRetentionMaintenanceError.existingJob
            }
            if let data: Data = scope["retention_job"] {
                let existing = try ICloudRetentionJob.decode(data)
                if existing.approval == approval { return existing } // Never repeat the same approval.
                guard replacingCompletedApprovalID == existing.approval.approvalID, existing.isFinished,
                      !existing.attempts.contains(where: { $0.stage == .needsReview }),
                      !(scope["retention_schedule_enabled"] as Bool) else { throw ICloudRetentionJobError.approvalMismatch }
            } else if replacingCompletedApprovalID != nil {
                throw ICloudRetentionJobError.jobChanged
            }
            let job = try ICloudRetentionJob(approval: approval)
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET retention_job = ?, retention_schedule_enabled=0,
                    retention_wake_at=NULL, retention_wake_delay=NULL, retention_wake_attempt=0
                WHERE account_id = ?
                """,
                           arguments: [try job.serialized(), self.accountID])
            return job
        }
    }

    func retentionReviewContext() async throws -> ICloudRetentionReviewContext {
        try await database.readAsync { db in
            let scope = try self.retentionJobScope(in: db)
            guard let generation: String = scope["cloud_generation"], let fingerprint: String = scope["user_fingerprint"] else {
                throw ICloudRetentionReviewError.cloudPreparationRequired
            }
            let data: Data? = scope["retention_job"]
            let job = try data.map(ICloudRetentionJob.decode)
            if let job { try self.validateRetentionApproval(job.approval, scope: scope) }
            return .init(generation: generation, systemFingerprint: fingerprint,
                         syncUnreadContent: scope["sync_unread_content"], job: job)
        }
    }

    func retentionJob(approvalID: String, requiresExecutionAuthorization: Bool = true) async throws -> ICloudRetentionJob {
        try await database.readAsync { db in
            let scope = try self.retentionJobScope(in: db)
            guard let data: Data = scope["retention_job"] else { throw ICloudRetentionJobError.approvalMismatch }
            let job = try ICloudRetentionJob.decode(data)
            try self.validateRetentionApproval(job.approval, scope: scope)
            if requiresExecutionAuthorization { try self.requireMaintenanceExecution(job.approval, scope: scope) }
            guard job.approval.approvalID == approvalID else { throw ICloudRetentionJobError.jobChanged }
            return job
        }
    }

    func retentionWriterVersion() async throws -> ICloudFieldVersion {
        try await database.readAsync { db in
            let scope = try self.retentionJobScope(in: db)
            return .init(counter: scope["logical_clock"], deviceID: scope["device_id"])
        }
    }

    func storeRetentionJob(_ next: ICloudRetentionJob, replacing expected: ICloudRetentionJob) async throws -> ICloudRetentionJob {
        try next.validate(); try expected.validate()
        guard next.approval == expected.approval, next.attempts.count == expected.attempts.count else {
            throw ICloudRetentionJobError.jobChanged
        }
        var changed = 0
        for (previous, following) in zip(expected.attempts, next.attempts) where previous != following {
            changed += 1
            guard previous == expected.nextAttempt,
                  previous.articleRecordName == following.articleRecordName, previous.operationID == following.operationID else {
                throw ICloudRetentionJobError.jobChanged
            }
            switch previous.stage {
            case .pending:
                guard following.stage == .submitted || following.stage == .skipped else { throw ICloudRetentionJobError.invalidJob }
            case .submitted:
                guard following.stage == .accepted || following.stage == .needsReview,
                      following.proposalDigest == previous.proposalDigest, following.processedRecords == previous.processedRecords else {
                    throw ICloudRetentionJobError.invalidJob
                }
            case .accepted, .skipped, .needsReview: throw ICloudRetentionJobError.invalidJob
            }
        }
        guard changed == 1 else { throw ICloudRetentionJobError.invalidJob }
        return try await database.writeAsync { db in
            let scope = try self.retentionJobScope(in: db)
            try self.validateRetentionApproval(expected.approval, scope: scope)
            try self.requireMaintenanceExecution(expected.approval, scope: scope)
            guard let data: Data = scope["retention_job"], try ICloudRetentionJob.decode(data) == expected else {
                throw ICloudRetentionJobError.jobChanged
            }
            try db.execute(sql: "UPDATE icloud_sync_scope SET retention_job = ? WHERE account_id = ?",
                           arguments: [try next.serialized(), self.accountID])
            return next
        }
    }

    func retentionJobScope(in db: Database) throws -> Row {
        try requireScope(in: db)
        guard try usesRetentionProtocol(in: db),
              try AccountRecord.fetchOne(db, key: accountID)?.isEnabled == true,
              let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]),
              scope["initialized_zones"] as Int == 3,
              scope["cloud_reset_operation"] as DatabaseValue == .null else { throw ICloudRetentionJobError.approvalMismatch }
        return scope
    }
    func validateRetentionApproval(_ approval: ICloudRetentionApproval, scope: Row) throws {
        guard scope["cloud_generation"] as String? == approval.generation,
              scope["user_fingerprint"] as String? == approval.systemFingerprint else {
            throw ICloudRetentionJobError.approvalMismatch
        }
        if let parent = approval.maintenanceApprovalID {
            guard let state = try maintenanceState(scope: scope), state.approval.approvalID == parent,
                  state.approval.retentionDays == approval.retentionDays,
                  state.approval.weeklyRecordLimit == approval.weeklyRecordLimit,
                  state.approval.allowsClockMaintenance == approval.allowsClockMaintenance else {
                throw ICloudRetentionMaintenanceError.invalidState
            }
        }
    }
}
