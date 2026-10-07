import Foundation

enum ICloudRetentionMaintenanceError: Error, Sendable, Equatable {
    case invalidState, disabled, staleReview, confirmationRequired, existingJob
}

struct ICloudRetentionMaintenanceApproval: Codable, Sendable, Equatable {
    let approvalID: String
    let generation: String
    let systemFingerprint: String
    let retentionDays: Int
    let weeklyRecordLimit: Int
    let allowsFutureArticles: Bool
    let allowsClockMaintenance: Bool

    func validate() throws {
        guard UUID(uuidString: approvalID)?.uuidString == approvalID,
              !systemFingerprint.isEmpty, systemFingerprint.utf8.count <= 256,
              retentionDays == 183, weeklyRecordLimit == 400,
              allowsFutureArticles, allowsClockMaintenance else { throw ICloudRetentionMaintenanceError.invalidState }
        try ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3).validate()
    }

    func childApproval(names: [String]) throws -> ICloudRetentionApproval {
        try validate()
        let value = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: generation,
            systemFingerprint: systemFingerprint, articleRecordNames: names,
            retentionDays: retentionDays, weeklyRecordLimit: weeklyRecordLimit,
            allowsClockMaintenance: allowsClockMaintenance, maintenanceApprovalID: approvalID)
        try value.validate(); return value
    }
}

/// Local consent only, with a bounded retry wait. It never becomes a cloud
/// record, contains no article identities, and is absent after old migrations.
struct ICloudRetentionMaintenanceState: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let approval: ICloudRetentionMaintenanceApproval
    var schedule: ICloudRetentionScheduleState

    init(approval: ICloudRetentionMaintenanceApproval) {
        schemaVersion = 1; self.approval = approval
        schedule = .init(enabled: true, deadline: nil, minimumWait: nil, attempt: 0, revision: 0)
    }

    func validate() throws {
        try approval.validate()
        guard schemaVersion == 1, schedule.revision >= 0, (0...31).contains(schedule.attempt),
              (schedule.deadline == nil) == (schedule.minimumWait == nil),
              schedule.deadline.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 }) ?? true,
              schedule.minimumWait.map({ $0.isFinite && $0 > 0 && $0 <= ICloudBootstrapRetryPolicy.maximumDelay }) ?? true else {
            throw ICloudRetentionMaintenanceError.invalidState
        }
    }

    func serialized() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4_096 else { throw ICloudRetentionMaintenanceError.invalidState }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == ["schemaVersion", "approval", "schedule"],
              let approval = json["approval"] as? [String: Any],
              Set(approval.keys) == ["approvalID", "generation", "systemFingerprint", "retentionDays", "weeklyRecordLimit", "allowsFutureArticles", "allowsClockMaintenance"],
              let schedule = json["schedule"] as? [String: Any],
              Set(["enabled", "attempt", "revision"]).isSubset(of: Set(schedule.keys)),
              Set(schedule.keys).isSubset(of: ["enabled", "deadline", "minimumWait", "attempt", "revision"]),
              schedule["deadline"] == nil || schedule["deadline"] is NSNumber,
              schedule["minimumWait"] == nil || schedule["minimumWait"] is NSNumber else {
            throw ICloudRetentionMaintenanceError.invalidState
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
}

struct ICloudRetentionMaintenanceContext: Sendable, Equatable {
    let scope: ICloudRetentionReviewContext
    let state: ICloudRetentionMaintenanceState?
}

public struct ICloudRetentionMaintenanceReview: Sendable, Equatable {
    public let id: UUID
    public let retentionDays: Int
    public let weeklyRecordLimit: Int
    public let resumesExistingApproval: Bool
}

public struct ICloudRetentionMaintenanceStatus: Sendable, Equatable {
    public let approvalID: String
    public let isEnabled: Bool
    public let nextWakeAt: Date?
    public let needsOutcomeReview: Bool
    public let failureMessage: String?

    init(context: ICloudRetentionMaintenanceContext, failureMessage: String?) {
        approvalID = context.state!.approval.approvalID
        isEnabled = context.state!.schedule.enabled; nextWakeAt = context.state!.schedule.deadline
        needsOutcomeReview = context.scope.job?.attempts.contains(where: { $0.stage == .needsReview }) == true
        self.failureMessage = failureMessage
    }
}

actor ICloudRetentionMaintenanceReviewer {
    private let repository: ICloudRecordRepository
    private let uptime: @Sendable () -> Duration
    private var review: (value: ICloudRetentionMaintenanceReview, context: ICloudRetentionMaintenanceContext, expires: Duration)?
    private var preparation = UUID()

    init(repository: ICloudRecordRepository,
         uptime: @escaping @Sendable () -> Duration = { .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds)) }) {
        self.repository = repository; self.uptime = uptime
    }

    func prepare() async throws -> ICloudRetentionMaintenanceReview {
        review = nil; let token = UUID(); preparation = token
        let context = try await repository.retentionMaintenanceContext()
        try Task.checkCancellation()
        guard preparation == token else { throw ICloudRetentionMaintenanceError.staleReview }
        guard context.state?.schedule.enabled != true else { throw ICloudRetentionMaintenanceError.existingJob }
        if let job = context.scope.job, !job.isFinished || job.attempts.contains(where: { $0.stage == .needsReview }) {
            guard let previous = context.state?.approval.approvalID,
                  job.approval.maintenanceApprovalID == previous else { throw ICloudRetentionMaintenanceError.existingJob }
        }
        let value = ICloudRetentionMaintenanceReview(id: UUID(), retentionDays: 183, weeklyRecordLimit: 400,
                                                     resumesExistingApproval: context.state != nil)
        review = (value, context, uptime() + .seconds(600)); return value
    }

    func approve(id: UUID, cleanupConfirmed: Bool, futureArticlesConfirmed: Bool,
                 clockMaintenanceConfirmed: Bool) async throws -> ICloudRetentionMaintenanceState {
        guard cleanupConfirmed, futureArticlesConfirmed, clockMaintenanceConfirmed else {
            throw ICloudRetentionMaintenanceError.confirmationRequired
        }
        guard let review, review.value.id == id, uptime() < review.expires else { throw ICloudRetentionMaintenanceError.staleReview }
        let context = try await repository.retentionMaintenanceContext()
        try Task.checkCancellation()
        guard self.review?.value.id == id, uptime() < review.expires, context == review.context else {
            throw ICloudRetentionMaintenanceError.staleReview
        }
        let state = try await repository.approveRetentionMaintenance(expected: context)
        self.review = nil; return state
    }

    func discard(id: UUID? = nil) {
        if id == nil || review?.value.id == id { review = nil; preparation = UUID() }
    }
}
