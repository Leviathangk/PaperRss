import Foundation

/// The UI receives counts and an opaque review token, never GUIDs, URLs or SDK
/// conditional metadata. A preview grants no permission to mutate CloudKit.
public struct ICloudRetentionReview: Sendable, Equatable {
    public let id: UUID
    public let candidateArticles: Int
    public let scannedAt: Date
    public let retentionDays: Int
    public let weeklyRecordLimit: Int
}

public struct ICloudRetentionProgress: Sendable, Equatable {
    public let approvalID: String
    public let approvedArticles: Int
    public let completedArticles: Int
    public let skippedArticles: Int
    public let articlesNeedingReview: Int
    public let remainingArticles: Int
    public let processedRecords: Int
    public let isEnabled: Bool
    public let isFinished: Bool
    public let nextWakeAt: Date?
    public let failureMessage: String?
    public let isMaintenanceTask: Bool
    public let uncertainOperations: Int

    init(job: ICloudRetentionJob, schedule: ICloudRetentionScheduleState, failureMessage: String? = nil) {
        approvalID = job.approval.approvalID; approvedArticles = job.attempts.count
        completedArticles = job.attempts.filter { $0.stage == .accepted }.count
        skippedArticles = job.attempts.filter { $0.stage == .skipped }.count
        articlesNeedingReview = job.attempts.filter { $0.stage == .needsReview }.count
        remainingArticles = job.attempts.filter { $0.stage == .pending || $0.stage == .submitted }.count
        processedRecords = job.attempts.filter { $0.stage == .accepted }.reduce(0) { $0 + ($1.processedRecords ?? 0) }
        isEnabled = schedule.enabled; isFinished = job.isFinished; nextWakeAt = schedule.deadline
        self.failureMessage = failureMessage
        isMaintenanceTask = job.approval.maintenanceApprovalID != nil
        uncertainOperations = job.attempts.filter { $0.stage == .submitted || $0.stage == .needsReview }.count
    }
}

enum ICloudRetentionReviewError: Error, Sendable, Equatable {
    case confirmationRequired, clockMaintenanceRequired, scanIncomplete, noCandidates
    case existingJob, staleReview, cloudPreparationRequired
}

struct ICloudRetentionReviewContext: Sendable, Equatable {
    let generation: String
    let systemFingerprint: String
    let syncUnreadContent: Bool
    let job: ICloudRetentionJob?
}

enum ICloudRetentionCandidateDiscovery {
    /// Query evidence is advisory. Every selected address is point-read again
    /// by the executor; a query's absent records never authorize deletion.
    static func names(records: [ICloudCloudRecordMetadata], protection: ICloudMaintenanceProtection,
                      syncUnreadContent: Bool, now: Date, limit: Int = 400) throws -> [String] {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              (1...400).contains(limit), records.count <= 20_000,
              Set(records.map(\.envelope.recordName)).count == records.count else {
            throw ICloudInventoryError.malformedPage
        }
        var groups: [String: [ICloudCloudRecordMetadata]] = [:]
        for record in records {
            try record.envelope.validate()
            guard [.read, .starred, .content].contains(record.envelope.kind) else { continue }
            groups[ICloudMaintenancePlanner.articleKey(record.envelope.recordName), default: []].append(record)
        }
        var selected: [String] = []
        for key in groups.keys.sorted() {
            let inventory = ICloudMaintenancePlanner.inventory(records: groups[key]!, isComplete: true,
                reachedSafetyLimit: false, syncUnreadContent: syncUnreadContent, protection: protection, now: now)
            guard let preview = inventory.cleanupPreview,
                  preview.removableBodies + preview.staleStateRecords > 0 else { continue }
            let name = "article-v1:" + key
            _ = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: name)
            selected.append(name)
            if selected.count == limit { break }
        }
        return selected
    }
}

