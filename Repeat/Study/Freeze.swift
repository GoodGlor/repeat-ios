import Foundation
import SwiftData

/// The rules around `StreakFreeze` (#112): how many exist, and when one is spent.
///
/// Everything here except the act of writing a row is a pure function of the log
/// and the rows already stored, which is what keeps §2.1's "derived, never
/// counted" true of all but the one irreducible fact.
enum Freeze {
    /// One freeze per this many days on which a review happened. Cumulative over
    /// the whole log, so it never goes down and never needs correcting on undo.
    static let daysPerFreeze = 7
    /// The most that can be held at once. Without a cap they pile up until a
    /// streak is never really at risk, and a streak that cannot be lost is not
    /// worth keeping.
    static let maximumHeld = 2

    /// How many have ever been earned. Derived (§2.1).
    static func earned(reviewDays: Set<Date>) -> Int {
        reviewDays.count / daysPerFreeze
    }

    /// How many are available to spend right now.
    static func available(reviewDays: Set<Date>, spent: Int) -> Int {
        min(maximumHeld, max(0, earned(reviewDays: reviewDays) - spent))
    }

    /// The day a freeze should cover, or `nil` when none should be spent.
    ///
    /// **Only yesterday, and only when the day before it was already part of a
    /// run.** That single restriction is what makes this whole feature safe:
    ///
    /// - at most one freeze goes per settle, so nothing can drain in a burst;
    /// - returning after a long absence cannot reach back and rewrite history;
    /// - settling repeatedly in one day changes nothing, because the second call
    ///   sees yesterday already frozen;
    /// - and "a freeze bridges one day, not two" needs no special case — miss
    ///   Monday and Tuesday, come back Wednesday, and freezing Tuesday could not
    ///   save Monday, so nothing is spent trying.
    static func dayToFreeze(
        reviewDays: Set<Date>,
        frozen: Set<Date>,
        available: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        guard available > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)
        else { return nil }

        // Nothing to save if yesterday was worked, and nothing to do if it has
        // already been covered.
        guard !reviewDays.contains(yesterday), !frozen.contains(yesterday) else { return nil }
        // And nothing to save if there was no run reaching yesterday in the first
        // place — a freeze protects a streak, it does not start one.
        guard reviewDays.contains(dayBefore) || frozen.contains(dayBefore) else { return nil }

        return yesterday
    }
}

// MARK: - The store

extension Freeze {
    static func rows(in context: ModelContext) -> [StreakFreeze] {
        (try? context.fetch(FetchDescriptor<StreakFreeze>())) ?? []
    }

    /// The set `Streak.length(frozenDays:)` wants.
    static func days(in context: ModelContext) -> Set<Date> {
        Set(rows(in: context).map(\.day))
    }

    /// Spends a freeze if one is due, and returns the row it wrote.
    ///
    /// Idempotent by two separate mechanisms, which is deliberate for the one
    /// piece of state in this app that cannot be recomputed: `dayToFreeze`
    /// refuses a day already covered, and `StreakFreeze.day` is `@Attribute
    /// (.unique)` so a second write would collapse onto the first anyway.
    @discardableResult
    static func settle(
        in context: ModelContext,
        reviewDays: Set<Date>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> StreakFreeze? {
        let existing = rows(in: context)
        let frozen = Set(existing.map(\.day))
        let available = available(reviewDays: reviewDays, spent: existing.count)
        guard let day = dayToFreeze(reviewDays: reviewDays, frozen: frozen,
                                    available: available, now: now, calendar: calendar)
        else { return nil }

        let freeze = StreakFreeze(day: day, spentAt: now)
        context.insert(freeze)
        try? context.save()
        return freeze
    }

    /// The freeze the Done screen has not named yet, if there is one.
    static func unannounced(in context: ModelContext) -> StreakFreeze? {
        rows(in: context)
            .filter { $0.announcedAt == nil }
            .max { $0.day < $1.day }
    }
}
