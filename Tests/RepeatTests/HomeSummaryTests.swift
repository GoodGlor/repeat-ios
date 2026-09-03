import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #20 — Home's numbers, which must be the queue builder's own.
final class HomeSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func makeStore() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    @discardableResult
    private func makeDeck(
        _ context: ModelContext,
        title: String,
        colorHex: String = "#1F7A5C",
        sortOrder: Int = 0,
        cards: Int,
        due: Date? = nil
    ) -> Deck {
        let deck = Deck(sheetTitle: title, sheetId: 0, colorHex: colorHex, sortOrder: sortOrder)
        context.insert(deck)
        for index in 0..<cards {
            let note = Note(deck: deck, front: "\(title)-\(index)", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            if let due {
                // A reviewed card carries the evidence of its review. Setting `state`
                // without `lastReview` and `reps` describes a card the app cannot
                // produce — `rate()` writes all three from one snapshot — and #84's
                // queue reads `lastReview` as the queryable stand-in for "not new".
                // `QueueBuilderTests` has always built its fixtures this way.
                card.state = .review
                card.due = due
                card.reps = 3
                card.lastReview = due.addingTimeInterval(-86_400)
            }
            context.insert(card)
        }
        return deck
    }

    private func plan(_ context: ModelContext) throws -> QueuePlan {
        let decks = try context.fetch(FetchDescriptor<Deck>())
        var generator = SystemRandomNumberGenerator()
        return QueueBuilder.plan(decks: decks, now: now, using: &generator)
    }

    // MARK: - Acceptance: the count and estimate are the queue builder's

    func testDueCountAndEstimateComeFromThePlanItself() throws {
        let context = try makeStore()
        makeDeck(context, title: "Verbs", cards: 40)
        try context.save()

        let plan = try plan(context)
        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: plan, logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.dueCount, plan.count)
        XCTAssertEqual(summary.estimatedMinutes, plan.estimatedMinutes)
        // 40 new cards, but §5.2 caps the session — Home must promise the capped
        // figure, not the raw backlog, because that is what the button delivers.
        XCTAssertLessThan(summary.dueCount, 40)
    }

    func testPerDeckBadgesAddUpToTheSessionTotal() throws {
        let context = try makeStore()
        makeDeck(context, title: "Verbs", sortOrder: 0, cards: 6,
                 due: now.addingTimeInterval(-3600))
        makeDeck(context, title: "Nouns", sortOrder: 1, cards: 4,
                 due: now.addingTimeInterval(-7200))
        try context.save()

        let plan = try plan(context)
        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: plan, logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.decks.map(\.due).reduce(0, +), summary.dueCount)
        XCTAssertEqual(summary.decks.map(\.id), ["Verbs", "Nouns"], "sortOrder decides the order")
    }

    func testZeroDueIsTheAllDoneState() throws {
        let context = try makeStore()
        makeDeck(context, title: "Verbs", cards: 3, due: now.addingTimeInterval(5 * 86_400))
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertTrue(summary.isAllDone)
        XCTAssertEqual(summary.dueCount, 0)
    }

    // MARK: - Deck rows

    func testADeckWithNothingDueSaysWhenItComesBack() throws {
        let context = try makeStore()
        makeDeck(context, title: "Tomorrow", sortOrder: 0, cards: 2,
                 due: calendar.startOfDay(for: now).addingTimeInterval(86_400 + 3600))
        makeDeck(context, title: "Later", sortOrder: 1, cards: 2,
                 due: calendar.startOfDay(for: now).addingTimeInterval(3 * 86_400 + 3600))
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.decks[0].nextDueLabel, "завтра")
        XCTAssertEqual(summary.decks[1].nextDueLabel, "за 3 дн")
        XCTAssertTrue(summary.decks.allSatisfy { $0.due == 0 })
    }

    func testAnEmptyDeckClaimsNoDate() {
        XCTAssertNil(HomeSummary.nextDueLabel(for: [], now: now, calendar: calendar))
    }

    func testADeckInThePlanShowsABadgeInsteadOfADate() throws {
        let context = try makeStore()
        makeDeck(context, title: "Verbs", cards: 3, due: now.addingTimeInterval(-60))
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.decks[0].due, 3)
        XCTAssertNil(summary.decks[0].nextDueLabel)
    }

    func testAMalformedDeckCarriesItsReasonIntoTheRow() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Broken", cards: 1)
        deck.malformedReason = "немає колонки back"
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.decks[0].malformedReason, "немає колонки back")
    }

    func testDeletedDecksAndNotesAreNotCounted() throws {
        let context = try makeStore()
        let live = makeDeck(context, title: "Live", sortOrder: 0, cards: 2)
        let gone = makeDeck(context, title: "Gone", sortOrder: 1, cards: 5)
        gone.deletedAt = now
        live.notes[0].deletedAt = now
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.decks.map(\.id), ["Live"])
        XCTAssertEqual(summary.decks[0].cardCount, 1)
    }

    func testNewCardsIntroducedTodayAreCountedPerDeckAndOncePerCard() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 2)
        try context.save()
        let cardId = deck.notes[0].cards[0].id

        // The same card rated twice today still counts as one new card, and an
        // undo marker (rating 0) is not a review at all.
        let logs = try [
            ReviewLog(cardId: cardId, direction: .forward, rating: 3, reviewedAt: now,
                      elapsedDays: 0, scheduledDays: 1, stateBefore: .new,
                      prevState: CardSchedulingSnapshot()),
            ReviewLog(cardId: cardId, direction: .forward, rating: 3,
                      reviewedAt: now.addingTimeInterval(60),
                      elapsedDays: 0, scheduledDays: 1, stateBefore: .new,
                      prevState: CardSchedulingSnapshot()),
            ReviewLog(cardId: deck.notes[1].cards[0].id, direction: .forward, rating: 0,
                      reviewedAt: now, elapsedDays: 0, scheduledDays: 1, stateBefore: .new,
                      prevState: CardSchedulingSnapshot()),
        ]

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: logs, now: now, calendar: calendar)

        XCTAssertEqual(summary.decks[0].newToday, 1)
    }

    // MARK: - Today's progress (#89)

    /// The ring on Home's hero.
    ///
    /// Counted per **card**, not per log, for the same reason `newToday` is: a
    /// card walked through three learning steps writes three rows, and a ring
    /// that counted them would report more progress than there was work — and
    /// could exceed 1, which draws an over-full circle.
    func testTodayProgressCountsEachCardOnceAndIgnoresUndoMarkers() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 4, due: now.addingTimeInterval(-60))
        try context.save()
        let first = deck.notes[0].cards[0].id

        let logs = try [
            ReviewLog(cardId: first, direction: .forward, rating: 3, reviewedAt: now,
                      elapsedDays: 0, scheduledDays: 1, stateBefore: .learning,
                      prevState: CardSchedulingSnapshot()),
            // Same card, second learning step.
            ReviewLog(cardId: first, direction: .forward, rating: 3,
                      reviewedAt: now.addingTimeInterval(60),
                      elapsedDays: 0, scheduledDays: 1, stateBefore: .learning,
                      prevState: CardSchedulingSnapshot()),
            // An undo marker is not a review.
            ReviewLog(cardId: deck.notes[1].cards[0].id, direction: .forward, rating: 0,
                      reviewedAt: now, elapsedDays: 0, scheduledDays: 1, stateBefore: .review,
                      prevState: CardSchedulingSnapshot()),
        ]

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: logs, now: now, calendar: calendar)

        XCTAssertEqual(summary.reviewedToday, 1)
        XCTAssertLessThanOrEqual(summary.todayProgress, 1)
        XCTAssertEqual(summary.todayProgress,
                       Double(1) / Double(1 + summary.dueCount), accuracy: 0.0001)
    }

    /// A fresh install draws an empty ring, not a full one.
    ///
    /// `0 / 0` is the shape of the bug: dividing nothing by nothing and rendering
    /// the result as "100 %" would congratulate someone who has not opened a deck.
    func testTodayProgressIsZeroWhenThereIsNothingOnEitherSideOfTheRatio() throws {
        let context = try makeStore()
        try context.save()

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.dueCount, 0)
        XCTAssertEqual(summary.reviewedToday, 0)
        XCTAssertEqual(summary.todayProgress, 0)
    }

    /// An emptied queue reads as finished rather than as "nothing to do".
    func testTodayProgressIsCompleteOnceTheQueueIsEmptied() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 2, due: now.addingTimeInterval(86_400))
        try context.save()

        let logs = try deck.notes.map { note in
            try ReviewLog(cardId: note.cards[0].id, direction: .forward, rating: 3,
                          reviewedAt: now, elapsedDays: 0, scheduledDays: 1,
                          stateBefore: .review, prevState: CardSchedulingSnapshot())
        }

        let summary = HomeSummary.make(
            decks: try context.fetch(FetchDescriptor<Deck>()),
            plan: try plan(context), logsToday: logs, now: now, calendar: calendar)

        XCTAssertEqual(summary.dueCount, 0, "nothing should be due yet")
        XCTAssertEqual(summary.reviewedToday, 2)
        XCTAssertEqual(summary.todayProgress, 1)
    }

    /// #89 shows the streak on Home and in the session's top bar, and hides it
    /// below two days: "1 day" on the very first session is not an achievement,
    /// and a chip that starts at zero is a chip that is always there.
    func testTheStreakChipAppearsOnlyOnceTheStreakIsWorthKeeping() {
        XCTAssertFalse(StreakChip.isWorthShowing(0))
        XCTAssertFalse(StreakChip.isWorthShowing(1))
        XCTAssertTrue(StreakChip.isWorthShowing(2))
        XCTAssertTrue(StreakChip.isWorthShowing(30))
    }

    // MARK: - Greeting

    func testGreetingFollowsTheClock() {
        func greeting(hour: Int) -> String {
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
            return HomeSummary.greeting(at: date, calendar: calendar)
        }
        XCTAssertEqual(greeting(hour: 8), "Доброго ранку")
        XCTAssertEqual(greeting(hour: 13), "Добрий день")
        XCTAssertEqual(greeting(hour: 20), "Добрий вечір")
        XCTAssertEqual(greeting(hour: 2), "Доброї ночі")
    }

    // MARK: - Acceptance: pull-to-refresh bypasses the throttle

    func testPullToRefreshIsNotThrottled() {
        XCTAssertNil(SyncTrigger.pullToRefresh.throttleInterval,
                     "§4.2 exempts pull-to-refresh; the behaviour itself is proven in SyncActorTests")
        XCTAssertEqual(SyncTrigger.appActive.throttleInterval, 600)
    }
}
