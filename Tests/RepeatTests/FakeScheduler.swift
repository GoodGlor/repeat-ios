import Foundation
import UserNotifications
@testable import Repeat

/// Records what would have been scheduled. Shared by the reminder and the
/// achievement suites.
final class FakeScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [UNNotificationRequest] = []
    private(set) var removals: [[String]] = []
    /// Every accepted `add` call, even one that replaced another by identifier.
    /// `pendingRequests().count` cannot tell "posted once" from "posted twice,
    /// the second replacing the first" — replacement is exactly what the real
    /// centre does — so a test proving a single delivery attempt asserts here.
    private(set) var addCount = 0
    /// When set, `add` throws it — the centre refusing a request.
    var addError: Error?

    /// A refusal, named. `URLError(.cancelled)` was standing in for one, which
    /// reads like a network failure in a file that has nothing to do with the
    /// network.
    enum Failure: Error { case refused }

    func pendingRequests() async -> [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func removePending(identifiers: [String]) async {
        lock.lock(); defer { lock.unlock() }
        removals.append(identifiers)
        requests.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.lock(); defer { lock.unlock() }
        if let addError { throw addError }
        addCount += 1
        // Mirrors UNUserNotificationCenter: same identifier replaces.
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }

    func requestAuthorization() async -> Bool { true }
}

/// Records which thread each call arrived on. `nonisolated(nonsending)` keeps
/// these methods on the **caller's** executor, so what they record is the
/// executor of the function under test rather than a hop of their own. This is
/// how the 2026-09-04 pull-to-refresh crash is pinned.
///
/// `DailyReminderTests` predates this and keeps its own private copy; leave it
/// alone, so that suite stays a witness that #27 was not modified.
final class ThreadProbeScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var onMainThread: [Bool] = []

    private func record() {
        lock.lock(); defer { lock.unlock() }
        onMainThread.append(pthread_main_np() != 0)
    }

    nonisolated(nonsending) func pendingRequests() async -> [UNNotificationRequest] { record(); return [] }
    nonisolated(nonsending) func removePending(identifiers: [String]) async { record() }
    nonisolated(nonsending) func add(_ request: UNNotificationRequest) async throws { record() }
    nonisolated(nonsending) func requestAuthorization() async -> Bool { record(); return true }
}
