import Foundation
import SwiftData
import Scheduling

/// §5.3 — spreading a backlog over three days.
///
/// The point is not to make the number smaller. It is that a backlog is the
/// commonest reason people stop, and 300 cards is a wall whether or not the
/// scheduler thinks they are all owed today. Moving the *safest* cards out keeps
/// the ones actually at risk of being forgotten in front of the person.
enum CatchUp {

    /// What Home shows when there is a backlog worth offering to spread.
    struct Offer: Equatable {
        /// Due reviews right now — the number the person is looking at.
        var dueReviews: Int
        /// The 14-day average daily review count this is measured against.
        var dailyAverage: Double
        /// How many would move out of today.
        var moving: Int
        /// What today's queue becomes.
        var remaining: Int { dueReviews - moving }
    }

    /// §5.3's two conditions, both of them.
    ///
    /// The multiple alone would fire on the second day of use, when the average
    /// is 3 and the queue is 8; the floor alone would nag someone whose normal
    /// day *is* 60 cards. A backlog is only a backlog relative to the habit.
    static let multipleOfAverage = 2.0
    static let minimumDue = 50
    /// §5.3's window.
    static let averagingDays = 14
    /// "Spread over 3 days" — today, tomorrow, the day after.
    static let days = 3

    /// The daily average over the last 14 days, counting only days that have
    /// passed.
    ///
    /// Divided by the window, not by the number of days that had reviews: an
    /// average taken over active days only would rise every time someone skipped
    /// a day, which is exactly when a backlog forms — the offer would then be
    /// hardest to trigger at the moment it is most needed.
    static func dailyAverage(
        logs: [ReviewLog],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -averagingDays, to: today)
        else { return 0 }
        let recent = logs.filter { $0.reviewedAt >= windowStart && $0.reviewedAt < today }
        return Double(recent.count) / Double(averagingDays)
    }

    /// `nil` when there is no backlog — which is also how "the offer disappears
    /// once the backlog clears" is implemented: there is no separate dismissal
    /// state to get out of step with reality.
    static func offer(
        dueReviews: Int,
        logs: [ReviewLog],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Offer? {
        let average = dailyAverage(logs: logs, now: now, calendar: calendar)
        guard dueReviews > minimumDue, Double(dueReviews) > multipleOfAverage * average
        else { return nil }

        let keeping = keepCount(of: dueReviews)
        return Offer(dueReviews: dueReviews, dailyAverage: average, moving: dueReviews - keeping)
    }

    /// Today's share, rounded up: on 100 cards this leaves 34 today and moves 33
    /// and 33. The remainder stays rather than moves, because the day someone
    /// asked for help is not the day to hand them the bigger half.
    static func keepCount(of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(total) / Double(days)).rounded(.up))
    }

    /// Which card moves where.
    ///
    /// Sorted by retrievability descending: the cards most likely to still be
    /// remembered are the ones it is safe to postpone, and the furthest day goes
    /// to the safest of them. The most fragile memories keep today's slot, which
    /// is the whole justification for touching a scheduler's dates at all.
    ///
    /// Returns pairs rather than mutating, so the decision can be tested without
    /// a store and applied in one place.
    static func schedule(
        cards: [Card],
        scheduler: Scheduler = Scheduler(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [(card: Card, due: Date)] {
        guard cards.count > 1 else { return [] }

        let ranked = cards
            .map { (card: $0, retrievability: scheduler.retrievability(of: $0.snapshot, now: now)) }
            // `id` breaks ties so the same backlog produces the same plan twice —
            // otherwise "accepting twice does nothing" would depend on sort
            // stability, which Swift does not promise.
            .sorted { ($0.retrievability, $0.card.id) > ($1.retrievability, $1.card.id) }
            .map(\.card)

        let keeping = keepCount(of: ranked.count)
        let moving = ranked.count - keeping
        guard moving > 0 else { return [] }

        // The safest half of the movers goes two days out, the rest one.
        let toDayTwo = moving / 2
        var plan: [(card: Card, due: Date)] = []
        for (index, card) in ranked.prefix(moving).enumerated() {
            let offset = index < toDayTwo ? 2 : 1
            guard let due = shifted(card.due, byDays: offset, now: now, calendar: calendar) else { continue }
            plan.append((card, due))
        }
        return plan
    }

    /// Applies the plan.
    ///
    /// Only `due` moves. Stability and difficulty are the card's memory model and
    /// have nothing to do with when it is convenient to see it — rescheduling
    /// that touched them would be rewriting history to make a queue shorter.
    @discardableResult
    static func apply(
        _ plan: [(card: Card, due: Date)],
        in context: ModelContext
    ) throws -> Int {
        for entry in plan { entry.card.due = entry.due }
        try context.save()
        return plan.count
    }

    /// Keeps the card's own time of day, moved to a later date.
    ///
    /// Preserving the clock time rather than snapping to midnight keeps the
    /// within-day ordering §5.2 builds the queue from, and stops a spread turning
    /// into a pile that all comes due at 00:00.
    private static func shifted(
        _ due: Date,
        byDays days: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        // An overdue card carries a `due` in the past, sometimes weeks back.
        // Shifting *that* would leave it still overdue and still in today's
        // queue — the move has to be measured from today.
        let base = max(due, now)
        return calendar.date(byAdding: .day, value: days, to: base)
    }
}
