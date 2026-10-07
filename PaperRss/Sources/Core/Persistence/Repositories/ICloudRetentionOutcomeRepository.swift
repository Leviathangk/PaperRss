import Foundation
import GRDB

extension ICloudRecordRepository {
    func acceptReviewedRetentionOutcome(expected: ICloudRetentionJob, attempt: ICloudRetentionJob.Attempt,
                                        snapshot: ICloudRetentionPointSnapshot) async throws -> ICloudRetentionJob {
        guard case .confirmed = try ICloudRetentionOutcomeVerifier.inspect(job: expected, attempt: attempt, snapshot: snapshot) else {
            throw ICloudRetentionJobError.needsReview
        }
        return try await database.writeAsync { db in
            let scope = try self.retentionJobScope(in: db)
            try self.validateRetentionApproval(expected.approval, scope: scope)
            guard !(scope["retention_schedule_enabled"] as Bool),
                  let data: Data = scope["retention_job"], try ICloudRetentionJob.decode(data) == expected else {
                throw ICloudRetentionJobError.jobChanged
            }
            var next = expected
            guard let index = next.attempts.firstIndex(of: attempt) else { throw ICloudRetentionJobError.jobChanged }
            next.attempts[index].stage = .accepted
            try db.execute(sql: "UPDATE icloud_sync_scope SET retention_job=? WHERE account_id=?",
                           arguments: [try next.serialized(), self.accountID])
            return next
        }
    }
}
