import Foundation

/// The one stored thing about badges: which ones have already been **shown**
/// (spec §4), as a set of `Achievements.Badge` raw values in `UserDefaults`.
///
/// Not "unlocked" — that is a fact about the log and is re-derived every time.
/// Since #108 the Stats grid *displays* this set as earned, so nothing may be
/// written here before the user's last chance to undo — the Done screen writes
/// it as the user leaves. Losing the set is the cheap direction: a badge is
/// celebrated a second time. The expensive one is writing too early, because a
/// stale ledger shows a badge the log no longer supports, which is why it is
/// written late, never early. Not synced, not backed up, not in the Sheet, on
/// purpose.
///
/// Written only by whatever *shows* a badge — the Done screen's tiles, the
/// notification — never by evaluation. Each id is stored with the day it was
/// first shown, which is the date the Stats grid prints.
struct AchievementLedger {
    private let defaults: UserDefaults

    private enum Key {
        /// `[String: Date]` — badge id → the day it was first shown. Replaced the
        /// earlier `achievements.shown` (`[String]`) before anything wrote it.
        static let shownOn = "achievements.shownOn"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shownOn: [String: Date] {
        defaults.dictionary(forKey: Key.shownOn) as? [String: Date] ?? [:]
    }

    var shown: Set<String> { Set(shownOn.keys) }

    /// Records the first showing; a badge already in the ledger keeps its date.
    func markShown<S: Sequence>(_ badges: S, on date: Date = .now) where S.Element == Achievements.Badge {
        var merged = shownOn
        for badge in badges where merged[badge.rawValue] == nil {
            merged[badge.rawValue] = date
        }
        defaults.set(merged, forKey: Key.shownOn)
    }

    /// For `-resetStoreOnLaunch`: a UI test's ledger must not outlive its launch.
    func reset() {
        defaults.removeObject(forKey: Key.shownOn)
    }
}
