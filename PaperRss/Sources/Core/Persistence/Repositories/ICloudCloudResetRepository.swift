import Foundation
import GRDB

extension ICloudRecordRepository {
    /// Persists one approved operation and pauses normal sync atomically. Local
    /// reading data, capture, pending intents and checkpoints are all retained.
    func beginCloudReset(_ approval: ICloudCloudResetApproval) async throws -> ICloudCloudResetOperation {
        try approval.validate()
        return try await database.writeAsync { db in
            let row = try self.cloudResetScope(in: db)
            if let existing: Data = row["cloud_reset_operation"] {
                let operation = try self.validCloudReset(existing, scope: row)
                guard operation.approval == approval else { throw ICloudCloudResetError.operationInProgress }
                return operation
            }
            let pause: String? = row["pause_reason"]
            guard pause == nil || ["zoneDeleted", "zoneMissing", "structureDeleted", "cloudRootMissing"].contains(pause!),
                  row["cloud_generation"] as String? == approval.previousGeneration,
                  row["cloud_protocol_version"] as Int == approval.previousProtocolVersion,
                  row["user_fingerprint"] as String? == approval.systemFingerprint else {
                throw ICloudCloudResetError.approvalMismatch
            }
            let operation = ICloudCloudResetOperation(approval: approval)
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET cloud_reset_operation = ?, pause_reason = 'cloudResetRequested'
                WHERE account_id = ?;
                """, arguments: [try operation.serialized(), self.accountID])
            return operation
        }
    }

    func cloudResetOperation(id: String) async throws -> ICloudCloudResetOperation {
        try await database.readAsync { db in
            let row = try self.cloudResetScope(in: db)
            guard let data: Data = row["cloud_reset_operation"] else { throw ICloudCloudResetError.approvalMismatch }
            let operation = try self.validCloudReset(data, scope: row)
            guard operation.approval.operationID == id else { throw ICloudCloudResetError.operationChanged }
            return operation
        }
    }

    func advanceCloudReset(_ expected: ICloudCloudResetOperation,
                           to stage: ICloudCloudResetOperation.Stage) async throws -> ICloudCloudResetOperation {
        let retaining = expected.approval.previousDataDisposition == .preserve &&
            expected.stage == .articlesCreated && stage == .previousRetained
        guard stage != .cloudReady, retaining || (stage != .previousRetained && stage.rawValue == expected.stage.rawValue + 1) else {
            throw ICloudCloudResetError.invalidOperation
        }
        var next = expected
        next.stage = stage
        return try await storeCloudReset(next, replacing: expected)
    }

    /// A server-ready replacement is terminal even if a local stage commit was
    /// lost. Never replay old deletions after discovering this root.
    func markCloudResetReady(_ expected: ICloudCloudResetOperation,
                            observed root: ICloudCloudRoot) async throws -> ICloudCloudResetOperation {
        try root.validate()
        guard root == expected.approval.replacementRoot else {
            throw ICloudCloudResetError.unexpectedRoot
        }
        var next = expected
        next.stage = .cloudReady
        return try await storeCloudReset(next, replacing: expected)
    }

    private func storeCloudReset(_ next: ICloudCloudResetOperation,
                                replacing expected: ICloudCloudResetOperation) async throws -> ICloudCloudResetOperation {
        try expected.validate(); try next.validate()
        return try await database.writeAsync { db in
            let row = try self.cloudResetScope(in: db)
            guard let data: Data = row["cloud_reset_operation"],
                  try self.validCloudReset(data, scope: row) == expected else {
                throw ICloudCloudResetError.operationChanged
            }
            let reason = next.stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested"
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET cloud_reset_operation = ?, pause_reason = ?
                WHERE account_id = ?;
                """, arguments: [try next.serialized(), reason, self.accountID])
            return next
        }
    }

    private func cloudResetScope(in db: Database) throws -> Row {
        try requireScope(in: db, permitsPause: true)
        guard try AccountRecord.fetchOne(db, key: accountID)?.isEnabled == true,
              let row = try Row.fetchOne(db, sql: """
                SELECT cloud_generation, cloud_protocol_version, user_fingerprint, pause_reason, cloud_reset_operation
                FROM icloud_sync_scope WHERE account_id = ?;
                """, arguments: [accountID]) else { throw ICloudRecordError.unavailableScope }
        return row
    }

    private func validCloudReset(_ data: Data, scope: Row) throws -> ICloudCloudResetOperation {
        let operation = try ICloudCloudResetOperation.decode(data)
        let reason: String? = scope["pause_reason"]
        guard scope["cloud_generation"] as String? == operation.approval.previousGeneration,
              scope["cloud_protocol_version"] as Int == operation.approval.previousProtocolVersion,
              scope["user_fingerprint"] as String? == operation.approval.systemFingerprint,
              reason == (operation.stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested") else {
            throw ICloudCloudResetError.approvalMismatch
        }
        return operation
    }
}
