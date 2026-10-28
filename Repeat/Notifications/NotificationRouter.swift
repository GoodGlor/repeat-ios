import Foundation
import UserNotifications

/// Turns a tap on one of our notifications into a route (§7.1, #109).
///
/// Until this existed the reminder carried `userInfo["url"]` that nothing read:
/// tapping it opened the app wherever it last was. The route is left in
/// `PendingRoute` — the same channel an App Intent uses — and announced, so a
/// `RootTabView` that is already on screen picks it up at once, and one that is
/// still launching finds it in its `.task`.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let userInfoKey = "url"
    /// Posted after a route is left behind.
    static let routeRequested = Notification.Name("com.goodglor.repeat.route-requested")

    /// The destination a payload names, if any. Pure, so it is testable.
    static func destination(from userInfo: [AnyHashable: Any]) -> DeepLink.Destination? {
        guard let string = userInfo[userInfoKey] as? String,
              let url = URL(string: string) else { return nil }
        return DeepLink.destination(for: url)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = Self.destination(from: response.notification.request.content.userInfo)
        else { return }
        await deliver(destination)
    }

    /// Leaves the route and announces it — **on the main actor**, and that is the
    /// whole of #141.
    ///
    /// This body used to sit inline above. A method satisfying an `@objc` protocol
    /// requirement is *nonisolated*, so `async` there means the cooperative pool:
    /// the post landed on a background thread, `RootTabView.onReceive` delivers on
    /// whichever thread posted, SwiftUI updated from it, and UIKit's snapshot and
    /// state-restoration machinery asserted and aborted. Tapping the reminder
    /// killed the app before it drew anything — which from outside looked exactly
    /// like the tap doing nothing.
    ///
    /// Gotcha 39, reintroduced: the 2026-09-04 sweep fixed seven functions of this
    /// shape, and #109 wrote this file three days later, outside it.
    ///
    /// **`nonisolated(nonsending)` would not fix this.** That keeps the body on the
    /// *caller's* actor, and the caller is `UNUserNotificationCenter`'s own queue,
    /// not the main one. The hop has to be explicit.
    ///
    /// Callable, unlike the delegate method above: `UNNotificationResponse` cannot
    /// be constructed, so this is the only place the isolation can be observed.
    @MainActor
    func deliver(_ destination: DeepLink.Destination) {
        PendingRoute.request(destination)
        NotificationCenter.default.post(name: Self.routeRequested, object: nil)
    }
}
