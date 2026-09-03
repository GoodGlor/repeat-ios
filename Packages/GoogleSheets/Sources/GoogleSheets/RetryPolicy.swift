import Foundation

/// Waiting, injected so tests do not have to.
public protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

/// §4.6: exponential backoff on quota and 5xx — 1, 2, 4, 8 minutes, at most five
/// tries, then give up and wait for the next trigger (§4.2).
public struct RetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int
    public let delays: [TimeInterval]

    public init(
        maximumAttempts: Int = 5,
        delays: [TimeInterval] = [60, 120, 240, 480]
    ) {
        self.maximumAttempts = maximumAttempts
        self.delays = delays
    }

    /// Delay before attempt number `attempt` (1-based). The last delay repeats if
    /// the schedule is shorter than the attempt count.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let index = min(attempt - 2, delays.count - 1)
        return delays[max(0, index)]
    }

    /// Retried: quota exhaustion and Google's own faults. Not retried: anything
    /// that will fail identically next time — a wrong id, a sheet that is not
    /// shared, a revoked key. Retrying those wastes the window and hides the
    /// real problem behind five minutes of silence.
    public static func isRetriable(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }
}
