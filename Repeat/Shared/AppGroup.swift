import Foundation

/// The App Group shared by the app, the widget and the Share Extension.
///
/// The Share Extension writes quick-captured items here (spec §7.3) and the
/// widget reads the due count from here (spec §7.1); neither can reach the
/// app's own container. This file is compiled into all three targets.
public enum AppGroup {
    public static let identifier = "group.com.goodglor.repeat"

    /// Shared container URL, or `nil` when the App Group entitlement is missing
    /// — which is what happens on a free Apple Developer account.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the Share Extension drops captured items for the app to ingest.
    public static var inboxURL: URL? {
        containerURL?.appendingPathComponent("inbox", isDirectory: true)
    }

    /// Where the app publishes the due count for the widget to read.
    public static var dueCountURL: URL? {
        containerURL?.appendingPathComponent("due-count.json", isDirectory: false)
    }

    /// Creates the shared directories. Safe to call repeatedly.
    @discardableResult
    public static func prepare() -> Bool {
        guard let inboxURL else { return false }
        do {
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
