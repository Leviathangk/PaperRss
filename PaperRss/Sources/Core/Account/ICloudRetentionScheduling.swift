@preconcurrency import CloudKit
import Foundation

struct ICloudRetentionScheduleState: Codable, Sendable, Equatable {
    let enabled: Bool
    let deadline: Date?
    let minimumWait: TimeInterval?
    let attempt: Int
    let revision: Int64

    /// A cold process conservatively waits the original delay again. Moving
    /// the device clock forward, restarting or reopening settings cannot skip
    /// server retryAfter. The live sleep itself uses a monotonic Duration.
    func coldWait(now: Date) throws -> TimeInterval? {
        guard now.timeIntervalSince1970.isFinite else { throw ICloudRetentionJobError.invalidJob }
        guard let deadline, let minimumWait else {
            guard deadline == nil && minimumWait == nil else { throw ICloudRetentionJobError.invalidJob }
            return nil
        }
        let remaining = max(minimumWait, deadline.timeIntervalSince(now))
        guard remaining.isFinite else { throw ICloudRetentionJobError.invalidJob }
        return min(remaining, ICloudBootstrapRetryPolicy.maximumDelay)
    }
}

enum ICloudRetentionSchedulingPolicy {
    static let interval: TimeInterval = 60
    static func delay(for error: any Error, attempt: Int) -> TimeInterval? {
        delay(for: error, attempt: attempt, depth: 0)
    }
    private static func delay(for error: any Error, attempt: Int, depth: Int) -> TimeInterval? {
        guard depth < 4 else { return nil }
        if let reset = error as? ICloudCloudResetError, reset == .operationInProgress { return interval }
        if let error = error as? ICloudRetentionError {
            switch error {
            case .budgetExceeded: return 24 * 60 * 60 // Refresh server evidence next day; never locally renew quota.
            case .unresolvedChanges: return 60 * 60
            default: return nil
            }
        }
        if let cloud = error as? CKError {
            if cloud.code == .serverRecordChanged || cloud.code == .batchRequestFailed {
                return interval // Refetch a new point proof; no reuse of a failed SDK batch.
            }
            if cloud.code == .partialFailure {
                guard let failures = cloud.partialErrorsByItemID, !failures.isEmpty else { return nil }
                var wait = interval
                for failure in failures.values {
                    guard let next = delay(for: failure, attempt: attempt, depth: depth + 1) else { return nil }
                    wait = max(wait, next)
                }
                return wait
            }
        }
        return ICloudBootstrapRetryPolicy.delay(for: error, attempt: attempt).map { max(interval, $0) }
    }
}

enum ICloudRetentionSchedulingEvent: Sendable {
    case progressed(ICloudRetentionJob), waiting(TimeInterval), finished(ICloudRetentionJob)
    case failed(any Error)
}

