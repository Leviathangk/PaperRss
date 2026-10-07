import Foundation

enum ICloudRetentionJobError: Error, Sendable, Equatable {
    case invalidJob, approvalMismatch, jobChanged, needsReview
}

/// A concrete scope approved separately after review. Product-rule acceptance
/// never creates this object, and normal sync does not persist one by default.
struct ICloudRetentionApproval: Codable, Sendable, Equatable {
    let approvalID: String
    let generation: String
    let systemFingerprint: String
    let articleRecordNames: [String]
    let retentionDays: Int
    let weeklyRecordLimit: Int
    let allowsClockMaintenance: Bool
    let maintenanceApprovalID: String?

    init(approvalID: String, generation: String, systemFingerprint: String, articleRecordNames: [String],
         retentionDays: Int, weeklyRecordLimit: Int, allowsClockMaintenance: Bool = false,
         maintenanceApprovalID: String? = nil) {
        self.approvalID = approvalID; self.generation = generation; self.systemFingerprint = systemFingerprint
        self.articleRecordNames = articleRecordNames; self.retentionDays = retentionDays
        self.weeklyRecordLimit = weeklyRecordLimit; self.allowsClockMaintenance = allowsClockMaintenance
        self.maintenanceApprovalID = maintenanceApprovalID
    }

    func validate() throws {
        guard UUID(uuidString: approvalID)?.uuidString == approvalID,
              !systemFingerprint.isEmpty, systemFingerprint.utf8.count <= 256,
              retentionDays == 183, weeklyRecordLimit == 400,
              !articleRecordNames.isEmpty, articleRecordNames.count <= 400,
              Set(articleRecordNames).count == articleRecordNames.count,
              articleRecordNames == articleRecordNames.sorted() else { throw ICloudRetentionJobError.invalidJob }
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
        if let maintenanceApprovalID {
            guard UUID(uuidString: maintenanceApprovalID)?.uuidString == maintenanceApprovalID,
                  allowsClockMaintenance else { throw ICloudRetentionJobError.invalidJob }
        }
        for name in articleRecordNames { _ = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: name) }
    }
}

struct ICloudRetentionJob: Codable, Sendable, Equatable {
    struct Attempt: Codable, Sendable, Equatable {
        enum Stage: String, Codable, Sendable { case pending, submitted, accepted, skipped, needsReview }
        let articleRecordName: String
        let operationID: String
        var stage: Stage
        var proposalDigest: String?
        var processedRecords: Int?
    }
    let schemaVersion: Int
    let approval: ICloudRetentionApproval
    var attempts: [Attempt]

    init(approval: ICloudRetentionApproval) throws {
        try approval.validate()
        schemaVersion = 1; self.approval = approval
        attempts = approval.articleRecordNames.map {
            .init(articleRecordName: $0, operationID: UUID().uuidString, stage: .pending)
        }
    }
    var nextAttempt: Attempt? { attempts.first { $0.stage == .pending || $0.stage == .submitted } }
    var isFinished: Bool { nextAttempt == nil }

    func validate() throws {
        try approval.validate()
        guard schemaVersion == 1, attempts.map(\.articleRecordName) == approval.articleRecordNames,
              Set(attempts.map(\.operationID)).count == attempts.count else { throw ICloudRetentionJobError.invalidJob }
        for attempt in attempts {
            guard UUID(uuidString: attempt.operationID)?.uuidString == attempt.operationID else { throw ICloudRetentionJobError.invalidJob }
            switch attempt.stage {
            case .pending, .skipped:
                guard attempt.proposalDigest == nil, attempt.processedRecords == nil else { throw ICloudRetentionJobError.invalidJob }
            case .submitted, .accepted, .needsReview:
                guard let digest = attempt.proposalDigest, digest.count == 64,
                      digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                      let cost = attempt.processedRecords, (3...6).contains(cost) else { throw ICloudRetentionJobError.invalidJob }
            }
        }
    }
    func serialized() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 256 * 1_024 else { throw ICloudRetentionJobError.invalidJob }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 256 * 1_024 else { throw ICloudRetentionJobError.invalidJob }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json, Set(json.keys) == ["schemaVersion", "approval", "attempts"],
              let approval = json["approval"] as? [String: Any],
              let attempts = json["attempts"] as? [[String: Any]], attempts.count <= 400 else { throw ICloudRetentionJobError.invalidJob }
        let requiredApproval: Set<String> = ["approvalID", "generation", "systemFingerprint", "articleRecordNames", "retentionDays", "weeklyRecordLimit", "allowsClockMaintenance"]
        guard requiredApproval.isSubset(of: Set(approval.keys)),
              Set(approval.keys).isSubset(of: requiredApproval.union(["maintenanceApprovalID"])),
              approval["maintenanceApprovalID"] == nil || approval["maintenanceApprovalID"] is String else {
            throw ICloudRetentionJobError.invalidJob
        }
        for attempt in attempts {
            let required: Set<String> = ["articleRecordName", "operationID", "stage"]
            guard required.isSubset(of: Set(attempt.keys)),
                  Set(attempt.keys).isSubset(of: required.union(["proposalDigest", "processedRecords"])) else { throw ICloudRetentionJobError.invalidJob }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
}

protocol ICloudRetentionExecutionTransport: Sendable {
    func prepareServerClock() async throws
    func fetch(articleRecordName: String) async throws -> ICloudRetentionPointSnapshot
    func submit(_ batch: ICloudRetentionAtomicBatch) async throws -> [ICloudReceivedRecord]
}
