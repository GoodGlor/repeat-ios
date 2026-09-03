import SwiftUI

/// Light, dark, or whatever the phone is set to (#87).
///
/// ## Why this is `@AppStorage` and not `AppSettings`
///
/// Every other preference lives in `AppSettings`, so this one looking different
/// deserves an explanation. `AppSettings` is constructed per view — `HomeView`,
/// `SettingsView` and `RepeatApp` each hold their own instance over the same
/// `UserDefaults`. That is harmless for a value read once when a screen opens, and
/// wrong for this one: the card asks for the override to "apply immediately,
/// without restarting", and one `@Observable` instance changing does not notify a
/// different instance of the same class. The setting would have taken effect on
/// the next launch — which is precisely the acceptance criterion it would fail.
///
/// `@AppStorage` observes the defaults themselves, so the picker in Settings and
/// the root that applies the scheme are looking at one value rather than two
/// copies of it.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The key both the picker and the root bind to. One string, one source.
    static let storageKey = "settings.appearance"

    /// `nil` hands the decision back to the system, which is the default and the
    /// only value that keeps following the phone after it is set.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: Localized.string("Система")
        case .light: Localized.string("Світла")
        case .dark: Localized.string("Темна")
        }
    }

    /// Falls back to `.system` for an unreadable value rather than to a fixed
    /// scheme: a defaults file written by a future version should leave the app
    /// following the phone, not pinned to a guess.
    static func stored(in defaults: UserDefaults = .standard) -> Appearance {
        guard let raw = defaults.string(forKey: storageKey) else { return .system }
        return Appearance(rawValue: raw) ?? .system
    }
}
