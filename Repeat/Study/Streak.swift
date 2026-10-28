import Foundation

/// Consecutive days with at least one review (§6.3, §6.5).
///
/// Derived from `_log` rather than stored. A counter would have to be corrected
/// on every undo, every restore from backup and every rebuild from `_log` (#41),
/// and any missed correction would be permanent and invisible. The log already
/// records exactly which days had reviews.
enum Streak {
    /// - Parameters:
    ///   - reviewDates: `reviewedAt` of every real review; undo markers
    ///     (rating 0) must already be excluded by the caller.
    ///   - frozenDays: start-of-day dates a `StreakFreeze` covers (#112). These
    ///     **continue** the run without counting toward it: a freeze buys a day
    ///     off, not a day's work, and §2.1 says every number here comes from the
    ///     log — which has no reviews on a frozen day. Defaulted to empty so a
    ///     caller that does not care about freezes gets exactly the old answer.
    static func length(
        reviewDates: [Date],
        frozenDays: Set<Date> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        length(days: ReviewDays(reviewDates: reviewDates, calendar: calendar),
               frozenDays: frozenDays, now: now, calendar: calendar)
    }

    /// The same answer from a day map that has already been built (#136). Stats
    /// builds one and hands it to this, `Records` and `Heatmap` rather than paying
    /// for the same start-of-day walk three times.
    static func length(
        days: ReviewDays,
        frozenDays: Set<Date> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        guard !days.isEmpty else { return 0 }
        let frozen = Set(frozenDays.map { calendar.startOfDay(for: $0) })

        let today = calendar.startOfDay(for: now)
        // A day with no session yet does not break the streak until it ends, so
        // count back from yesterday when today is still empty.
        var cursor = days.hasReview(on: today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        guard days.hasReview(on: cursor) || frozen.contains(cursor) else { return 0 }

        var length = 0
        while days.hasReview(on: cursor) || frozen.contains(cursor) {
            if days.hasReview(on: cursor) { length += 1 }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return length
    }
}