/// Only a separately approved concrete job can enable this timer. Provider
/// restart can resume an enabled approved job;
/// construction, account activation and product-rule acceptance stay inert.
actor ICloudRetentionScheduler {
    private let repository: ICloudRecordRepository
    private let coordinator: ICloudRetentionCoordinator
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var running: (id: UUID, approvalID: String, task: Task<Void, Never>)?
    private var lifecycle = 0

    init(repository: ICloudRecordRepository, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.repository = repository; coordinator = .init(repository: repository)
        self.now = now; self.sleep = sleep
    }

    func start(approvalID: String, using transport: any ICloudRetentionExecutionTransport,
               isCurrent: @escaping @Sendable () async throws -> Bool = { true },
               onEvent: @escaping @Sendable (ICloudRetentionSchedulingEvent) async -> Void = { _ in }) async throws {
        if let running {
            guard running.approvalID == approvalID else { throw ICloudRetentionJobError.jobChanged }
            return // A foreground request never replaces the live retry wait.
        }
        _ = try await repository.setRetentionScheduleEnabled(true, approvalID: approvalID)
        launch(approvalID: approvalID, transport: transport, isCurrent: isCurrent, onEvent: onEvent)
    }

    func resumeIfEnabled(approvalID: String, using transport: any ICloudRetentionExecutionTransport,
                         isCurrent: @escaping @Sendable () async throws -> Bool = { true },
                         onEvent: @escaping @Sendable (ICloudRetentionSchedulingEvent) async -> Void = { _ in }) async throws {
        guard running == nil, try await repository.retentionScheduleState(approvalID: approvalID).enabled else { return }
        launch(approvalID: approvalID, transport: transport, isCurrent: isCurrent, onEvent: onEvent)
    }

    func stop(approvalID: String) async throws {
        if let running, running.approvalID != approvalID { throw ICloudRetentionJobError.approvalMismatch }
        _ = try await repository.retentionScheduleState(approvalID: approvalID)
        lifecycle &+= 1
        running?.task.cancel()
        // Keep the running handle until an awaited SDK request returns; a new
        // start cannot replace it or claim cancellation drained the cloud.
        await coordinator.stop()
        _ = try await repository.setRetentionScheduleEnabled(false, approvalID: approvalID)
    }

    /// Account/app suspension cancels execution, retaining the user's durable
    /// finite approval and retry wait for a later verified same-scope resume.
    func suspend(waitForRequests: Bool = false) async {
        lifecycle &+= 1
        let task = running?.task
        task?.cancel()
        await coordinator.stop()
        if waitForRequests { await task?.value }
    }

    private func launch(approvalID: String, transport: any ICloudRetentionExecutionTransport,
                        isCurrent: @escaping @Sendable () async throws -> Bool,
                        onEvent: @escaping @Sendable (ICloudRetentionSchedulingEvent) async -> Void) {
        let id = UUID(), epoch = lifecycle
        let task = Task(priority: .background) {
            await self.run(approvalID: approvalID, transport: transport, epoch: epoch, isCurrent: isCurrent, onEvent: onEvent)
            self.finished(id: id)
        }
        running = (id, approvalID, task)
    }
    private func finished(id: UUID) { if running?.id == id { running = nil } }

    private func check(approvalID: String, epoch: Int, isCurrent: @Sendable () async throws -> Bool) async throws {
        try Task.checkCancellation()
        guard epoch == lifecycle, try await isCurrent(),
              try await repository.retentionScheduleState(approvalID: approvalID).enabled else { throw CancellationError() }
        try Task.checkCancellation()
        guard epoch == lifecycle else { throw CancellationError() }
    }

    private func run(approvalID: String, transport: any ICloudRetentionExecutionTransport, epoch: Int,
                     isCurrent: @escaping @Sendable () async throws -> Bool,
                     onEvent: @Sendable (ICloudRetentionSchedulingEvent) async -> Void) async {
        do {
            while true {
                try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                let state = try await repository.retentionScheduleState(approvalID: approvalID)
                if let wait = try state.coldWait(now: now()) {
                    await onEvent(.waiting(wait))
                    try await sleep(.seconds(wait))
                    try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    try await repository.clearRetentionWake(approvalID: approvalID, expectedRevision: state.revision)
                }
                try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                let job: ICloudRetentionJob
                do {
                    job = try await coordinator.executeNext(approvalID: approvalID, using: transport, isCurrent: {
                        try await self.check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                        return true
                    })
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                    let deadline = try await repository.scheduleRetentionWake(approvalID: approvalID, for: error, now: now())
                    if deadline != nil { continue }
                    throw error
                }
                try await check(approvalID: approvalID, epoch: epoch, isCurrent: isCurrent)
                if job.isFinished {
                    _ = try await repository.setRetentionScheduleEnabled(false, approvalID: approvalID)
                    await onEvent(.finished(job)); return
                }
                await onEvent(.progressed(job))
                _ = try await repository.scheduleRetentionWake(approvalID: approvalID, for: nil, now: now())
            }
        } catch is CancellationError { }
        catch {
            _ = try? await repository.setRetentionScheduleEnabled(false, approvalID: approvalID)
            await onEvent(.failed(error))
        }
    }
}
