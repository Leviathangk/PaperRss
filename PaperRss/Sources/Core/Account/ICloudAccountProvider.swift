@preconcurrency import CloudKit
import Foundation
import GRDB

enum ICloudAutomaticSyncEvent: Sendable {
    case started, changed, completed
    case failed(any Error)
}

protocol ICloudAccountSyncing: ICloudInventoryPageFetching {
    var supportsAutomaticSync: Bool { get }
    var requiresBootstrapRetry: Bool { get async }
    func fetchChanges() async throws
    func sendChanges() async throws
    func startAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws
    func prepareAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws
    func localChangesAvailable() async throws
    func restoreForLocalCopy() async throws -> ICloudLocalCopyRepository.Context
    func resumeOriginalAccount() async throws
    func prepareArchiveRecovery() async throws -> ICloudArchiveRecoveryPlan
    func executeArchiveRecovery(_ plan: ICloudArchiveRecoveryPlan, initializeEmptyCloudConfirmed: Bool) async throws -> AccountRecord
    func discardArchiveRecovery(planID: UUID) async
    func stop() async
}

extension ICloudAccountSyncing {
    var supportsAutomaticSync: Bool { false }
    var requiresBootstrapRetry: Bool { get async { false } }
    func startAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {}
    func prepareAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        try await startAutomaticSync(onEvent: onEvent)
    }
    func localChangesAvailable() async throws { try await sendChanges() }
    func restoreForLocalCopy() async throws -> ICloudLocalCopyRepository.Context {
        throw ICloudLocalCopyError.unavailableTarget
    }
    func resumeOriginalAccount() async throws { throw ICloudSameAccountResumeError.unavailableScope }
    func prepareArchiveRecovery() async throws -> ICloudArchiveRecoveryPlan { throw ICloudArchiveRecoveryError.unavailableSource }
    func executeArchiveRecovery(_ plan: ICloudArchiveRecoveryPlan, initializeEmptyCloudConfirmed: Bool) async throws -> AccountRecord { throw ICloudArchiveRecoveryError.staleReview }
    func discardArchiveRecovery(planID: UUID) async {}
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        throw ICloudEngineError.notEntitled
    }
}

