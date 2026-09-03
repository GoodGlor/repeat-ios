import Foundation

/// First-launch state (§6.1).
///
/// The decisions live here rather than in the view because two of them are worth
/// being sure about: onboarding must appear exactly once, and skipping it must
/// still reach the setup sheet — a fresh install that never connects a
/// spreadsheet is an app with nothing in it.
enum Onboarding {
    static let completedKey = "onboarding.completed"

    /// Where the flow is.
    ///
    /// `setup` is a step of the flow, not a consequence of finishing it: page 3's
    /// button and the Skip button both land here. Skipping is a statement about
    /// the explanation, not about wanting an empty app.
    enum Step: Equatable {
        case pages(index: Int)
        case setup
        case finished
    }

    static let pageCount = 3

    static func hasCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// Replays the flow from Settings (§6.1, §6.6).
    static func replay(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: completedKey)
    }

    /// Whether to present anything at launch.
    ///
    /// Only the never-completed case. Someone who ran the flow and chose not to
    /// connect a spreadsheet is not asked again on every launch — Home's "Потребує
    /// уваги" section already says the connection is missing and links to
    /// Settings, and a modal that cannot be escaped permanently is worse than a
    /// row that can be ignored.
    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !hasCompleted(defaults: defaults)
    }

    static func next(after step: Step) -> Step {
        switch step {
        case .pages(let index) where index + 1 < pageCount: .pages(index: index + 1)
        case .pages: .setup
        case .setup, .finished: .finished
        }
    }

    /// Skip jumps the explanation, never the setup.
    static func skip(from step: Step) -> Step {
        switch step {
        case .pages: .setup
        case .setup, .finished: .finished
        }
    }
}
