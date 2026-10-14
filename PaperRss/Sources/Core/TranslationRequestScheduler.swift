import Foundation

/// One model budget shared by body, title and selection translation. A job's
/// concurrency limit alone cannot enforce RPM/RPS, especially across articles.
actor TranslationRequestScheduler {
    private struct Waiter {
        let id: UUID
        let interval: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Budget {
        var waiting: [Waiter] = []
        var active = 0
        var nextStart: ContinuousClock.Instant = .now
        var adaptiveInterval: Duration = .zero
        var consecutiveRateLimits = 0
        var recoverySuccesses = 0
        var blockedUntil: ContinuousClock.Instant?
        var blockedError: LLMServiceError = .rateLimited
        var timer: Task<Void, Never>?
    }
    private var budgets: [String: Budget] = [:]
    private let baseRetryDelay: Duration
    private let failureCooldown: Duration
    private let maximumRateLimitAttempts = 3

    init(baseRetryDelay: Duration = .seconds(5), failureCooldown: Duration = .seconds(60)) {
        self.baseRetryDelay = baseRetryDelay
        self.failureCooldown = failureCooldown
    }

    func run<T: Sendable>(
        key: String,
        minimumInterval: Duration,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        for attempt in 0..<maximumRateLimitAttempts {
            try await acquire(key: key, interval: minimumInterval)
            do {
                try Task.checkCancellation()
                let result = try await operation()
                release(key: key, error: nil)
                return result
            } catch {
                release(key: key, error: error)
                guard !Task.isCancelled, Self.retryDelay(for: error) != nil,
                      attempt + 1 < maximumRateLimitAttempts else { throw error }
            }
        }
        throw LLMServiceError.rateLimited
    }

    private func acquire(key: String, interval: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                var budget = budgets[key] ?? Budget()
                budget.waiting.append(Waiter(id: id, interval: interval, continuation: continuation))
                budgets[key] = budget
                drain(key: key)
            }
        } onCancel: {
            Task { await self.cancel(id: id, key: key) }
        }
    }

    private func cancel(id: UUID, key: String) {
        guard var budget = budgets[key], let index = budget.waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = budget.waiting.remove(at: index)
        budgets[key] = budget
        waiter.continuation.resume(throwing: CancellationError())
        drain(key: key)
    }

    private func drain(key: String) {
        guard var budget = budgets[key] else { return }
        budget.timer?.cancel()
        budget.timer = nil
        let now = ContinuousClock.now
        if let blockedUntil = budget.blockedUntil {
            if now < blockedUntil {
                let waiting = budget.waiting
                budget.waiting.removeAll()
                budgets[key] = budget
                waiting.forEach { $0.continuation.resume(throwing: budget.blockedError) }
                return
            }
            budget.blockedUntil = nil
            budget.consecutiveRateLimits = 0
        }
        guard let first = budget.waiting.first, budget.active < 2 else {
            budgets[key] = budget
            return
        }
        if now < budget.nextStart {
            let deadline = budget.nextStart
            budget.timer = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                self.drain(key: key)
            }
            budgets[key] = budget
            return
        }
        budget.waiting.removeFirst()
        budget.active += 1
        budget.nextStart = now.advanced(by: max(first.interval, budget.adaptiveInterval))
        budgets[key] = budget
        first.continuation.resume()
        // Healthy generic models may start immediately within the concurrency cap.
        if !budget.waiting.isEmpty { drain(key: key) }
    }

    private func release(key: String, error: Error?) {
        guard var budget = budgets[key] else { return }
        budget.active -= 1
        if let error, let retryAfter = Self.retryDelay(for: error) {
            budget.consecutiveRateLimits += 1
            budget.recoverySuccesses = 0
            let factor = Double(1 << min(budget.consecutiveRateLimits - 1, 5))
            let pause = max(retryAfter, baseRetryDelay * factor)
            budget.nextStart = max(budget.nextStart, ContinuousClock.now.advanced(by: pause))
            budget.adaptiveInterval = max(budget.adaptiveInterval, baseRetryDelay / 5 * factor)
            if budget.consecutiveRateLimits >= maximumRateLimitAttempts {
                budget.blockedUntil = max(budget.nextStart, ContinuousClock.now.advanced(by: failureCooldown))
                budget.blockedError = .rateLimited
            }
        } else if let serviceError = error as? LLMServiceError, case .quotaExceeded = serviceError {
            budget.blockedUntil = ContinuousClock.now.advanced(by: failureCooldown)
            budget.blockedError = .quotaExceeded
        } else if error == nil {
            budget.consecutiveRateLimits = 0
            // Recovery is bounded: a temporary 429 must not permanently slow
            // later articles. Keep nextStart intact to honor an outstanding pause.
            budget.recoverySuccesses += 1
            if budget.recoverySuccesses >= 2 {
                budget.adaptiveInterval = .zero
            }
        }
        budgets[key] = budget
        drain(key: key)
    }

    private static func retryDelay(for error: Error) -> Duration? {
        guard let error = error as? LLMServiceError else { return nil }
        switch error {
        case .rateLimited: return .zero
        case let .rateLimitedWithRetryAfter(seconds): return .seconds(seconds)
        default: return nil
        }
    }
}