/// Cloud restore -> RSS -> apply inbox -> send. Cloud failures are reported
/// while direct RSS reading and durable local edits remain available offline.
actor ICloudAccountProvider: AccountProvider {
    nonisolated let accountID: String
    nonisolated var accountType: AccountType { .iCloud }
    nonisolated let local: LocalAccountProvider
    private let database: LibraryDatabase
    private let records: ICloudRecordRepository
    private let sync: any ICloudAccountSyncing
    private let onProgress: @Sendable (AccountRefreshProgress?) async -> Void
    private let onChange: @Sendable () async -> Void
    private var refreshTask: Task<RefreshResult, any Error>?
    private var refreshTaskID: UUID?
    private var refreshFeedIDs: Set<UUID>?
    private var automaticObservation: Task<Void, Never>?
    private var automaticSession: UUID?
    private var localChangeTask: Task<Void, Never>?
    private var automaticFailureReported = false
    private static let foregroundFetchInterval: TimeInterval = 120
    private let foregroundNow: @Sendable () -> Date
    private var lastForegroundFetchAt: Date?
    private var foregroundFetchID: UUID?
    private var bootstrapRetryTask: Task<Void, Never>?
    private var bootstrapRetryID: UUID?
    private var bootstrapDeadline: Date?
    private let bootstrapNow: @Sendable () -> Date
    private let bootstrapSleep: @Sendable (Duration) async throws -> Void
    private var inventoryScanner: ICloudInventoryScanner?
    private var localCopyLifecycle = UUID()
    private var localCopyOperation: (id: UUID, cancel: @Sendable () -> Void)?
    private var localCopyReview: (id: UUID, plan: ICloudLocalCopyRepository.Plan)?
    private var sameAccountResume: (id: UUID, cancel: @Sendable () -> Void)?
    private var archiveRecoverySession: UUID?
    private var archiveRecoveryOperation: (id: UUID, cancel: @Sendable () -> Void)?
    private var archiveRecoveryReview: (id: UUID, plan: ICloudArchiveRecoveryPlan)?
    private let retentionReviewer: ICloudRetentionReviewCoordinator
    private let retentionScheduler: ICloudRetentionScheduler
    private let retentionTransportFactory: (@Sendable (String) -> any ICloudRetentionExecutionTransport)?
    private var retentionLifecycle = UUID()
    private var retentionPreparation: UUID?
    private var retentionDiscovery: ICloudRetentionDiscoveryScanner?
    private var retentionDiscoveryBinding: ICloudRetentionDiscoveryBinding?
    private var retentionFailure: String?
    private let maintenanceReviewer: ICloudRetentionMaintenanceReviewer
    private let maintenanceScheduler: ICloudRetentionMaintenanceScheduler
    private var maintenanceFailure: String?
    private let outcomeReviewer: ICloudRetentionOutcomeReviewer
    private let outcomeReaderFactory: (@Sendable (String) -> any ICloudRetentionOutcomeReading)?
    private var outcomeSession: UUID?
    private var outcomeTask: (id: UUID, task: Task<ICloudRetentionOutcomeReviewResult, any Error>)?
    private let newLibraryReviewer: ICloudNewLibraryReviewer
    private let newLibraryCoordinator: ICloudCloudResetCoordinator
    private let newLibraryObserver: any ICloudNewLibraryObserving
    private let newLibraryTransportFactory: (@Sendable (String) -> any ICloudCloudResetTransport)?

    init(
        accountID: String, database: LibraryDatabase,
        customFeedFetcher: (@Sendable (Feed, Bool) async throws -> FeedFetchResult)? = nil,
        sync: (any ICloudAccountSyncing)? = nil,
        foregroundNow: @escaping @Sendable () -> Date = { Date() },
        bootstrapNow: @escaping @Sendable () -> Date = { Date() },
        bootstrapSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        retentionTransportFactory: (@Sendable (String) -> any ICloudRetentionExecutionTransport)? = nil,
        retentionSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        maintenanceSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        outcomeReaderFactory: (@Sendable (String) -> any ICloudRetentionOutcomeReading)? = nil,
        newLibraryObserver: (any ICloudNewLibraryObserving)? = nil,
        newLibraryTransportFactory: (@Sendable (String) -> any ICloudCloudResetTransport)? = nil,
        onProgress: @escaping @Sendable (AccountRefreshProgress?) async -> Void = { _ in },
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.accountID = accountID; self.database = database
        records = ICloudRecordRepository(database: database, accountID: accountID)
        retentionReviewer = ICloudRetentionReviewCoordinator(repository: records)
        retentionScheduler = ICloudRetentionScheduler(repository: records, sleep: retentionSleep)
        self.retentionTransportFactory = retentionTransportFactory
        maintenanceReviewer = ICloudRetentionMaintenanceReviewer(repository: records)
        outcomeReviewer = ICloudRetentionOutcomeReviewer(repository: records)
        self.outcomeReaderFactory = outcomeReaderFactory
        newLibraryReviewer = ICloudNewLibraryReviewer(repository: records)
        newLibraryCoordinator = ICloudCloudResetCoordinator(repository: records)
        self.newLibraryObserver = newLibraryObserver ?? ICloudNewLibraryCloudKitObserver()
        self.newLibraryTransportFactory = newLibraryTransportFactory
        local = LocalAccountProvider(accountID: accountID, database: database, customFeedFetcher: customFeedFetcher)
        let driver = sync ?? ICloudSyncEngineDriver(repository: records)
        self.sync = driver
        self.foregroundNow = foregroundNow
        maintenanceScheduler = .init(repository: records, source: driver, sleep: maintenanceSleep)
        self.bootstrapNow = bootstrapNow
        self.bootstrapSleep = bootstrapSleep
        self.onProgress = onProgress
        self.onChange = onChange
    }

    deinit {
        let retentionScheduler = self.retentionScheduler
        let newLibraryCoordinator = self.newLibraryCoordinator
        let maintenanceScheduler = self.maintenanceScheduler, outcomeReviewer = self.outcomeReviewer
        outcomeTask?.task.cancel()
        Task {
            await retentionScheduler.suspend(); await maintenanceScheduler.suspend()
            await outcomeReviewer.stop(); await newLibraryCoordinator.stop()
        }
        archiveRecoveryOperation?.cancel()
        automaticObservation?.cancel()
        localChangeTask?.cancel()
        bootstrapRetryTask?.cancel()
        refreshTask?.cancel()
    }

    func prepareNewLibraryReview() async throws -> ICloudNewLibraryReview {
        guard archiveRecoverySession == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudCloudResetError.operationInProgress
        }
        let lifecycle = retentionLifecycle
        let review = try await newLibraryReviewer.prepare(using: newLibraryObserver)
        guard !Task.isCancelled, lifecycle == retentionLifecycle else {
            await newLibraryReviewer.discard(id: review.id)
            throw CancellationError()
        }
        return review
    }
    func discardNewLibraryReview(id: UUID) async { await newLibraryReviewer.discard(id: id) }

    func executeNewLibraryReview(id: UUID, newLibraryConfirmed: Bool, oldCloudRetentionConfirmed: Bool) async throws {
        guard archiveRecoverySession == nil, archiveRecoveryOperation == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudCloudResetError.operationInProgress
        }
        let lifecycle = retentionLifecycle
        let approved = try await newLibraryReviewer.approve(id: id, newLibraryConfirmed: newLibraryConfirmed,
                                                           oldCloudRetentionConfirmed: oldCloudRetentionConfirmed)
        try Task.checkCancellation()
        guard lifecycle == retentionLifecycle else { throw CancellationError() }
        let session = UUID(), operationID = UUID()
        archiveRecoverySession = session
        let coordinator = newLibraryCoordinator
        let transport = newLibraryTransportFactory?(approved.approval.operationID) ??
            ICloudCloudResetCloudKitTransport(repository: records, operationID: approved.approval.operationID)
        let isCurrent: @Sendable () async throws -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.newLibrarySessionIsCurrent(session)
        }
        let task = Task {
            await self.quiesceForArchive()
            try Task.checkCancellation()
            guard self.archiveRecoverySession == session else { throw CancellationError() }
            return try await coordinator.resume(operationID: approved.approval.operationID, using: transport,
                                               isCurrent: isCurrent)
        }
        archiveRecoveryOperation = (operationID, { task.cancel(); Task { await coordinator.stop() } })
        defer {
            if archiveRecoveryOperation?.id == operationID { archiveRecoveryOperation = nil }
            if archiveRecoverySession == session { archiveRecoverySession = nil }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel(); Task { await coordinator.stop() }
        }
        guard !Task.isCancelled, archiveRecoverySession == session, result.stage == .cloudReady,
              result.approval.previousDataDisposition == .preserve,
              result.approval.replacementProtocolVersion == 3 else { throw CancellationError() }
        await onChange()
    }
    private func newLibrarySessionIsCurrent(_ session: UUID) -> Bool { archiveRecoverySession == session }

    func prepareRetentionMaintenanceReview() async throws -> ICloudRetentionMaintenanceReview {
        guard archiveRecoverySession == nil, outcomeSession == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudRetentionMaintenanceError.existingJob
        }
        let lifecycle = retentionLifecycle
        let review = try await maintenanceReviewer.prepare()
        guard !Task.isCancelled, retentionIsCurrent(lifecycle) else {
            await maintenanceReviewer.discard(id: review.id); throw CancellationError()
        }
        return review
    }

    func discardRetentionMaintenanceReview(id: UUID) async { await maintenanceReviewer.discard(id: id) }

    func enableReviewedRetentionMaintenance(id: UUID, cleanupConfirmed: Bool, futureArticlesConfirmed: Bool,
                                           clockMaintenanceConfirmed: Bool) async throws {
        guard archiveRecoverySession == nil, outcomeSession == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudRetentionMaintenanceError.existingJob
        }
        let lifecycle = retentionLifecycle
        _ = try await maintenanceReviewer.approve(id: id, cleanupConfirmed: cleanupConfirmed,
            futureArticlesConfirmed: futureArticlesConfirmed, clockMaintenanceConfirmed: clockMaintenanceConfirmed)
        try Task.checkCancellation()
        guard retentionIsCurrent(lifecycle) else { throw CancellationError() }
        try await resumeRetentionMaintenance(lifecycle: lifecycle)
    }

    func retentionMaintenanceStatus() async throws -> ICloudRetentionMaintenanceStatus? {
        let context = try await records.retentionMaintenanceContext()
        guard context.state != nil else { return nil }
        return .init(context: context, failureMessage: maintenanceFailure)
    }

    func stopRetentionMaintenance(approvalID: String) async throws {
        // Durable revocation precedes cancellation. Late SDK returns cannot
        // re-enable a child, overwrite its UUID, or grant new future consent.
        try await records.disableRetentionMaintenance(approvalID: approvalID)
        await maintenanceScheduler.suspend()
        await retentionScheduler.suspend()
        maintenanceFailure = nil
    }

    func resumeEnabledRetentionMaintenance() async throws {
        guard archiveRecoverySession == nil, outcomeSession == nil,
              try await records.retentionMaintenanceContext().state?.schedule.enabled == true else {
            throw ICloudRetentionMaintenanceError.disabled
        }
        maintenanceFailure = nil
        try await resumeRetentionMaintenance(lifecycle: retentionLifecycle)
    }

    private func resumeRetentionMaintenance(lifecycle: UUID) async throws {
        try await maintenanceScheduler.resumeIfEnabled(isCurrent: { [weak self] in
            guard let self else { return false }
            return await self.retentionIsCurrent(lifecycle)
        }, launchJob: { [weak self] job in
            guard let self, await self.retentionIsCurrent(lifecycle) else { throw CancellationError() }
            try await self.launchRetention(job: job, resume: true, lifecycle: lifecycle)
        }, onFailure: { [weak self] error in
            await self?.maintenanceFailed(error, lifecycle: lifecycle)
        })
    }

    private func maintenanceFailed(_ error: any Error, lifecycle: UUID) {
        guard retentionLifecycle == lifecycle else { return }
        maintenanceFailure = ICloudSyncFailure.message(for: error)
    }

    func reviewRetentionOutcomes(approvalID: String) async throws -> ICloudRetentionOutcomeReviewResult {
        guard archiveRecoverySession == nil, outcomeTask == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudRetentionJobError.jobChanged
        }
        let id = UUID(), lifecycle = retentionLifecycle
        outcomeSession = id
        defer { if outcomeSession == id { outcomeSession = nil } }
        await maintenanceScheduler.suspend(waitForRequests: true)
        guard retentionLifecycle == lifecycle, outcomeSession == id else { throw CancellationError() }
        let reviewer = outcomeReviewer
        let reader = outcomeReaderFactory?(approvalID) ?? ICloudRetentionOutcomeCloudKitReader(repository: records, approvalID: approvalID)
        let current: @Sendable () async throws -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.outcomeIsCurrent(lifecycle: lifecycle, session: id)
        }
        let task = Task { try await reviewer.review(approvalID: approvalID, using: reader, isCurrent: current) }
        outcomeTask = (id, task)
        defer { if outcomeTask?.id == id { outcomeTask = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func outcomeIsCurrent(lifecycle: UUID, session: UUID) -> Bool {
        retentionLifecycle == lifecycle && outcomeSession == session && archiveRecoverySession == nil
    }

    func prepareRetentionReview(reset: Bool = false) async throws -> ICloudRetentionReview {
        guard retentionPreparation == nil, archiveRecoverySession == nil, outcomeSession == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudRetentionReviewError.existingJob
        }
        let lifecycle = retentionLifecycle, id = UUID()
        retentionPreparation = id
        defer { if retentionPreparation == id { retentionPreparation = nil } }
        let context: ICloudRetentionReviewContext
        do { context = try await records.retentionReviewContext() }
        catch ICloudRetentionJobError.approvalMismatch { throw ICloudRetentionReviewError.cloudPreparationRequired }
        guard retentionLifecycle == lifecycle else { throw CancellationError() }
        guard try await records.retentionMaintenanceContext().state?.schedule.enabled != true else {
            throw ICloudRetentionMaintenanceError.existingJob
        }
        if let job = context.job, !job.isFinished || job.attempts.contains(where: { $0.stage == .needsReview }) {
            throw ICloudRetentionReviewError.existingJob
        }
        let binding = ICloudRetentionDiscoveryBinding(context)
        if reset || retentionDiscovery == nil || retentionDiscoveryBinding != binding {
            await retentionDiscovery?.cancel()
            retentionDiscovery = ICloudRetentionDiscoveryScanner(source: sync)
            retentionDiscoveryBinding = binding
        }
        let scanner = retentionDiscovery!, protection = try await records.maintenanceProtection(), scannedAt = Date()
        let names = try await scanner.scan(protection: protection, now: scannedAt)
        guard retentionLifecycle == lifecycle, retentionDiscovery === scanner else { throw CancellationError() }
        let review = try await retentionReviewer.prepare(names: names, context: context, scannedAt: scannedAt)
        guard !Task.isCancelled, retentionLifecycle == lifecycle else {
            await retentionReviewer.discard(id: review.id)
            throw CancellationError()
        }
        return review
    }

    func discardRetentionReview(id: UUID) async { await retentionReviewer.discard(id: id) }

    func startReviewedRetention(id: UUID, cleanupConfirmed: Bool, clockMaintenanceConfirmed: Bool) async throws {
        guard archiveRecoverySession == nil, outcomeSession == nil, localCopyOperation == nil, sameAccountResume == nil else { throw ICloudRetentionReviewError.existingJob }
        let lifecycle = retentionLifecycle
        let job = try await retentionReviewer.approve(id: id, cleanupConfirmed: cleanupConfirmed,
                                                     clockMaintenanceConfirmed: clockMaintenanceConfirmed)
        guard retentionLifecycle == lifecycle else { throw CancellationError() }
        try await launchRetention(job: job, resume: false, lifecycle: lifecycle)
    }

    func retentionProgress() async throws -> ICloudRetentionProgress? {
        let context = try await records.retentionReviewContext()
        guard let job = context.job else { return nil }
        let state = try await records.retentionScheduleState(approvalID: job.approval.approvalID)
        return .init(job: job, schedule: state, failureMessage: retentionFailure)
    }

    func resumeReviewedRetention(approvalID: String) async throws {
        guard outcomeSession == nil else { throw ICloudRetentionJobError.jobChanged }
        let job = try await records.retentionJob(approvalID: approvalID)
        try await launchRetention(job: job, resume: false, lifecycle: retentionLifecycle)
        if job.approval.maintenanceApprovalID != nil { try await resumeRetentionMaintenance(lifecycle: retentionLifecycle) }
    }

    func stopReviewedRetention(approvalID: String) async throws {
        let job = try await records.retentionJob(approvalID: approvalID, requiresExecutionAuthorization: false)
        if let parent = job.approval.maintenanceApprovalID {
            try await stopRetentionMaintenance(approvalID: parent); return
        }
        try await retentionScheduler.stop(approvalID: approvalID)
    }

    private func launchRetention(job: ICloudRetentionJob, resume: Bool, lifecycle: UUID) async throws {
        let transport = retentionTransportFactory?(job.approval.approvalID) ??
            ICloudRetentionCloudKitTransport(repository: records, approvalID: job.approval.approvalID)
        let current: @Sendable () async throws -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.retentionIsCurrent(lifecycle)
        }
        let event: @Sendable (ICloudRetentionSchedulingEvent) async -> Void = { [weak self] event in
            await self?.retentionEvent(event, lifecycle: lifecycle)
        }
        retentionFailure = nil
        if resume {
            try await retentionScheduler.resumeIfEnabled(approvalID: job.approval.approvalID,
                using: transport, isCurrent: current, onEvent: event)
        } else {
            try await retentionScheduler.start(approvalID: job.approval.approvalID,
                using: transport, isCurrent: current, onEvent: event)
        }
    }
    private func retentionIsCurrent(_ lifecycle: UUID) -> Bool {
        retentionLifecycle == lifecycle && archiveRecoverySession == nil && outcomeSession == nil
    }
    private func retentionEvent(_ event: ICloudRetentionSchedulingEvent, lifecycle: UUID) {
        guard retentionLifecycle == lifecycle else { return }
        if case .failed(let error) = event { retentionFailure = ICloudSyncFailure.message(for: error) }
    }
    private func resumeApprovedRetention() async {
        guard archiveRecoverySession == nil, outcomeSession == nil else { return }
        if let context = try? await records.retentionMaintenanceContext(), context.state?.schedule.enabled == true {
            try? await resumeRetentionMaintenance(lifecycle: retentionLifecycle); return
        }
        guard
              let context = try? await records.retentionReviewContext(), let job = context.job,
              !job.isFinished, job.approval.allowsClockMaintenance else { return }
        try? await launchRetention(job: job, resume: true, lifecycle: retentionLifecycle)
    }

    func scanCloudInventory(reset: Bool) async throws -> ICloudCloudInventory {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        if reset || inventoryScanner == nil {
            await inventoryScanner?.cancel()
            inventoryScanner = ICloudInventoryScanner(source: sync)
        }
        let scanner = inventoryScanner!
        let metadata = try await scanner.scan()
        guard inventoryScanner === scanner else { throw CancellationError() }
        // Read protection after the network pages, so edits made while scanning
        // cannot disappear from the preview simply because it started earlier.
        let protection = try await records.maintenanceProtection()
        let snapshot = try await records.accountSnapshot()
        let complete = await scanner.isComplete
        let limited = await scanner.didReachSafetyLimit
        let foreign = await scanner.foreignRecordCount
        let foreignZones = await scanner.foreignZoneCount
        guard inventoryScanner === scanner else { throw CancellationError() }
        return ICloudMaintenancePlanner.inventory(records: metadata,
            isComplete: complete, reachedSafetyLimit: limited,
            syncUnreadContent: snapshot.syncUnreadContent, protection: protection,
            otherGenerationRecords: foreign, otherGenerationZones: foreignZones)
    }

    func refresh(reason: RefreshReason) async throws -> RefreshResult {
        try await refresh(feedIDs: nil, reason: reason)
    }

    func prepareLocalCopy(catalog: ICloudCopySourceCatalog, selection: ICloudCopySelection) async throws -> ICloudCopyReview {
        guard localCopyOperation == nil, sameAccountResume == nil, archiveRecoverySession == nil else { throw ICloudLocalCopyError.copyInProgress }
        localCopyReview = nil
        let lifecycle = localCopyLifecycle, operationID = UUID()
        let task = Task {
            try Task.checkCancellation()
            let request = ICloudLocalCopyRepository.Selection(sourceAccountID: catalog.sourceAccountID,
                targetAccountID: self.accountID, feedIDs: selection.feedIDs, folderIDs: selection.folderIDs,
                articles: selection.includeReliableArticles ? .reliableArticles : .none, reviewedLinkIDs: selection.reviewedLinkIDs)
            let copier = ICloudLocalCopyRepository(database: self.database)
            try await copier.preflightCatalog(catalog, selection: request)
            try Task.checkCancellation()
            guard self.localCopyLifecycle == lifecycle else { throw CancellationError() }
            let context = try await self.sync.restoreForLocalCopy()
            try Task.checkCancellation()
            guard self.localCopyLifecycle == lifecycle else { throw CancellationError() }
            return try await copier.prepare(selection: request, context: context, catalog: catalog)
        }
        localCopyOperation = (operationID, { task.cancel() })
        defer { if localCopyOperation?.id == operationID { localCopyOperation = nil } }
        let plan = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        guard localCopyLifecycle == lifecycle else { throw CancellationError() }
        let id = UUID()
        localCopyReview = (id, plan)
        return .init(id: id, counts: .init(plan.counts), preparedAt: plan.preparedAt)
    }

    func discardLocalCopyReview(id: UUID) {
        if localCopyReview?.id == id { localCopyReview = nil }
    }

    func executeLocalCopy(reviewID: UUID) async throws -> ICloudCopyResult {
        guard localCopyOperation == nil, sameAccountResume == nil, archiveRecoverySession == nil else { throw ICloudLocalCopyError.copyInProgress }
        guard let review = localCopyReview, review.id == reviewID else { throw ICloudLocalCopyError.stalePlan }
        localCopyReview = nil // One explicit confirmation, never an automatic retry.
        let lifecycle = localCopyLifecycle, operationID = UUID(), plan = review.plan
        let task = Task {
            try Task.checkCancellation()
            let context = try await self.sync.restoreForLocalCopy()
            try Task.checkCancellation()
            guard self.localCopyLifecycle == lifecycle else { throw CancellationError() }
            guard context == plan.context else { throw ICloudLocalCopyError.stalePlan }
            let result = try await ICloudLocalCopyRepository(database: self.database).execute(.init(plan))
            // Past this point the transaction committed. Cancellation/network
            // failure cannot turn it into a failed copy or prompt duplication.
            await self.onChange()
            var warning: String?
            if self.localCopyLifecycle != lifecycle || Task.isCancelled {
                warning = ICloudSyncFailure.message(for: CancellationError())
            } else {
                do { try await self.sync.localChangesAvailable() }
                catch { warning = ICloudSyncFailure.message(for: error) }
            }
            return ICloudCopyResult(counts: .init(result), syncWarning: warning)
        }
        localCopyOperation = (operationID, { task.cancel() })
        defer { if localCopyOperation?.id == operationID { localCopyOperation = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func resumeOriginalAccount() async throws -> ICloudSameAccountResumeResult {
        guard sameAccountResume == nil, localCopyOperation == nil, archiveRecoverySession == nil else {
            throw ICloudSameAccountResumeError.operationInProgress
        }
        let lifecycle = localCopyLifecycle, id = UUID()
        let task = Task {
            try Task.checkCancellation()
            try await self.sync.resumeOriginalAccount()
            // The local pause has been released. Preserve that result even if
            // the subsequent fetch fails, or the caller closes its sheet.
            var warning: String?
            if self.localCopyLifecycle != lifecycle || Task.isCancelled {
                warning = ICloudSyncFailure.message(for: CancellationError())
            } else {
                do {
                    try await self.sync.fetchChanges()
                    try Task.checkCancellation()
                    guard self.localCopyLifecycle == lifecycle else { throw CancellationError() }
                    try await self.sync.localChangesAvailable()
                } catch {
                    warning = ICloudSyncFailure.message(for: error)
                    if let session = self.automaticSession { await self.scheduleBootstrapRetry(for: error, session: session) }
                }
            }
            await self.onChange()
            let snapshot = try? await self.records.accountSnapshot()
            return ICloudSameAccountResumeResult(isPaused: snapshot?.isPaused ?? true, syncWarning: warning)
        }
        sameAccountResume = (id, { task.cancel() })
        defer { if sameAccountResume?.id == id { sameAccountResume = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func prepareArchiveRecovery() async throws -> ICloudArchiveRecoveryReview {
        guard archiveRecoveryOperation == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudArchiveRecoveryError.operationInProgress
        }
        archiveRecoveryReview = nil
        let session = UUID(), operationID = UUID()
        archiveRecoverySession = session
        let task = Task {
            await self.quiesceForArchive()
            try Task.checkCancellation()
            guard self.archiveRecoverySession == session else { throw CancellationError() }
            let plan = try await self.sync.prepareArchiveRecovery()
            if Task.isCancelled || self.archiveRecoverySession != session {
                await self.sync.discardArchiveRecovery(planID: plan.id)
                throw CancellationError()
            }
            return plan
        }
        archiveRecoveryOperation = (operationID, { task.cancel() })
        defer { if archiveRecoveryOperation?.id == operationID { archiveRecoveryOperation = nil } }
        do {
            let plan = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, archiveRecoverySession == session else {
                await sync.discardArchiveRecovery(planID: plan.id)
                throw CancellationError()
            }
            let id = UUID()
            archiveRecoveryReview = (id, plan)
            return .init(id: id, counts: plan.review, preparedAt: .now, needsCloudInitialization: plan.needsCloudInitialization)
        } catch {
            if archiveRecoverySession == session { archiveRecoverySession = nil }
            throw error
        }
    }

    func discardArchiveRecoveryReview(id: UUID) async {
        guard let review = archiveRecoveryReview, review.id == id else { return }
        archiveRecoveryReview = nil
        archiveRecoverySession = nil
        await sync.discardArchiveRecovery(planID: review.plan.id)
    }

    /// No post-commit refresh or change callback here: AppStore first installs
    /// the new account/provider and removes the old route, then projects it.
    func executeArchiveRecovery(reviewID: UUID, initializeEmptyCloudConfirmed: Bool = false) async throws -> AccountRecord {
        guard archiveRecoveryOperation == nil, localCopyOperation == nil, sameAccountResume == nil else {
            throw ICloudArchiveRecoveryError.operationInProgress
        }
        guard let review = archiveRecoveryReview, review.id == reviewID, let session = archiveRecoverySession else {
            throw ICloudArchiveRecoveryError.staleReview
        }
        guard !review.plan.needsCloudInitialization || initializeEmptyCloudConfirmed else {
            throw ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired
        }
        archiveRecoveryReview = nil
        let operationID = UUID()
        let task = Task {
            try Task.checkCancellation()
            guard self.archiveRecoverySession == session else { throw CancellationError() }
            return try await self.sync.executeArchiveRecovery(review.plan, initializeEmptyCloudConfirmed: initializeEmptyCloudConfirmed)
        }
        archiveRecoveryOperation = (operationID, { task.cancel() })
        defer { if archiveRecoveryOperation?.id == operationID { archiveRecoveryOperation = nil } }
        do {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch {
            if archiveRecoverySession == session { archiveRecoverySession = nil }
            await sync.discardArchiveRecovery(planID: review.plan.id)
            throw error
        }
    }

    private func quiesceForArchive() async {
        await newLibraryReviewer.discard()
        retentionLifecycle = UUID()
        retentionPreparation = nil
        outcomeSession = nil
        let outcome = outcomeTask?.task
        outcome?.cancel()
        await outcomeReviewer.stop()
        await maintenanceReviewer.discard()
        await maintenanceScheduler.suspend(waitForRequests: true)
        await retentionReviewer.discard()
        await retentionScheduler.suspend(waitForRequests: true)
        _ = try? await outcome?.value
        let discovery = retentionDiscovery
        retentionDiscovery = nil; retentionDiscoveryBinding = nil
        await discovery?.cancel()
        // Stop producers first, before starting the driver's exclusive review.
        // Await application tasks; SDK cancellation alone does not drain them.
        let refresh = refreshTask, observation = automaticObservation, changes = localChangeTask, retry = bootstrapRetryTask
        automaticSession = nil
        automaticObservation?.cancel(); automaticObservation = nil
        localChangeTask?.cancel(); localChangeTask = nil
        cancelBootstrapRetry()
        refreshTask?.cancel(); refreshTask = nil; refreshTaskID = nil
        await sync.stop()
        _ = try? await refresh?.value
        await observation?.value
        await changes?.value
        await retry?.value
        let scanner = inventoryScanner
        inventoryScanner = nil
        await scanner?.cancel()
        await onProgress(nil)
    }

    func refresh(feedIDs: Set<UUID>?, reason: RefreshReason) async throws -> RefreshResult {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        if let refreshTask {
            if refreshFeedIDs == nil || refreshFeedIDs == feedIDs { return try await refreshTask.value }
            let previousID = refreshTaskID
            _ = try await refreshTask.value
            if refreshTaskID == previousID { self.refreshTask = nil; refreshTaskID = nil }
            return try await refresh(feedIDs: feedIDs, reason: reason)
        }
        let id = UUID()
        let task = Task { try await performRefresh(reason: reason, feedIDs: feedIDs) }
        refreshTask = task
        refreshTaskID = id
        refreshFeedIDs = feedIDs
        defer { if refreshTaskID == id { refreshTask = nil; refreshTaskID = nil } }
        do {
            let result = try await task.value
            if refreshTaskID == id { await onProgress(nil) }
            return result
        } catch {
            if refreshTaskID == id { await onProgress(nil) }
            throw error
        }
    }

    /// Observation watches only metadata. The clock changes in the same
    /// transaction as every captured edit, including bulk SQL and OPML.
    func startAutomaticSync() async {
        guard sync.supportsAutomaticSync, automaticSession == nil, archiveRecoverySession == nil else { return }
        let session = UUID()
        automaticSession = session
        automaticFailureReported = false
        lastForegroundFetchAt = nil
        foregroundFetchID = nil
        do {
            let callback: @Sendable (ICloudAutomaticSyncEvent) async -> Void = { [weak self] event in
                await self?.automaticEvent(event, session: session)
            }
            let signal = try await database.readAsync { try ICloudAutomaticSyncSignal.fetch(accountID: self.accountID, in: $0) }
            guard automaticSession == session else { return }
            guard let signal, signal.isEnabled, signal.captureEnabled else { await stop(); return }
            let waiting = signal.isPaused ? false : try await waitForBootstrapRetry(session: session)
            if signal.isPaused || waiting {
                // Install callbacks without bypassing a persisted server wait.
                try await sync.prepareAutomaticSync(onEvent: callback)
            } else {
                try await sync.startAutomaticSync(onEvent: callback)
            }
        } catch { await automaticEvent(.failed(error), session: session) }
        guard automaticSession == session else { return }
        let database = self.database, accountID = self.accountID
        let observation = ValueObservation.tracking { db in
            try ICloudAutomaticSyncSignal.fetch(accountID: accountID, in: db)
        }.removeDuplicates()
        automaticObservation = Task { [weak self] in
            do {
                for try await signal in observation.values(in: database.dbPool, bufferingPolicy: .bufferingNewest(1)) {
                    guard !Task.isCancelled else { return }
                    await self?.metadataChanged(signal, session: session)
                }
            } catch {
                if !Task.isCancelled { await self?.automaticEvent(.failed(error), session: session) }
            }
        }
        await resumeApprovedRetention()
    }

    func resumeAutomaticSync(fetchRemote: Bool = false) async {
        guard archiveRecoverySession == nil else { return }
        await startAutomaticSync()
        await resumeApprovedRetention()
        guard let session = automaticSession else { return }
        do {
            let current = try await database.readAsync { try ICloudAutomaticSyncSignal.fetch(accountID: self.accountID, in: $0) }
            guard automaticSession == session else { return }
            guard let current, current.isEnabled, current.captureEnabled, !current.isPaused else {
                await metadataChanged(current, session: session)
                return
            }
            if fetchRemote {
                do {
                    try await fetchForegroundChangesIfDue(session: session)
                }
                catch ICloudEngineError.alreadySyncing {}
                catch { await automaticEvent(.failed(error), session: session) }
            }
            let signal = try await database.readAsync { try ICloudAutomaticSyncSignal.fetch(accountID: self.accountID, in: $0) }
            await metadataChanged(signal, session: session)
        } catch { await automaticEvent(.failed(error), session: session) }
    }

    /// Only activation-driven pulls are throttled. Durable local edits, SDK
    /// push delivery and explicit refresh continue through their own paths.
    private func fetchForegroundChangesIfDue(session: UUID) async throws {
        guard foregroundFetchID == nil else { return }
        let now = foregroundNow()
        if let lastForegroundFetchAt {
            let elapsed = now.timeIntervalSince(lastForegroundFetchAt)
            if elapsed >= 0, elapsed < Self.foregroundFetchInterval { return }
        }
        let id = UUID()
        foregroundFetchID = id
        defer { if foregroundFetchID == id { foregroundFetchID = nil } }
        guard !(try await waitForBootstrapRetry(session: session)), automaticSession == session else { return }
        lastForegroundFetchAt = now
        do {
            try await sync.fetchChanges()
        } catch {
            if automaticSession == session { lastForegroundFetchAt = nil }
            throw error
        }
    }

    private func metadataChanged(_ signal: ICloudAutomaticSyncSignal?, session: UUID) async {
        guard automaticSession == session else { return }
        guard let signal, signal.isEnabled, signal.captureEnabled else {
            await stop()
            return
        }
        if signal.isPaused {
            await maintenanceScheduler.suspend()
            await retentionScheduler.suspend()
            outcomeSession = nil; outcomeTask?.task.cancel()
            await outcomeReviewer.stop()
            localChangeTask?.cancel()
            cancelBootstrapRetry()
            await sync.stop()
            await onProgress(nil)
            return
        }
        // Coalesce a burst without dropping edits made while the engine sends.
        localChangeTask?.cancel()
        localChangeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await self?.announceLocalChanges(session: session)
            } catch {}
        }
    }

    private func announceLocalChanges(session: UUID) async {
        guard automaticSession == session else { return }
        do {
            let signal = try await database.readAsync { try ICloudAutomaticSyncSignal.fetch(accountID: self.accountID, in: $0) }
            guard automaticSession == session else { return }
            guard let signal, signal.isEnabled, signal.captureEnabled, !signal.isPaused else { return }
            if try await waitForBootstrapRetry(session: session) { return }
            let revision = await sync.requiresBootstrapRetry ? try await records.bootstrapRetryState().revision : nil
            guard automaticSession == session else { return }
            automaticFailureReported = false
            try await sync.localChangesAvailable()
            guard automaticSession == session else { return }
            if let revision, await !sync.requiresBootstrapRetry {
                try await records.clearBootstrapRetry(expectedRevision: revision)
                guard automaticSession == session else { return }
                let state = try await records.bootstrapRetryState()
                if automaticSession == session, state.deadline == nil { cancelBootstrapRetry() }
            }
        } catch {
            if !Task.isCancelled { await automaticEvent(.failed(error), session: session) }
        }
    }

    private func automaticEvent(_ event: ICloudAutomaticSyncEvent, session: UUID) async {
        guard automaticSession == session else { return }
        if case .failed(let error) = event { await scheduleBootstrapRetry(for: error, session: session) }
        guard automaticSession == session, refreshTask == nil else { return }
        do {
            let now = Date().timeIntervalSince1970
            switch event {
            case .changed:
                await onChange()
                return
            case .started:
                automaticFailureReported = false
                let showsInitialProgress = try await database.writeAsync { db in
                    guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else { return false }
                    var state = try AccountSyncStateRecord.fetchOne(db, key: self.accountID) ?? .init(accountID: self.accountID)
                    state.lastSyncStartedAt = now
                    try state.save(db)
                    return !state.initialSyncCompleted
                }
                guard automaticSession == session, refreshTask == nil else { return }
                if showsInitialProgress { await onProgress(.init()) }
            case .completed:
                let snapshot = try await records.accountSnapshot()
                guard automaticSession == session else { return }
                if snapshot.pendingChanges == 0, !snapshot.isPaused {
                    try await database.writeAsync { db in
                        guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else { return }
                        var state = try AccountSyncStateRecord.fetchOne(db, key: self.accountID) ?? .init(accountID: self.accountID)
                        state.initialSyncCompleted = true
                        state.lastSyncCompletedAt = now
                        state.consecutiveFailureCount = 0
                        state.lastError = nil
                        try state.save(db)
                    }
                }
                guard automaticSession == session, refreshTask == nil else { return }
                await onProgress(nil)
            case .failed(let error):
                lastForegroundFetchAt = nil
                guard !automaticFailureReported else { return }
                automaticFailureReported = true
                let message = ICloudSyncFailure.message(for: error)
                try await database.writeAsync { db in
                    guard try AccountRecord.fetchOne(db, key: self.accountID)?.isEnabled == true else { return }
                    var state = try AccountSyncStateRecord.fetchOne(db, key: self.accountID) ?? .init(accountID: self.accountID)
                    state.consecutiveFailureCount += 1
                    state.lastError = message
                    try state.save(db)
                }
                guard automaticSession == session, refreshTask == nil else { return }
                await onProgress(nil)
            }
            guard automaticSession == session else { return }
            await onChange()
        } catch {
            // A failed local write cannot become successful sync evidence.
            await onProgress(nil)
        }
    }

    private func waitForBootstrapRetry(session: UUID) async throws -> Bool {
        guard await sync.requiresBootstrapRetry else { return false }
        let state = try await records.bootstrapRetryState()
        guard automaticSession == session else { throw CancellationError() }
        guard let deadline = state.deadline, deadline > bootstrapNow() else { return false }
        armBootstrapRetry(deadline: deadline, session: session)
        return true
    }

    private func scheduleBootstrapRetry(for error: any Error, session: UUID) async {
        // The SDK owns ordinary record retries. This timer only recovers an
        // engine that could not start, or whose delegate had to stop applying.
        guard ICloudBootstrapRetryPolicy.delay(for: error, attempt: 1) != nil,
              await sync.requiresBootstrapRetry, automaticSession == session else { return }
        do {
            let deadline = try await records.scheduleBootstrapRetry(for: error, now: bootstrapNow())
            guard automaticSession == session, let deadline else { return }
            armBootstrapRetry(deadline: deadline, session: session)
        } catch {}
    }

    private func armBootstrapRetry(deadline: Date, session: UUID) {
        guard automaticSession == session else { return }
        if bootstrapDeadline == deadline, bootstrapRetryTask != nil { return }
        cancelBootstrapRetry()
        let id = UUID(), sleep = bootstrapSleep
        let delay = min(ICloudBootstrapRetryPolicy.maximumDelay, max(0, deadline.timeIntervalSince(bootstrapNow())))
        bootstrapRetryID = id
        bootstrapDeadline = deadline
        bootstrapRetryTask = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.bootstrapRetryFired(id: id, session: session)
            } catch {}
        }
    }

    private func bootstrapRetryFired(id: UUID, session: UUID) async {
        guard automaticSession == session, bootstrapRetryID == id else { return }
        bootstrapRetryTask = nil
        bootstrapRetryID = nil
        bootstrapDeadline = nil
        await announceLocalChanges(session: session)
    }

    private func cancelBootstrapRetry() {
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        bootstrapRetryID = nil
        bootstrapDeadline = nil
    }

    private func performRefresh(reason: RefreshReason, feedIDs: Set<UUID>?) async throws -> RefreshResult {
        let started = Date().timeIntervalSince1970
        try await database.writeAsync { db in
            var state = try AccountSyncStateRecord.fetchOne(db, key: self.accountID) ?? AccountSyncStateRecord(accountID: self.accountID)
            state.lastSyncStartedAt = started
            try state.save(db)
        }
        await onProgress(.init())
        var cloudFailure: (any Error)?
        do { try await sync.fetchChanges() } catch {
            cloudFailure = error
            if let session = automaticSession { await scheduleBootstrapRetry(for: error, session: session) }
        }
        try Task.checkCancellation()
        var seenFeedIDs = Set<UUID>()
        let feeds = try local.fetchFeeds().filter {
            (feedIDs?.contains($0.id) ?? true) && seenFeedIDs.insert($0.id).inserted
        }
        var completed = 0
        var feedFailures = 0
        await onProgress(.init(completed: 0, total: feeds.count))
        // Bound network concurrency to the same six feeds as the local path.
        await withTaskGroup(of: LocalAccountProvider.SingleFeedRefreshResult.self) { group in
            var index = 0
            for _ in 0..<min(6, feeds.count) {
                let feed = feeds[index]; index += 1
                group.addTask { await self.local.fetchSingleFeed(feed: feed) }
            }
            while let result = await group.next() {
                if case .failure = result.result { feedFailures += 1 }
                do { _ = try await local.applyRefreshResultAsync(result) }
                catch { feedFailures += 1 }
                completed += 1
                await onProgress(.init(completed: completed, total: feeds.count))
                if index < feeds.count {
                    let feed = feeds[index]; index += 1
                    group.addTask { await self.local.fetchSingleFeed(feed: feed) }
                }
            }
        }
        try Task.checkCancellation()
        // This is independent of network availability: statuses fetched earlier
        // or before a restart still apply to newly materialized RSS items.
        do { try records.reconcileInbox() } catch { cloudFailure = cloudFailure ?? error }
        if cloudFailure == nil {
            do { try await sync.sendChanges() } catch {
                cloudFailure = error
                if let session = automaticSession { await scheduleBootstrapRetry(for: error, session: session) }
            }
        }
        let finished = Date().timeIntervalSince1970
        let message = cloudFailure.map { ICloudSyncFailure.message(for: $0) } ??
            (feedFailures > 0 ? I18N.localized("部分订阅刷新失败。", englishFallback: "Some feeds failed to refresh.") : nil)
        try await database.writeAsync { db in
            var state = try AccountSyncStateRecord.fetchOne(db, key: self.accountID) ?? AccountSyncStateRecord(accountID: self.accountID)
            state.lastArticleFetchAt = finished
            if message == nil {
                state.initialSyncCompleted = true; state.lastSyncCompletedAt = finished
                state.consecutiveFailureCount = 0; state.lastError = nil
            } else {
                state.consecutiveFailureCount += 1; state.lastError = message
            }
            try state.save(db)
        }
        return RefreshResult(status: message.map(RefreshResult.Status.failed) ?? .success)
    }

    func pushPendingArticleStates() async throws {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        if sync.supportsAutomaticSync {
            await startAutomaticSync()
        } else {
            try await sync.sendChanges()
        }
    }
    func stop() async {
        archiveRecoverySession = nil
        retentionLifecycle = UUID()
        retentionPreparation = nil
        outcomeSession = nil
        outcomeTask?.task.cancel()
        await outcomeReviewer.stop()
        await maintenanceReviewer.discard()
        await maintenanceScheduler.suspend()
        await newLibraryReviewer.discard()
        await newLibraryCoordinator.stop()
        let discovery = retentionDiscovery
        retentionDiscovery = nil
        retentionDiscoveryBinding = nil
        await discovery?.cancel()
        await retentionReviewer.discard()
        await retentionScheduler.suspend()
        archiveRecoveryReview = nil
        archiveRecoveryOperation?.cancel()
        archiveRecoveryOperation = nil
        localCopyLifecycle = UUID()
        localCopyReview = nil
        localCopyOperation?.cancel()
        localCopyOperation = nil
        sameAccountResume?.cancel()
        sameAccountResume = nil
        let scanner = inventoryScanner
        inventoryScanner = nil
        automaticSession = nil
        automaticObservation?.cancel()
        automaticObservation = nil
        localChangeTask?.cancel()
        localChangeTask = nil
        cancelBootstrapRetry()
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        await sync.stop()
        await scanner?.cancel()
        if automaticSession == nil, refreshTask == nil { await onProgress(nil) }
    }
    func addFeed(url: URL, title: String?, folder: String?) async throws -> Feed {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        return try await local.addFeed(url: url, title: title, folder: folder)
    }
    func deleteFeed(feedID: UUID) async throws {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        try await local.deleteFeed(feedID: feedID)
    }
    func renameFeed(feedID: UUID, newTitle: String) async throws {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        try await local.renameFeed(feedID: feedID, newTitle: newTitle)
    }
    func addFolder(name: String) async throws -> FolderRecord {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        return try await local.addFolder(name: name)
    }
    func deleteFolder(name: String) async throws {
        guard archiveRecoverySession == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        try await local.deleteFolder(name: name)
    }
}

struct ICloudAutomaticSyncSignal: Sendable, Equatable {
    let clock: Int64
    let isEnabled: Bool
    let captureEnabled: Bool
    let isPaused: Bool

    static func fetch(accountID: String, in db: Database) throws -> Self? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.logical_clock, s.capture_enabled, s.pause_reason, a.is_enabled
            FROM icloud_sync_scope s JOIN accounts a ON a.id = s.account_id
            WHERE s.account_id = ? AND a.type = 'iCloud';
            """, arguments: [accountID]) else { return nil }
        return .init(clock: row["logical_clock"], isEnabled: row["is_enabled"],
                     captureEnabled: row["capture_enabled"], isPaused: row["pause_reason"] as String? != nil)
    }
}

enum ICloudSyncFailure {
    /// User-facing errors deliberately exclude raw CKError descriptions, which
    /// can include private record/URL fields. Detailed state stays in the queue.
    static func message(for error: any Error) -> String {
        switch error {
        case ICloudNewLibraryReviewError.newLibraryConfirmationRequired:
            return I18N.localized("请确认建立空的新云库及其他设备的同步影响。", englishFallback: "Confirm creating an empty replacement cloud library and its effect on syncing other devices.")
        case ICloudNewLibraryReviewError.oldCloudRetentionRequired:
            return I18N.localized("请确认旧云资料继续保留并占用 iCloud 空间。", englishFallback: "Confirm retaining the previous cloud data and its iCloud storage usage.")
        case ICloudNewLibraryReviewError.staleReview:
            return I18N.localized("新云库准备预览已过期或账号范围已变化，请重新核验。", englishFallback: "The new-library review expired or the account scope changed. Verify again.")
        case ICloudNewLibraryReviewError.unavailableScope:
            return I18N.localized("当前范围不适用保留旧云资料的新云库准备，请先核对恢复进度。", englishFallback: "This scope is not eligible for preparing a new library while retaining old cloud data. Review recovery progress first.")
        case ICloudRetentionReviewError.confirmationRequired:
            return I18N.localized("请先审阅并确认本次云端历史清理的影响。", englishFallback: "Review and confirm the effects of this cloud history cleanup first.")
        case ICloudRetentionMaintenanceError.confirmationRequired:
            return I18N.localized("请分别确认历史恢复影响、以后文章的持续维护和额外时间控制保存。", englishFallback: "Separately confirm the history recovery effects, ongoing maintenance of future articles and extra server-time control saves.")
        case ICloudRetentionMaintenanceError.disabled:
            return I18N.localized("持续维护授权已停用。请重新审阅并确认后继续，原任务记录仍保留。", englishFallback: "Ongoing maintenance consent is disabled. Review and confirm before continuing. Original task records are retained.")
        case ICloudRetentionMaintenanceError.staleReview, ICloudRetentionMaintenanceError.invalidState:
            return I18N.localized("持续维护预览已过期或账号范围已变化，请重新核验。", englishFallback: "The ongoing maintenance review expired or the account scope changed. Verify again.")
        case ICloudRetentionMaintenanceError.existingJob:
            return I18N.localized("现有授权或任务仍在使用此范围，请先停用维护并查看任务进度。", englishFallback: "Existing consent or a task is using this scope. Disable maintenance and review task progress first.")
        case ICloudRetentionReviewError.clockMaintenanceRequired:
            return I18N.localized("请单独确认用于核验服务器时间的额外控制写入。", englishFallback: "Separately confirm the extra control writes used to verify server time.")
        case ICloudRetentionReviewError.scanIncomplete:
            return I18N.localized("候选核验尚未完成或达到统计上限，请继续读取或缩小范围。", englishFallback: "Candidate verification is incomplete or reached the scan limit. Continue reading or narrow the scope.")
        case ICloudRetentionReviewError.noCandidates:
            return I18N.localized("本次没有可提交审阅的清理候选。", englishFallback: "There are no cleanup candidates to review in this scan.")
        case ICloudRetentionReviewError.existingJob:
            return I18N.localized("现有清理或恢复任务仍需处理，请先查看其进度。", englishFallback: "An existing cleanup or recovery task still needs attention. Review its progress first.")
        case ICloudRetentionReviewError.staleReview:
            return I18N.localized("清理预览已过期或资料范围已变化，请重新核验。", englishFallback: "The cleanup review expired or the data scope changed. Verify again.")
        case ICloudRetentionReviewError.cloudPreparationRequired, ICloudRetentionJobError.approvalMismatch:
            return I18N.localized("当前云库尚未满足安全清理条件，请先完成新云库准备及旧资料恢复核验。", englishFallback: "The current cloud library is not ready for safe cleanup. Finish preparing the new library and reviewing recovery of old data first.")
        case ICloudRetentionJobError.jobChanged, ICloudRetentionJobError.needsReview:
            return I18N.localized("清理任务或云端证据已变化，需要重新审阅。", englishFallback: "The cleanup task or cloud evidence changed and needs another review.")
        case ICloudArchiveRecoveryError.connectionConfirmationRequired:
            return I18N.localized("请先确认连接当前 iCloud 账号进行恢复核验。", englishFallback: "Confirm connecting to the current iCloud account for recovery verification first.")
        case ICloudArchiveRecoveryError.archiveConfirmationRequired:
            return I18N.localized("请先审阅并确认保留旧资料的只读本机归档。", englishFallback: "Review and confirm retaining old data as a read-only local archive first.")
        case ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired:
            return I18N.localized("请先确认建立新的空 iCloud 云库，旧归档资料不会自动带入。", englishFallback: "Confirm creating a new empty iCloud library first. Old archive data is not brought in automatically.")
        case ICloudArchiveRecoveryError.unavailableSource:
            return I18N.localized("当前账号不适用归档恢复，请先核对本机恢复资料。", englishFallback: "This account is not eligible for archive recovery. Review local recovery data first.")
        case ICloudArchiveRecoveryError.cloudNeedsReview:
            return I18N.localized("当前云库尚未准备完成或无法核实，旧资料保持原状，请重新核验。", englishFallback: "The current cloud library is not ready or could not be verified. Old data is unchanged. Verify again.")
        case ICloudArchiveRecoveryError.staleReview, ICloudArchiveRecoveryError.expiredReview:
            return I18N.localized("归档预览已过期，或账号与资料已变化，请重新核验。", englishFallback: "The archive review expired, or the account or data changed. Verify again.")
        case ICloudArchiveRecoveryError.safetyLimit:
            return I18N.localized("归档恢复核验达到安全限制，旧资料保持原状，请稍后重试。", englishFallback: "Archive recovery verification reached its safety limit. Old data is unchanged. Try again later.")
        case ICloudArchiveRecoveryError.operationInProgress:
            return I18N.localized("归档恢复仍在核验或等待确认，请先完成或关闭恢复窗口。", englishFallback: "Archive recovery is being verified or awaiting confirmation. Finish or close the recovery window first.")
        case ICloudArchiveRecoveryError.readonlyArchive:
            return I18N.localized("这是只读本机归档，原资料与阅读状态保持保留。", englishFallback: "This is a read-only local archive. Original data and reading states are retained.")
        case ICloudSameAccountResumeError.confirmationRequired:
            return I18N.localized("请先确认恢复原 iCloud 账号的同步。", englishFallback: "Confirm resuming sync for the original iCloud account first.")
        case ICloudSameAccountResumeError.unavailableScope:
            return I18N.localized("此入口只恢复因系统账号变化而暂停的原账号同步，请先核对恢复资料。", englishFallback: "This action only resumes the original account paused by a system account change. Review recovery data first.")
        case ICloudSameAccountResumeError.cloudNeedsReview:
            return I18N.localized("原云库的控制信息或资料区无法核实，同步保持暂停。", englishFallback: "The original cloud library’s control metadata or zones could not be verified. Sync remains paused.")
        case ICloudSameAccountResumeError.operationInProgress:
            return I18N.localized("账号恢复或资料复制仍在处理，请稍后再试。", englishFallback: "Account recovery or a data copy is still running. Try again shortly.")
        case ICloudSameAccountResumeError.safetyLimit:
            return I18N.localized("账号恢复核验达到安全限制，同步保持暂停，请稍后重新核验。", englishFallback: "Account recovery verification reached its safety limit. Sync remains paused. Verify again later.")
        case ICloudLocalCopyError.invalidSelection:
            return I18N.localized("选中的本地资料不可用，请重新选择。", englishFallback: "The selected local data is unavailable. Choose it again.")
        case ICloudLocalCopyError.unavailableTarget:
            return I18N.localized("目标 iCloud 账号尚未完成恢复或已停用，请先完成同步。", englishFallback: "The target iCloud account is disabled or has not finished recovery. Finish syncing first.")
        case ICloudLocalCopyError.targetRequiresReview:
            return I18N.localized("目标 iCloud 资料需要复核，暂不能复制。", englishFallback: "The target iCloud data needs review before copying.")
        case ICloudLocalCopyError.stalePlan:
            return I18N.localized("资料或账号已变化，或预览已过期，请重新选择并预览。", englishFallback: "The data or account changed, or the preview expired. Choose the data and preview again.")
        case ICloudLocalCopyError.scanLimitExceeded:
            return I18N.localized("选择的资料过多，请缩小范围后重新预览。", englishFallback: "Too much data was selected. Choose a smaller range and preview again.")
        case ICloudLocalCopyError.copyInProgress:
            return I18N.localized("资料复制操作仍在处理，请稍后再试。", englishFallback: "A data copy operation is still running. Try again shortly.")
        case ICloudLocalCopyError.reviewRequired:
            return I18N.localized("请先审阅选中的资料及隐私范围。", englishFallback: "Review the selected data and its privacy scope first.")
        case ICloudMigrationPreviewError.unavailableSource:
            return I18N.localized("本地资料预览暂不可用，请检查本地账号。", englishFallback: "Local data preview is unavailable. Check the local account.")
        case ICloudEngineError.notEntitled:
            return I18N.localized("此版本无法连接 iCloud，本机资料仍可离线阅读。", englishFallback: "This version cannot connect to iCloud. Your data is still available offline.")
        case ICloudEngineError.noSystemAccount:
            return I18N.localized("请先在系统设置中登录 iCloud。", englishFallback: "Sign in to iCloud in System Settings.")
        case ICloudEngineError.restricted:
            return I18N.localized("系统限制了 iCloud 访问，请检查系统设置。", englishFallback: "iCloud access is restricted. Check System Settings.")
        case ICloudEngineError.temporarilyUnavailable:
            return I18N.localized("iCloud 账号暂不可用，稍后会重试；本地更改已保留。", englishFallback: "Your iCloud account is temporarily unavailable. Sync will retry; your local changes are retained.")
        case ICloudBootstrapRetryError.deferred:
            return I18N.localized("iCloud 暂时繁忙，稍后会重试；本地更改已保留。", englishFallback: "iCloud is busy. Sync will retry; your local changes are retained.")
        case ICloudRecordError.accountChanged, ICloudRecordError.recoveryRequired:
            return I18N.localized("iCloud 同步已暂停，请确认账号或云端资料恢复方式。", englishFallback: "iCloud sync is paused. Review the account or recovery options.")
        case is ICloudCloudResetError:
            return message(for: ICloudRecordError.recoveryRequired)
        case ICloudRootError.generationChanged:
            return I18N.localized("云端资料已经重置，同步已暂停。请确认恢复方式，本机更改已保留。", englishFallback: "The cloud library has been reset. Sync is paused. Review recovery options; your local changes are retained.")
        case ICloudRootError.rootMissing:
            return I18N.localized("云端恢复信息缺失，同步已暂停，本机资料已保留。", englishFallback: "Cloud recovery information is missing. Sync is paused and your local data is retained.")
        case ICloudRootError.resetInProgress:
            return I18N.localized("云端资料正在重置，同步已暂停，本机资料已保留。", englishFallback: "The cloud library is being reset. Sync is paused and your local data is retained.")
        case ICloudRootError.legacyCloudRequiresReview:
            return I18N.localized("已有资料需要确认兼容方式。本机资料已保留，暂不继续上传。", englishFallback: "Existing data needs a compatibility review. Your local data is retained and uploads are paused.")
        case ICloudRootError.malformedRoot, ICloudRootError.unsupportedVersion:
            return I18N.localized("云端资料格式暂不兼容，同步已暂停，本机资料已保留。", englishFallback: "The cloud data format is incompatible. Sync is paused and your local data is retained.")
        case is CancellationError:
            return I18N.localized("iCloud 同步已取消。", englishFallback: "iCloud sync was cancelled.")
        case let cloud as CKError:
            switch cloud.code {
            case .quotaExceeded:
                return I18N.localized("iCloud 存储空间不足，请释放空间后再同步。", englishFallback: "iCloud storage is full. Free up space and sync again.")
            case .requestRateLimited, .serviceUnavailable, .zoneBusy:
                return I18N.localized("iCloud 暂时繁忙，稍后会重试；本地更改已保留。", englishFallback: "iCloud is busy. Sync will retry; your local changes are retained.")
            case .permissionFailure, .missingEntitlement, .badContainer, .badDatabase:
                return I18N.localized("iCloud 连接配置不可用，本机资料已保留。", englishFallback: "The iCloud connection configuration is unavailable. Your local data is retained.")
            case .notAuthenticated:
                return I18N.localized("请先在系统设置中登录 iCloud。", englishFallback: "Sign in to iCloud in System Settings.")
            case .accountTemporarilyUnavailable:
                return message(for: ICloudEngineError.temporarilyUnavailable)
            default:
                return I18N.localized("iCloud 同步暂未完成，本地更改已保留。", englishFallback: "iCloud sync could not finish. Your local changes are retained.")
            }
        default:
            return I18N.localized("iCloud 同步暂未完成，本地更改已保留。", englishFallback: "iCloud sync could not finish. Your local changes are retained.")
        }
    }
}

enum ICloudAccountError: LocalizedError, Sendable {
    case alreadyExists
    var errorDescription: String? {
        I18N.localized("已有 iCloud 账号。", englishFallback: "An iCloud account already exists.")
    }
}
