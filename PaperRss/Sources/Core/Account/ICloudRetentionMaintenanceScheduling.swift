import Foundation

private struct ICloudRetentionMaintenanceSource: ICloudInventoryPageFetching {
    let source: any ICloudInventoryPageFetching
    let check: @Sendable () async throws -> Void
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        try await check()
        let page = try await source.inventoryPage(zone: zone, cursor: cursor, limit: limit)
        try await check(); return page
    }
}

/// Discovers future targets only under explicit same-generation consent, then
/// hands off a persisted finite child to the existing conditional executor.
/// The task handle is retained until a cancelled query actually returns.
actor ICloudRetentionMaintenanceScheduler {
    private let repository: ICloudRecordRepository
    private let source: any ICloudInventoryPageFetching
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var resumption: (id: UUID, task: Task<Void, Never>)?
    private var lifecycle = 0
    private var scanner: ICloudRetentionDiscoveryScanner?
    private var binding: ICloudRetentionDiscoveryBinding?

    init(repository: ICloudRecordRepository, source: any ICloudInventoryPageFetching,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.repository = repository; self.source = source; self.now = now; self.sleep = sleep
    }

    func resumeIfEnabled(isCurrent: @escaping @Sendable () async throws -> Bool,
                         launchJob: @escaping @Sendable (ICloudRetentionJob) async throws -> Void,
                         onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }) async throws {
        if let running {
            // A live wait stays untouched. A newly enabled policy may queue
            // one resume behind a cancelled SDK query, without replacing it.
            guard running.task.isCancelled, resumption == nil else { return }
            let id = UUID(), epoch = lifecycle
            let task = Task {
                await running.task.value
                guard self.resumption?.id == id else { return }
                self.resumption = nil
                guard epoch == self.lifecycle, !Task.isCancelled else { return }
                do {
                    try await self.resumeIfEnabled(isCurrent: isCurrent, launchJob: launchJob, onFailure: onFailure)
                } catch {
                    if epoch == self.lifecycle, !Task.isCancelled { await onFailure(error) }
                }
            }
            resumption = (id, task)
            return
        }
        let context = try await repository.retentionMaintenanceContext()
        guard let state = context.state, state.schedule.enabled else { return }
        try Task.checkCancellation()
        guard try await isCurrent(), running == nil else { return }
        let id = UUID(), epoch = lifecycle, approvalID = state.approval.approvalID
        let task = Task(priority: .background) {
            await self.run(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent,
                           launchJob: launchJob, onFailure: onFailure)
            if self.running?.id == id { self.running = nil }
        }
        running = (id, task)
    }

    func suspend(waitForRequests: Bool = false) async {
        lifecycle &+= 1
        resumption?.task.cancel(); resumption = nil
        let task = running?.task
        task?.cancel()
        await scanner?.cancel()
        scanner = nil; binding = nil
        if waitForRequests { await task?.value }
    }

    private func check(approvalID: String, epoch: Int,
                       isCurrent: @Sendable () async throws -> Bool) async throws -> ICloudRetentionMaintenanceContext {
        try Task.checkCancellation()
        guard epoch == lifecycle, try await isCurrent() else { throw CancellationError() }
        let context = try await repository.retentionMaintenanceContext()
        try Task.checkCancellation()
        guard epoch == lifecycle, let state = context.state, state.schedule.enabled,
              state.approval.approvalID == approvalID else { throw ICloudRetentionMaintenanceError.disabled }
        return context
    }

    private func run(approvalID: String, epoch: Int, isCurrent: @escaping @Sendable () async throws -> Bool,
                     launchJob: @Sendable (ICloudRetentionJob) async throws -> Void,
                     onFailure: @Sendable (any Error) async -> Void) async {
        do {
            while true {
                let context = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                let state = context.state!
                if let job = context.scope.job {
                    if job.attempts.contains(where: { $0.stage == .needsReview }) {
                        throw ICloudRetentionJobError.needsReview // Preserve all original evidence.
                    }
                    let schedule = try await repository.retentionScheduleState(approvalID: job.approval.approvalID)
                    if !job.isFinished {
                        guard job.approval.maintenanceApprovalID == approvalID, schedule.enabled else {
                            throw ICloudRetentionMaintenanceError.existingJob
                        }
                        _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                        try await launchJob(job)
                        _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                        try await sleep(.seconds(ICloudRetentionSchedulingPolicy.interval))
                        continue
                    }
                    if schedule.enabled {
                        // Let the child's terminal callback drain before CAS replacement.
                        try await sleep(.seconds(ICloudRetentionSchedulingPolicy.interval)); continue
                    }
                }
                if let wait = try state.schedule.coldWait(now: now()) {
                    try await sleep(.seconds(wait))
                    _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    try await repository.clearMaintenanceWake(approvalID: approvalID, expectedRevision: state.schedule.revision)
                    continue
                }
                do {
                    let nextBinding = ICloudRetentionDiscoveryBinding(context.scope)
                    if scanner == nil || binding != nextBinding {
                        await scanner?.cancel()
                        let guarded = ICloudRetentionMaintenanceSource(source: source, check: { [weak self] in
                            guard let self else { throw CancellationError() }
                            _ = try await self.check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                        })
                        scanner = ICloudRetentionDiscoveryScanner(source: guarded); binding = nextBinding
                    }
                    let protection = try await repository.maintenanceProtection()
                    _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    let names = try await scanner!.scan(protection: protection, now: now())
                    let latest = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    guard latest.scope.job == context.scope.job else { throw ICloudRetentionJobError.jobChanged }
                    _ = try await repository.scheduleMaintenanceWake(approvalID: approvalID, for: nil, now: now())
                    if names.isEmpty { continue }
                    let child = try state.approval.childApproval(names: names)
                    let job = try await repository.beginRetentionJob(child, replacingCompletedApprovalID: context.scope.job?.approval.approvalID)
                    _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    _ = try await repository.setRetentionScheduleEnabled(true, approvalID: job.approval.approvalID)
                    _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    try await launchJob(job)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    _ = try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    _ = try await repository.scheduleMaintenanceWake(approvalID: approvalID, for: error, now: now())
                }
            }
        } catch is CancellationError { }
        catch {
            if epoch == lifecycle { await onFailure(error) }
        }
    }
}
