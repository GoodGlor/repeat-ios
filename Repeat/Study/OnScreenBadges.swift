import Foundation

/// The badges a Done screen is displaying right now (§5.5).
///
/// The Done screen writes the ledger only when it is **left by a button**,
/// because shake-to-undo stays live while it is on screen — `StudyView` puts
/// `.onShake { undo() }` on `DoneView`, and `DoneView.leave` is the only caller
/// of `markShown`. So a Done screen that has not been left yet is showing
/// badges that are still *fresh* in the ledger.
///
/// A `BGAppRefreshTask` resumes a **suspended** process; it does not need the
/// app to have been quit. So the ordinary "finish a session, lock the phone on
/// the Done screen, come back tomorrow" evening puts a live Done screen with
/// fresh badges under the next background refresh: the scene is not active, the
/// badges are still fresh, and without this set `AchievementNotification.post`
/// would announce a badge that is on screen behind the lock and spend it while
/// its undo is still reachable. The scene check cannot catch that — a locked
/// phone showing the Done screen is not active.
///
/// **In-memory and per-process on purpose**, and that is the property that makes
/// this correct rather than a guess: this set and the Done screen are created
/// and destroyed together, in the same process. If iOS jettisoned the app and
/// relaunched it for the background task, this set is empty *and* that Done
/// screen is gone with it — the owner will never see it again, its undo window
/// is closed, and announcing those badges is then exactly right. Nothing is
/// persisted, so nothing can be left behind by a crash to silence a badge
/// forever.
///
/// Deliberately not on `DoneView`: `AchievementNotification` subtracts this set
/// and must not reference a view.
@MainActor
enum OnScreenBadges {
    /// Written by `DoneView` as it appears and cleared as it goes away — the
    /// disappearance, not the button, because an undo takes the screen away
    /// without going through `leave`.
    private(set) static var current: Set<Achievements.Badge> = []

    static func show<S: Sequence>(_ badges: S) where S.Element == Achievements.Badge {
        current = Set(badges)
    }

    static func clear() {
        current = []
    }
}
