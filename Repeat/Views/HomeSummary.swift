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
    }

    var greeting: String
    var dueCount: Int
    var estimatedMinutes: Int
    var newCardCount: Int
    /// Distinct cards actually graded today (#89). Counted per card rather than
    /// per log, so a card seen three times through its learning steps counts once
    /// — otherwise a short session can report more progress than there was work.
    var reviewedToday: Int
    var decks: [DeckRow]

    var isAllDone: Bool { dueCount == 0 }

    /// How much of today is behind you, 0…1 (#89).
    ///
    /// The denominator is what today turned out to be — everything already done
    /// plus everything still planned — not a target set in advance. A goal the
    /// app invents would be a number to fail; this one can only ever move
    /// forward, and reaches 1 exactly when the queue empties.
    ///
    /// Zero when there is nothing on either side of the ratio, so a fresh install
    /// draws an empty ring rather than a full one.
    var todayProgress: Double {
        let total = reviewedToday + dueCount
        guard total > 0 else { return 0 }
        return Double(reviewedToday) / Double(total)
    }

    static func make(
        decks: [Deck],
        plan: QueuePlan,
        logsToday: [ReviewLog],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HomeSummary {
        let live = decks.filter { $0.deletedAt == nil }.sorted {
            ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle)
        }

        // card id → deck, so the plan can be split by deck without re-deriving
        // which cards are due.
        var deckOfCard: [String: String] = [:]
        for deck in live {
            for note in deck.notes where note.deletedAt == nil {
                for card in note.cards { deckOfCard[card.id] = deck.sheetTitle }
            }
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
            let cards = deck.notes.filter { $0.deletedAt == nil }.flatMap(\.cards)
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
                malformedReason: deck.malformedReason
            )
        }

        // Reuses the same "a real grade, once per card" rule the per-deck new
        // count above uses — `rating != 0` excludes the log rows a rebuild writes
        // for cards that were never actually answered (#41).
        let reviewedToday = Set(
            logsToday.filter { $0.rating != 0 && calendar.isDate($0.reviewedAt, inSameDayAs: now) }
                .map(\.cardId)
        ).count

        return HomeSummary(
            greeting: greeting(at: now, calendar: calendar),
            dueCount: plan.count,
            estimatedMinutes: plan.estimatedMinutes,
            newCardCount: plan.newCardCount,
            reviewedToday: reviewedToday,
            decks: rows
        )
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