/// The in-memory review expires on a monotonic clock. Persisting a concrete
/// job requires two independent confirmations and an unchanged local scope.
actor ICloudRetentionReviewCoordinator {
    private let repository: ICloudRecordRepository
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> Duration
    private var review: (value: ICloudRetentionReview, context: ICloudRetentionReviewContext,
                         names: [String], expires: Duration)?

    init(repository: ICloudRecordRepository, now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> Duration = { .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds)) }) {
        self.repository = repository; self.now = now; self.uptime = uptime
    }

    func prepare(records: [ICloudCloudRecordMetadata], context: ICloudRetentionReviewContext,
                 isComplete: Bool, reachedSafetyLimit: Bool) async throws -> ICloudRetentionReview {
        review = nil
        guard isComplete, !reachedSafetyLimit else { throw ICloudRetentionReviewError.scanIncomplete }
        guard context == (try await repository.retentionReviewContext()) else { throw ICloudRetentionReviewError.staleReview }
        if let job = context.job, !job.isFinished || job.attempts.contains(where: { $0.stage == .needsReview }) {
            throw ICloudRetentionReviewError.existingJob
        }
        let protection = try await repository.maintenanceProtection(), scannedAt = now()
        let names = try ICloudRetentionCandidateDiscovery.names(records: records, protection: protection,
            syncUnreadContent: context.syncUnreadContent, now: scannedAt)
        return try await prepare(names: names, context: context, scannedAt: scannedAt)
    }

    /// Positive query hints select a finite review scope. They need not prove
    /// global query completion; the executor revalidates all six IDs per group.
    func prepare(names: [String], context: ICloudRetentionReviewContext, scannedAt: Date) async throws -> ICloudRetentionReview {
        review = nil
        if let job = context.job, !job.isFinished || job.attempts.contains(where: { $0.stage == .needsReview }) {
            throw ICloudRetentionReviewError.existingJob
        }
        guard names.count <= 400, Set(names).count == names.count, names == names.sorted(),
              scannedAt.timeIntervalSince1970.isFinite, scannedAt.timeIntervalSince1970 >= 0 else {
            throw ICloudInventoryError.malformedPage
        }
        for name in names { _ = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: name) }
        try Task.checkCancellation()
        guard context == (try await repository.retentionReviewContext()) else { throw ICloudRetentionReviewError.staleReview }
        guard !names.isEmpty else { throw ICloudRetentionReviewError.noCandidates }
        let value = ICloudRetentionReview(id: UUID(), candidateArticles: names.count, scannedAt: scannedAt,
                                         retentionDays: 183, weeklyRecordLimit: 400)
        review = (value, context, names, uptime() + .seconds(600))
        return value
    }

    func approve(id: UUID, cleanupConfirmed: Bool, clockMaintenanceConfirmed: Bool) async throws -> ICloudRetentionJob {
        guard cleanupConfirmed else { throw ICloudRetentionReviewError.confirmationRequired }
        guard clockMaintenanceConfirmed else { throw ICloudRetentionReviewError.clockMaintenanceRequired }
        guard let review, review.value.id == id, uptime() < review.expires else { throw ICloudRetentionReviewError.staleReview }
        guard review.context == (try await repository.retentionReviewContext()) else { throw ICloudRetentionReviewError.staleReview }
        guard self.review?.value.id == id, uptime() < review.expires else { throw ICloudRetentionReviewError.staleReview }
        try Task.checkCancellation()
        let approval = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: review.context.generation,
            systemFingerprint: review.context.systemFingerprint, articleRecordNames: review.names,
            retentionDays: 183, weeklyRecordLimit: 400, allowsClockMaintenance: true)
        let job = try await repository.beginRetentionJob(approval, replacingCompletedApprovalID: review.context.job?.approval.approvalID)
        self.review = nil
        return job
    }

    func discard(id: UUID? = nil) {
        if id == nil || review?.value.id == id { review = nil }
    }
}
