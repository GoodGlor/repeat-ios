import Foundation

/// Today's target and how far along it is (M9 §5.1).
///
/// #89's ring divided by a moving total, so cards arriving mid-day pulled a
/// finished ring back to a fraction. The target is now what today looked like
/// the first time Home built it — cached for the day by `DailyGoalCache` — and
/// the ring can only move forward. It is never below `done`: catch-up mode can
/// grade more than the morning promised, and a ring past 100 % is a lie about
/// the target, not a fact about the work.
///
/// The one exception to "the target only grows": an empty queue lowers it. The
/// catch-up offer (and suspending, deleting, or lowering a limit) can shrink
/// today's queue without anything being graded — the cards did not vanish, they
/// moved to a later day. If the target kept the morning's larger number, a day
/// that finished everything left in it would sit at a fraction forever instead
/// of closing.
struct DailyGoal: Equatable {
    /// 0 means there is no goal today — nothing was due and nothing was done.
    var target: Int
    /// Distinct cards graded today, the rule `HomeSummary.reviewedToday` uses.
    var done: Int

    static func make(reviewedToday: Int, dueCount: Int, cachedTarget: Int?) -> DailyGoal {
        // A cached zero is "no goal yet": the day started empty. The first build
        // with work on it sets the real target.
        let cached: Int? = (cachedTarget ?? 0) > 0 ? cachedTarget : nil
        let base = cached ?? (reviewedToday + dueCount)
        // An empty queue closes the day at what was actually done, even if the
        // cached target was bigger — the rest moved to a later day, not lost.
        let target = dueCount == 0 ? reviewedToday : max(base, reviewedToday)
        return DailyGoal(target: target, done: reviewedToday)
    }

    /// 0…1; 0 when there is no goal, so a fresh install draws an empty ring.
    ///
    /// `min(1, …)` guards a future constructor that bypasses `make` — `make`
    /// itself already guarantees `target >= done`, so this call site can never
    /// see the ratio exceed 1.
    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(done) / Double(target))
    }

    var isClosed: Bool { target > 0 && done >= target }
}

/// The one stored thing about the goal: `(day, target)`, in `UserDefaults`.
///
/// A cache of a derived value. Losing it means the next build of Home sets the
/// target again from what the day looks like then — never that anything is
/// counted twice or lost. Not synced, not backed up, on purpose.
///
/// App-process `UserDefaults.standard` only. This once predicted that the widget
/// ring would need its own read of it through an App Group suite; #111 did the
/// opposite and published the target into the shared file, so there is still one
/// reader of this cache and one definition of the day's target (§7.1).
///
/// A timezone change mid-day moves local midnight, so the cached day no longer
/// matches and the target is re-derived as if the day were new. Rare, accepted,
/// and self-correcting the next day.
struct DailyGoalCache {
    private let defaults: UserDefaults
    private let calendar: Calendar

    private enum Key {
        static let day = "dailyGoal.day"        // start of day, seconds since 1970
        static let target = "dailyGoal.target"
    }

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func target(on day: Date) -> Int? {
        guard let stored = defaults.object(forKey: Key.day) as? Double,
              stored == calendar.startOfDay(for: day).timeIntervalSince1970
        else { return nil }
        return defaults.object(forKey: Key.target) as? Int
    }

    func store(_ target: Int, on day: Date) {
        defaults.set(calendar.startOfDay(for: day).timeIntervalSince1970, forKey: Key.day)
        defaults.set(target, forKey: Key.target)
    }
}
