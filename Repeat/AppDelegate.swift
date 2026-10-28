import UIKit
import UserNotifications

/// Exists for one line. The notification centre's delegate has to be set before
/// launch finishes, or a tap that cold-starts the app is delivered to nobody —
/// and a SwiftUI `App` has no hook that early.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }
}
