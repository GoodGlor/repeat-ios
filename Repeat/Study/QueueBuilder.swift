import Foundation
import SwiftData
import Scheduling

/// Knobs for building a session queue (§5.2).
struct QueueConfig: Equatable, Sendable {
    /// Ceiling across all decks, applied after each deck's own `newCardsPerDay`.
    var globalNewCardCap: Int = 30
    /// Used until there are enough logs to measure (§5.2).
    var defaultSecondsPerCard: TimeInterval = 20
    /// Gaps longer than this are treated as a break rather than a card, so a
    /// session resumed the next morning does not report a 14-hour card.
    var maxPlausibleSecondsPerCard: TimeInterval = 120
    /// §5.2 says "the last 200 logs".
    var estimateSampleSize: Int = 200
}

/// An ordered session queue, built once when a session starts and rebuilt when the
/// day rolls over (§5.2).
struct QueuePlan: Equatable, Sendable {
    /// Card ids in the order they will be shown.
    var cardIds: [String]
    var dueReviewCount: Int
    var newCardCount: Int
    var secondsPerCard: TimeInterval
    /// The local day this plan was built for; a plan from yesterday is stale.
    var studyDay: Date

    var count: Int { cardIds.count }
    var isEmpty: Bool { cardIds.isEmpty }
    var estimatedSeconds: TimeInterval { Double(count) * secondsPerCard }
    var estimatedMinutes: Int { max(1, Int((estimatedSeconds / 60).rounded())) }

    func isStale(at now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(studyDay, inSameDayAs: now)
    }
}

enum QueueBuilder {

