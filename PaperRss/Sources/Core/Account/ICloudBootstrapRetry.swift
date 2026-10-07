@preconcurrency import CloudKit
import Foundation

enum ICloudBootstrapRetryError: Error, Sendable {
    case deferred
}

enum ICloudBootstrapRetryPolicy {
    static let maximumDelay: TimeInterval = 100 * 365 * 24 * 60 * 60
    static func delay(for error: any Error, attempt: Int) -> TimeInterval? {
        delay(for: error, attempt: attempt, depth: 0)
    }

    private static func delay(for error: any Error, attempt: Int, depth: Int) -> TimeInterval? {
        guard depth < 4 else { return nil }
        if error is ICloudBootstrapRetryError { return 2 }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .partialFailure:
                guard let failures = cloud.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error],
                      !failures.isEmpty else { return nil }
                var wait: TimeInterval = 0
                for failure in failures.values {
                    guard let next = delay(for: failure, attempt: attempt, depth: depth + 1) else { return nil }
                    wait = max(wait, next)
                }
                return wait
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
                 .zoneBusy, .accountTemporarilyUnavailable:
                if let seconds = cloud.retryAfterSeconds, seconds.isFinite, seconds > 0 {
                    // A century exceeds a process lifetime and also avoids
                    // overflowing the monotonic clock on malformed SDK input.
                    return min(seconds, maximumDelay)
                }
                return min(60, 2 * pow(2, Double(min(5, max(0, attempt - 1)))))
            default: return nil
            }
        }
        if let account = error as? ICloudEngineError, account == .temporarilyUnavailable { return 30 }
        return nil
    }
}

struct ICloudBootstrapRetryState: Sendable {
    let deadline: Date?
    let attempt: Int
    let revision: Int64
}
