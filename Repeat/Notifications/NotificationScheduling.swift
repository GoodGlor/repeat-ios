import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` §7.2 needs.
///
/// Behind a protocol because the interesting behaviour — never scheduling a
/// notification that would be false, and replacing rather than stacking — cannot
/// be asserted against the real notification centre in a unit test.
///
/// The requirements are `nonisolated(nonsending)`: a call stays on the caller's
/// actor rather than hopping to the cooperative pool. Nothing here needs a
/// background thread — the centre's own calls are already async — and it lets a
/// test's scheduler observe which executor `DailyReminder.refresh` runs on, which
/// is how the 2026-09-04 crash is pinned.
protocol NotificationScheduling: Sendable {
    nonisolated(nonsending) func pendingRequests() async -> [UNNotificationRequest]
    nonisolated(nonsending) func removePending(identifiers: [String]) async
    nonisolated(nonsending) func add(_ request: UNNotificationRequest) async throws
    /// Whether notifications may be shown at all.
    nonisolated(nonsending) func requestAuthorization() async -> Bool
}

struct SystemNotificationScheduler: NotificationScheduling {
    private var centre: UNUserNotificationCenter { .current() }

    func pendingRequests() async -> [UNNotificationRequest] {
        await centre.pendingNotificationRequests()
    }

    func removePending(identifiers: [String]) async {
        centre.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await centre.add(request)
    }

    func requestAuthorization() async -> Bool {
        // `.provisional` is deliberate: a daily study reminder is exactly the
        // quiet, opt-out kind this exists for, and asking for full permission on
        // first launch — before anyone has studied anything — is the surest way
        // to be refused permanently.
        let options: UNAuthorizationOptions = [.alert, .sound, .badge, .provisional]
        return (try? await centre.requestAuthorization(options: options)) ?? false
    }
}
