import Foundation

/// Where an intent asked the app to land (§7.4).
///
/// `StartReviewIntent` runs before the UI exists — Shortcuts launches the app to
/// perform it — so it cannot set a tab directly. It leaves a destination here and
/// `RootTabView` picks it up when it appears.
///
/// Deliberately the *same* vocabulary as `DeepLink.Destination` rather than a
/// second one. A widget tap and an Action-button press should reach the same
/// screen by the same code, or they will drift apart the first time one of them
/// changes.
enum PendingRoute {
    static let key = "route.pending"

    /// The App Group suite, so a route survives being written by an extension
    /// later. Falls back to `.standard` when the entitlement is missing, which is
    /// what a free developer account gets.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    static func request(_ destination: DeepLink.Destination, defaults: UserDefaults = sharedDefaults) {
        defaults.set(token(for: destination), forKey: key)
    }

    /// Reads and clears in one step. A route that is read twice would send the
    /// person back to the same screen the next time they open the app, which
    /// looks like the app ignoring them.
    static func consume(defaults: UserDefaults = sharedDefaults) -> DeepLink.Destination? {
        guard let token = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return destination(for: token)
    }

    private static func token(for destination: DeepLink.Destination) -> String {
        switch destination {
        case .study: return "study"
        case .add: return "add"
        case .stats: return "stats"
        }
    }

    private static func destination(for token: String) -> DeepLink.Destination? {
        switch token {
        case "study": return .study
        case "add": return .add
        case "stats": return .stats
        default: return nil
        }
    }
}
