import Foundation
import SwiftData

/// Everything Home shows, computed once (§6.2).
///
/// Home's numbers come from the queue builder's own plan rather than a parallel
/// count. The plan is capped — a global new-card ceiling, a per-deck allowance —
/// so a "cards due" figure derived any other way would promise more work than
/// pressing the button actually delivers. The same plan is then handed to the
/// session, so the count on the button and the queue behind it cannot disagree.
struct HomeSummary: Equatable {
    struct DeckRow: Identifiable, Equatable {
        var id: String
        var title: String
        var colorHex: String
        var cardCount: Int
        var newToday: Int
        /// How many of *this session's* cards belong to this deck.
        var due: Int
        /// Shown instead of a badge when the deck owes nothing today.
        var nextDueLabel: String?
        var malformedReason: String?
        /// §5.3: known ▮ learning ▮ new, over the same cards as `cardCount`.
        var mastery: Mastery.Counts
        /// #153: the tag this deck is studied under, when it is not all cards.
        var filterLabel: String? = nil
    }

    var greeting: String
    var dueCount: Int
    var estimatedMinutes: Int
    var newCardCount: Int
    /// Distinct cards actually graded today (#89). Counted per card rather than
    /// per log, so a card seen three times through its learning steps counts once
    /// — otherwise a short session can report more progress than there was work.
    var reviewedToday: Int
    /// M9 §5.1: today's target, fixed at the first build of the day.
    var goal: DailyGoal
    var decks: [DeckRow]

    var isAllDone: Bool { dueCount == 0 }

    /// How much of today is behind you, 0…1 (#89), against a target that does
    /// not move (M9). Counted per card, not per log, against that fixed target
    /// — see `DailyGoal` for why the denominator is fixed and `reviewedCount`
    /// for why the numerator is per card.
    var todayProgress: Double { goal.progress }

    /// The rule `reviewedToday` uses: a real grade, once per card, today.
    /// `rating != 0` excludes the log rows a rebuild from `_log` writes for
    /// cards that were never actually answered (#41) — those rows exist to
    /// carry scheduling state across the rebuild, not to record a review.
    static func reviewedCount(logsToday: [ReviewLog], now: Date, calendar: Calendar = .current) -> Int {
        Set(
            logsToday.filter { $0.rating != 0 && calendar.isDate($0.reviewedAt, inSameDayAs: now) }
                .map(\.cardId)
        ).count
    }

    static func make(
        decks: [Deck],
        plan: QueuePlan,
        logsToday: [ReviewLog],
        cachedTarget: Int? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HomeSummary {
        let live = decks.filter { $0.deletedAt == nil }.sorted {
            ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle)
        }

        // Cards are selected by *query*, not by walking `deck.notes → note.cards`
        // (#116 — the rule #84 gave the queue builder). The walk resolves one
        // relationship fault per note, and SwiftData turns those faults back on
        // after every fetch of the parent — the view's own `@Query` included — so
        // the walk was cold on every Home pass: **2.4 s** at ten thousand cards
        // against 0.07 s warm. A fetch with the two-hop join in the predicate
        // reads the columns straight from SQLite, and costs the same every time.
        var cardsByDeck: [String: [Card]] = [:]
        for deck in live { cardsByDeck[deck.sheetTitle] = cards(of: deck) }

        // card id → deck, so the plan can be split by deck without re-deriving
        // which cards are due.
        var deckOfCard: [String: String] = [:]
        for (title, cards) in cardsByDeck {
            for card in cards { deckOfCard[card.id] = title }
        }

        var dueByDeck: [String: Int] = [:]
        for id in plan.cardIds {
            guard let title = deckOfCard[id] else { continue }
            dueByDeck[title, default: 0] += 1
        }

        var newTodayByDeck: [String: Int] = [:]
        var counted: Set<String> = []
        for log in logsToday
        where log.stateBefore == .new && log.rating != 0
            && calendar.isDate(log.reviewedAt, inSameDayAs: now) {
            guard let title = deckOfCard[log.cardId], counted.insert(log.cardId).inserted
            else { continue }
            newTodayByDeck[title, default: 0] += 1
        }

        let rows = live.map { deck -> DeckRow in
            let cards = cardsByDeck[deck.sheetTitle] ?? []
            let due = dueByDeck[deck.sheetTitle] ?? 0
            return DeckRow(
                id: deck.sheetTitle,
                title: deck.sheetTitle,
                colorHex: deck.colorHex,
                cardCount: cards.count,
                newToday: newTodayByDeck[deck.sheetTitle] ?? 0,
                due: due,
                nextDueLabel: due == 0
                    ? nextDueLabel(for: cards, now: now, calendar: calendar)
                    : nil,
                malformedReason: deck.malformedReason,
                mastery: Mastery.Counts.make(cards: cards),
                filterLabel: plan.filters[deck.sheetTitle]?.label
            )
        }

        let reviewedToday = reviewedCount(logsToday: logsToday, now: now, calendar: calendar)

        return HomeSummary(
            greeting: greeting(at: now, calendar: calendar),
            dueCount: plan.count,
            estimatedMinutes: plan.estimatedMinutes,
            newCardCount: plan.newCardCount,
            reviewedToday: reviewedToday,
            goal: DailyGoal.make(reviewedToday: reviewedToday, dueCount: plan.count,
                                 cachedTarget: cachedTarget),
            decks: rows
        )
    }

    /// The deck's live cards — every card of every note that is not soft-deleted
    /// — by query (see `make`). A deck that belongs to no store has no cards to
    /// select, the same answer `QueueBuilder.plan` gives.
    static func cards(of deck: Deck) -> [Card] {
        guard let context = deck.modelContext else { return [] }
        let title = deck.sheetTitle
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
            card.note.deletedAt == nil
                && card.note.deck.deletedAt == nil
                && card.note.deck.sheetTitle == title
        })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// When the deck's next card comes back, in the coarsest useful terms.
    ///
    /// Returns `nil` for a deck with nothing scheduled at all — an empty deck
    /// should say nothing rather than claim a date it does not have.
    static func nextDueLabel(for cards: [Card], now: Date, calendar: Calendar) -> String? {
        let upcoming = cards.filter { !$0.isSuspended }.map(\.due).min()
        guard let next = upcoming else { return nil }

        // Measured against `now`, never against the wall clock. `isDateInTomorrow`
        // asks the system what today is, which makes the answer wrong for any
        // injected date — and wrong on a real phone across a midnight boundary
        // between building the summary and rendering it.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: next)
        ).day ?? 0

        switch days {
        case ..<0: return nil
        // Later today, but not in the plan: a learning card whose timer has not
        // expired yet.
        case 0: return next > now ? Localized.string("сьогодні") : nil
        case 1: return Localized.string("завтра")
        default: return Localized.string("за \(days) дн")
        }
    }

    /// §6.2's greeting. No name yet — onboarding (#24) is where one gets asked
    /// for, and inventing one before then would be worse than none.
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: Localized.string("Доброго ранку")
        case 12..<18: Localized.string("Добрий день")
        case 18..<23: Localized.string("Добрий вечір")
        default: Localized.string("Доброї ночі")
        }
    }
}