    /// Builds the queue for a session (§5.2).
    ///
    /// Order is: due reviews by `due` ascending, randomised within the same day, then
    /// new cards in sheet row order. Suspended cards never appear, and neither do
    /// cards due later today — those come back through `StudyQueue` when their
    /// timer expires.
    static func plan(
        decks: [Deck],
        now: Date = .now,
        config: QueueConfig = QueueConfig(),
        recentLogs: [ReviewLog] = [],
        logsToday: [ReviewLog] = [],
        calendar: Calendar = .current,
        using generator: inout some RandomNumberGenerator
    ) -> QueuePlan {
        let live = decks.filter { $0.deletedAt == nil }
        let titles = live.map(\.sheetTitle)
        let secondsPerCard = secondsPerCard(from: recentLogs, config: config)
        let studyDay = calendar.startOfDay(for: now)

        // Cards are selected by *query*, not by walking the object graph (#84).
        //
        // The old version was `for deck { for note { for card` — which materialises
        // every `Note` and every `Card` in the store to read four scalars off each.
        // Measured on 10k cards it took **3.0 s** against §8's 300 ms budget, and
        // the profile said exactly where it went: fetching the cards costs 0.17 s,
        // and reading `card.note.deck` across the results costs **1.03 s** on its
        // own. Relationship traversal is the entire bill; the arithmetic is free.
        //
        // So nothing below touches `card.note` per card. The filtering that used to
        // be `where` clauses is now a `#Predicate` — including the two hops to
        // `note.deletedAt` and `note.deck.sheetTitle`, which SwiftData turns into a
        // join and which measured free (0.086 s for the same 10k).
        guard let context = live.first?.modelContext, !titles.isEmpty else {
            // A deck that belongs to no store has no cards to select. Returning
            // empty is the honest answer, and it keeps `secondsPerCard` and
            // `studyDay` meaningful for a caller that only reads those.
            return QueuePlan(cardIds: [], dueReviewCount: 0, newCardCount: 0,
                             secondsPerCard: secondsPerCard, studyDay: studyDay)
        }

        // Due reviews — anything already learned and now owed, including learning
        // and relearning cards whose intra-day timer has already expired.
        //
        // `lastReview != nil` rather than `state != .new`, because `SchedulingState`
        // cannot appear in a `#Predicate` at all — the enum lives in another module
        // and is not one of the schema's value types, so equality is rejected as
        // flatly as inequality. The two are exactly equivalent: a card is `.new`
        // until its first rating, and that rating is what sets `lastReview`. They
        // are written from one snapshot by `rate`, by undo and by a restore, so it
        // is an invariant rather than a coincidence — and `StatsTests` asserts it
        // directly instead of leaving this comment to be believed.
        let dueDescriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
            !card.isSuspended
                && card.due <= now
                && card.lastReview != nil
                && card.note.deletedAt == nil
                && titles.contains(card.note.deck.sheetTitle)
        })
        let dueCards = (try? context.fetch(dueDescriptor)) ?? []
        let dueOrdered = orderDueCards(dueCards, calendar: calendar, using: &generator)

        // New cards — per-deck allowance first, then the global ceiling, always in
        // sheet row order so the owner's ordering in Sheets decides what is learned
        // first.
        let introduced = introducedToday(logsToday: logsToday, in: context,
                                         now: now, calendar: calendar)
        var newCards: [Card] = []
        for deck in live.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let allowance = max(0, deck.newCardsPerDay - (introduced[deck.sheetTitle] ?? 0))
            guard allowance > 0 else { continue }
            newCards.append(contentsOf: nextNewCards(in: context,
                                                     deckTitle: deck.sheetTitle,
                                                     allowance: allowance))
        }
        newCards = Array(newCards.prefix(config.globalNewCardCap))

        return QueuePlan(
            cardIds: dueOrdered.map(\.id) + newCards.map(\.id),
            dueReviewCount: dueOrdered.count,
            newCardCount: newCards.count,
            secondsPerCard: secondsPerCard,
            studyDay: studyDay
        )
    }

    /// One deck's next new cards, in sheet row order (§5.2).
    ///
    /// Ordered **entirely in SQL**, so the store returns a short window rather than
    /// every unseen card in the deck. The second sort key is `Card.id`, which is not
    /// an arbitrary choice: the id is `"<note uuid>#fwd"`, a fixed-width uuid
    /// followed by the direction, so ordering by it *is* ordering by
    /// `(note.id, direction)` — the exact tie-break §5.2 specifies, expressed in one
    /// indexed string column.
    ///
    /// An earlier attempt sorted on `sheetRow` alone and re-sorted a wider window in
    /// memory, assuming ties are rare and shallow. A test with sixty notes sharing
    /// one row index disproved it on the first run: SQLite returns an arbitrary
    /// subset for the limit, and the ten that should have come first were not all in
    /// it. Sorting completely in SQL removed the assumption instead of widening it.
    ///
    /// ## Why `state` is checked again in memory
    ///
    /// `lastReview == nil` is the SQL stand-in for `.new` (see `plan`). It is exact
    /// for any card the app can produce — but if it ever were not, the consequence
    /// *here* is the worst one in the app: a card halfway through its learning steps
    /// would be handed back as if it had never been seen, resetting real scheduling
    /// state. So the predicate is treated as a cheap **filter** and `state` as the
    /// **authority**. The window is wider than the allowance to leave room for rows
    /// the filter over-includes, so the cost of the belt-and-braces is one short
    /// fetch, and the worst case becomes "slightly fewer new cards today" rather
    /// than "a learning card silently reset".
    private static func nextNewCards(
        in context: ModelContext,
        deckTitle: String,
        allowance: Int
    ) -> [Card] {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                !card.isSuspended
                    && card.lastReview == nil
                    && card.note.deletedAt == nil
                    && card.note.deck.sheetTitle == deckTitle
            },
            sortBy: [SortDescriptor(\Card.note.sheetRow), SortDescriptor(\Card.id)]
        )
        descriptor.fetchLimit = allowance * 2 + 16
        let window = (try? context.fetch(descriptor)) ?? []
        return Array(window.lazy.filter { $0.state == .new }.prefix(allowance))
    }

    /// `due` ascending, shuffled within a calendar day.
    ///
    /// Two cards owed from the same day carry no meaningful order between them —
    /// the timestamps only reflect when they happened to be rated — so showing them
    /// in a fixed order every session would drill the same sequence. Ordering
    /// *between* days is preserved, so the longest-overdue material still comes
    /// first.
    private static func orderDueCards(
        _ cards: [Card],
        calendar: Calendar,
        using generator: inout some RandomNumberGenerator
    ) -> [Card] {
        let byDay = Dictionary(grouping: cards) { calendar.startOfDay(for: $0.due) }
        return byDay.keys.sorted().flatMap { day in
            byDay[day, default: []].shuffled(using: &generator)
        }
    }

    /// New cards already introduced today, per deck, so a second session on the
    /// same day does not hand out a fresh full allowance.
    ///
    /// This has to come from the log: a card that is no longer `.new` looks
    /// identical whether it was introduced this morning or last month. A log row
    /// with `stateBefore == .new` is the only record of the transition.
    private static func introducedToday(
        logsToday: [ReviewLog],
        in context: ModelContext,
        now: Date,
        calendar: Calendar
    ) -> [String: Int] {
        // A card counts once even if both its directions were introduced, because
        // the allowance is about new *material*, not new sides of it. A `Set` of
        // ids gives that for free, and it is also what makes the fetch below small.
        let ids = Set(
            logsToday
                .filter { $0.stateBefore == .new && $0.rating != 0
                    && calendar.isDate($0.reviewedAt, inSameDayAs: now) }
                .map(\.cardId)
        )
        guard !ids.isEmpty else { return [:] }

        // #84: this used to build a card-id → deck map by walking every deck, note
        // and card in the store — thousands of faults to answer a question about
        // the handful of cards introduced *today*. Fetching those by id and reading
        // the deck off each is bounded by the daily new-card cap instead.
        let identifiers = Array(ids)
        let descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { identifiers.contains($0.id) })
        let cards = (try? context.fetch(descriptor)) ?? []

        var counts: [String: Int] = [:]
        for card in cards {
            counts[card.note.deck.sheetTitle, default: 0] += 1
        }
        return counts
    }

    /// Average seconds per card, measured from the gaps between consecutive reviews
    /// in the most recent logs (§5.2). `ReviewLog` records when a review happened,
    /// not how long it took, so the gap is the only available signal; gaps longer
    /// than `maxPlausibleSecondsPerCard` are breaks between sessions, not cards.
    static func secondsPerCard(from logs: [ReviewLog], config: QueueConfig = QueueConfig()) -> TimeInterval {
        let times = logs
            .filter { $0.rating != 0 }               // undo markers are not reviews (§5.5)
            .map(\.reviewedAt)
            .sorted()
            .suffix(config.estimateSampleSize)

        guard times.count >= 2 else { return config.defaultSecondsPerCard }

        let gaps = zip(times, times.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 && $0 <= config.maxPlausibleSecondsPerCard }

        guard !gaps.isEmpty else { return config.defaultSecondsPerCard }
        return gaps.reduce(0, +) / Double(gaps.count)
    }
}
