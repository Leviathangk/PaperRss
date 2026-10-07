import Foundation
import GRDB

struct ICloudRootBinding: Sendable {
    let generation: String?
    let hasPriorCloudState: Bool
    let protocolVersion: Int
}

extension ICloudRecordRepository {
    func rootBinding() async throws -> ICloudRootBinding {
        try await database.readAsync { db in
            try self.rootBinding(in: db)
        }
    }

    private func rootBinding(in db: Database) throws -> ICloudRootBinding {
        try requireScope(in: db)
        guard try AccountRecord.fetchOne(db, key: accountID)?.isEnabled == true else {
            throw ICloudRecordError.unavailableScope
        }
        let row = try Row.fetchOne(db, sql: """
            SELECT cloud_generation, cloud_protocol_version, engine_state IS NOT NULL OR initialized_zones != 0 OR EXISTS (
                SELECT 1 FROM icloud_records WHERE account_id = ? AND is_confirmed = 1
            ) AS has_prior_state FROM icloud_sync_scope WHERE account_id = ?;
            """, arguments: [accountID, accountID])!
        let generation: String? = row["cloud_generation"]
        if let generation { try ICloudCloudRoot(generation: generation, phase: .ready).validate() }
        return .init(generation: generation, hasPriorCloudState: row["has_prior_state"], protocolVersion: row["cloud_protocol_version"])
    }

    func proposeCloudGeneration() async throws -> String {
        try await database.writeAsync { db in
            let binding = try self.rootBinding(in: db)
            guard binding.generation == nil, !binding.hasPriorCloudState else {
                throw ICloudRootError.legacyCloudRequiresReview
            }
            if let proposal = try String.fetchOne(db, sql: "SELECT cloud_generation_proposal FROM icloud_sync_scope WHERE account_id = ?",
                                                 arguments: [self.accountID]) {
                try ICloudCloudRoot(generation: proposal, phase: .ready).validate()
                return proposal
            }
            let proposal = UUID().uuidString
            try db.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation_proposal = ? WHERE account_id = ?",
                           arguments: [proposal, self.accountID])
            return proposal
        }
    }

    func acceptCloudRoot(_ root: ICloudCloudRoot, expectedGeneration: String? = nil) async throws {
        try root.validate()
        let rejection = try await database.writeAsync { db -> ICloudRootError? in
            let binding = try self.rootBinding(in: db)
            if let expectedGeneration, binding.generation != expectedGeneration { throw CancellationError() }
            let error: ICloudRootError?
            if root.phase == .resetting { error = .resetInProgress }
            else if let generation = binding.generation, generation != root.generation { error = .generationChanged }
            else if binding.generation != nil, binding.protocolVersion != root.protocolVersion { error = .unsupportedVersion }
            else if binding.generation == nil, binding.hasPriorCloudState { error = .legacyCloudRequiresReview }
            else { error = nil }
            if let error {
                let reason: String
                switch error {
                case .resetInProgress: reason = "cloudResetInProgress"
                case .generationChanged: reason = "cloudGenerationChanged"
                case .unsupportedVersion: reason = "invalidCloudRoot"
                default: reason = "legacyCloudRoot"
                }
                try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = ? WHERE account_id = ?",
                               arguments: [reason, self.accountID])
                return error
            }
            if binding.generation == root.generation { return nil }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET cloud_generation = ?, cloud_generation_proposal = NULL, cloud_protocol_version = ?
                WHERE account_id = ?;
                """, arguments: [root.generation, root.protocolVersion, self.accountID])
            return nil
        }
        // Throw after commit, otherwise the protective pause rolls back too.
        if let rejection { throw rejection }
    }

    func boundCloudGeneration() throws -> String {
        try database.read { db in
            guard let generation = try self.rootBinding(in: db).generation else { throw ICloudRecordError.unavailableScope }
            return generation
        }
    }
}
