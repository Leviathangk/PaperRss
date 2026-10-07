import Foundation
import GRDB

extension ICloudRecordRepository {
    func retentionMaintenanceContext() async throws -> ICloudRetentionMaintenanceContext {
        try await database.readAsync { db in try self.maintenanceContext(in: db) }
    }

    private func maintenanceContext(in db: Database) throws -> ICloudRetentionMaintenanceContext {
        let row = try retentionJobScope(in: db)
        guard let generation: String = row["cloud_generation"], let fingerprint: String = row["user_fingerprint"] else {
            throw ICloudRetentionMaintenanceError.invalidState
        }
        let state = try maintenanceState(scope: row)
        let data: Data? = row["retention_job"], job = try data.map(ICloudRetentionJob.decode)
        if let job { try validateRetentionApproval(job.approval, scope: row) }
        return .init(scope: .init(generation: generation, systemFingerprint: fingerprint,
                                 syncUnreadContent: row["sync_unread_content"], job: job), state: state)
    }

    func maintenanceState(scope: Row) throws -> ICloudRetentionMaintenanceState? {
        guard let data: Data = scope["retention_maintenance"] else { return nil }
        let state = try ICloudRetentionMaintenanceState.decode(data)
        guard state.approval.generation == scope["cloud_generation"] as String?,
              state.approval.systemFingerprint == scope["user_fingerprint"] as String? else {
            throw ICloudRetentionMaintenanceError.invalidState
        }
        return state
    }

    func requireMaintenanceExecution(_ approval: ICloudRetentionApproval, scope: Row) throws {
        guard let parent = approval.maintenanceApprovalID else { return }
        guard let state = try maintenanceState(scope: scope), state.approval.approvalID == parent,
              state.schedule.enabled else { throw ICloudRetentionMaintenanceError.disabled }
    }

    func approveRetentionMaintenance(expected: ICloudRetentionMaintenanceContext) async throws -> ICloudRetentionMaintenanceState {
        try await database.writeAsync { db in
            let current = try self.maintenanceContext(in: db)
            guard current == expected, current.state?.schedule.enabled != true else {
                throw ICloudRetentionMaintenanceError.staleReview
            }
            if let job = current.scope.job, !job.isFinished || job.attempts.contains(where: { $0.stage == .needsReview }) {
                guard job.approval.maintenanceApprovalID == current.state?.approval.approvalID,
                      job.approval.maintenanceApprovalID != nil else { throw ICloudRetentionMaintenanceError.existingJob }
            }
            var state = current.state ?? .init(approval: .init(approvalID: UUID().uuidString,
                generation: current.scope.generation, systemFingerprint: current.scope.systemFingerprint,
                retentionDays: 183, weeklyRecordLimit: 400, allowsFutureArticles: true, allowsClockMaintenance: true))
            guard state.schedule.revision < Int64.max else { throw ICloudRetentionMaintenanceError.invalidState }
            let old = state.schedule
            // Explicit reapproval keeps the original parent's ID and retry wait.
            state.schedule = .init(enabled: true, deadline: old.deadline, minimumWait: old.minimumWait,
                                   attempt: old.attempt, revision: old.revision + 1)
            try self.storeMaintenance(state, in: db)
            if let job = current.scope.job, job.approval.maintenanceApprovalID == state.approval.approvalID, !job.isFinished {
                try db.execute(sql: "UPDATE icloud_sync_scope SET retention_schedule_enabled=1 WHERE account_id=?",
                               arguments: [self.accountID])
            }
            return state
        }
    }

    func disableRetentionMaintenance(approvalID: String) async throws {
        try await database.writeAsync { db in
            let context = try self.maintenanceContext(in: db)
            guard var state = context.state, state.approval.approvalID == approvalID else {
                throw ICloudRetentionMaintenanceError.staleReview
            }
            guard state.schedule.revision < Int64.max else { throw ICloudRetentionMaintenanceError.invalidState }
            let old = state.schedule
            state.schedule = .init(enabled: false, deadline: old.deadline, minimumWait: old.minimumWait,
                                   attempt: old.attempt, revision: old.revision + 1)
            try self.storeMaintenance(state, in: db)
            if context.scope.job?.approval.maintenanceApprovalID == approvalID {
                try db.execute(sql: "UPDATE icloud_sync_scope SET retention_schedule_enabled=0 WHERE account_id=?",
                               arguments: [self.accountID])
            }
        }
    }

    func scheduleMaintenanceWake(approvalID: String, for error: (any Error)?, now: Date) async throws -> ICloudRetentionMaintenanceState {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw ICloudRetentionMaintenanceError.invalidState }
        return try await database.writeAsync { db in
            var state = try self.requireActiveMaintenance(approvalID: approvalID, in: db)
            let attempt = error == nil ? 0 : min(30, state.schedule.attempt) + 1
            let delay: TimeInterval
            if let error {
                guard let retry = ICloudRetentionSchedulingPolicy.delay(for: error, attempt: attempt) else { throw error }
                delay = retry
            } else { delay = 3_600 }
            if state.schedule.deadline != nil { return state }
            guard state.schedule.revision < Int64.max else { throw ICloudRetentionMaintenanceError.invalidState }
            state.schedule = .init(enabled: true, deadline: now.addingTimeInterval(delay), minimumWait: delay,
                                   attempt: attempt, revision: state.schedule.revision + 1)
            try self.storeMaintenance(state, in: db); return state
        }
    }

    func clearMaintenanceWake(approvalID: String, expectedRevision: Int64) async throws {
        try await database.writeAsync { db in
            var state = try self.requireActiveMaintenance(approvalID: approvalID, in: db)
            guard state.schedule.revision == expectedRevision, state.schedule.revision < Int64.max else {
                throw ICloudRetentionMaintenanceError.staleReview
            }
            state.schedule = .init(enabled: true, deadline: nil, minimumWait: nil, attempt: state.schedule.attempt,
                                   revision: state.schedule.revision + 1)
            try self.storeMaintenance(state, in: db)
        }
    }

    private func requireActiveMaintenance(approvalID: String, in db: Database) throws -> ICloudRetentionMaintenanceState {
        let row = try retentionJobScope(in: db)
        guard let state = try maintenanceState(scope: row), state.approval.approvalID == approvalID,
              state.schedule.enabled else { throw ICloudRetentionMaintenanceError.disabled }
        return state
    }

    private func storeMaintenance(_ state: ICloudRetentionMaintenanceState, in db: Database) throws {
        try db.execute(sql: "UPDATE icloud_sync_scope SET retention_maintenance=? WHERE account_id=?",
                       arguments: [try state.serialized(), accountID])
    }
}
