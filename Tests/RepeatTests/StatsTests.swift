import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #35 — the stats, all of them local, and fast enough with a real deck.
final class StatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar.current

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    @discardableResult
    private func log(_ rating: Int, daysAgo: Int, in context: ModelContext) throws -> ReviewLog {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let entry = try ReviewLog(
            cardId: "c-\(daysAgo)-\(rating)-\(UUID().uuidString)", direction: .forward,
            rating: rating, reviewedAt: date, elapsedDays: 1, scheduledDays: 1,
            stateBefore: .review, prevState: CardSchedulingSnapshot()
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    @discardableResult
    private func card(
        dueInDays: Int, state: SchedulingState = .review, suspended: Bool = false,
        in context: ModelContext, deck: Deck, row: Int
    ) throws -> Card {
        let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", sheetRow: row)
        context.insert(note)
        let made = try XCTUnwrap(context.syncCards(for: note, now: now).first)
        made.state = state
        made.due = calendar.date(byAdding: .day, value: dueInDays, to: now) ?? now
        made.isSuspended = suspended
        // A card that is not `.new` has been reviewed, and a review sets
        // `lastReview`. Keeping the fixture faithful to that matters here: the
        // stats queries key off `lastReview`, for reasons `StatsSummary`
        // explains and `testNewIsExactlyLastReviewNil` checks.
        made.lastReview = state == .new
            ? nil
            : calendar.date(byAdding: .day, value: -1, to: now)
        made.reps = state == .new ? 0 : 3
        try context.save()
        return made
    }

    // MARK: - Counts

    func testReviewsAreCountedInBothWindows() throws {
        let (context, deck) = try makeStore()
        for daysAgo in [0, 1, 3, 6, 9, 20, 29, 40] {
            try log(Grade.good.rawValue, daysAgo: daysAgo, in: context)
        }
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.reviewsLast7, 4, "0, 1, 3 and 6 days ago")
        XCTAssertEqual(summary.reviewsLast30, 7, "everything but the one 40 days back")
    }

    /// Rating 0 is an undo marker (§5.5), not a review. Counting it would inflate
    /// the streak and dilute retention.
    func testUndoMarkersAreNotReviews() throws {
        let (context, deck) = try makeStore()
        try log(Grade.good.rawValue, daysAgo: 0, in: context)
        try log(0, daysAgo: 0, in: context)
        try log(0, daysAgo: 1, in: context)
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.reviewsLast7, 1)
        XCTAssertEqual(summary.retention, 1.0)
        XCTAssertEqual(summary.streak, 1, "an undo on a day with no review is not a study day")
    }

    // MARK: - Retention

    /// §6.5: (Good + Easy) ÷ all, last 30 days.
    func testRetentionCountsGoodAndEasyOnly() throws {
        let (context, deck) = try makeStore()
        try log(Grade.good.rawValue, daysAgo: 1, in: context)
        try log(Grade.easy.rawValue, daysAgo: 1, in: context)
        try log(Grade.hard.rawValue, daysAgo: 1, in: context)
        try log(Grade.again.rawValue, daysAgo: 1, in: context)
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(try XCTUnwrap(summary.retention), 0.5, accuracy: 0.0001,
                       "Hard counts against, per §6.5")
    }

    func testRetentionIgnoresReviewsOlderThanThirtyDays() throws {
        let (context, deck) = try makeStore()
        try log(Grade.good.rawValue, daysAgo: 1, in: context)
        for _ in 0..<20 { try log(Grade.again.rawValue, daysAgo: 45, in: context) }
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertEqual(StatsSummary.load(from: context, now: now).retention, 1.0)
    }

    /// Telling someone with no history that they remember 0 % is telling them
    /// they are failing at something they have not started.
    func testRetentionIsUnknownRatherThanZeroWithNoHistory() throws {
        let (context, deck) = try makeStore()
        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertNil(summary.retention)
        XCTAssertFalse(summary.hasHistory)
        XCTAssertNotNil(context)
    }

    // MARK: - Forecast

    /// A three-week-old backlog is due *today*. Drawing it on its original date
    /// would put it off the left of the chart.
    func testOverdueCardsAllLandOnToday() throws {
        let (context, deck) = try makeStore()
        try card(dueInDays: -30, in: context, deck: deck, row: 1)
        try card(dueInDays: -1, in: context, deck: deck, row: 2)
        try card(dueInDays: 0, in: context, deck: deck, row: 3)

        let forecast = StatsSummary.forecast(in: context, now: now)
        XCTAssertEqual(forecast.count, 7)
        XCTAssertEqual(forecast[0].due, 3)
        XCTAssertEqual(forecast.dropFirst().map(\.due), [0, 0, 0, 0, 0, 0])
    }

    func testCardsBeyondTheWeekAreNotDrawn() throws {
        let (context, deck) = try makeStore()
        try card(dueInDays: 3, in: context, deck: deck, row: 1)
        try card(dueInDays: 6, in: context, deck: deck, row: 2)
        try card(dueInDays: 7, in: context, deck: deck, row: 3)
        try card(dueInDays: 90, in: context, deck: deck, row: 4)

        let forecast = StatsSummary.forecast(in: context, now: now)
        XCTAssertEqual(forecast.map(\.due), [0, 0, 0, 1, 0, 0, 1])
    }

    /// New cards have no due date worth forecasting, and a suspended card is not
    /// going to appear.
    func testSuspendedAndNewCardsAreNotForecast() throws {
        let (context, deck) = try makeStore()
        try card(dueInDays: 0, state: .new, in: context, deck: deck, row: 1)
        try card(dueInDays: 0, suspended: true, in: context, deck: deck, row: 2)
        try card(dueInDays: 0, in: context, deck: deck, row: 3)

        XCTAssertEqual(StatsSummary.forecast(in: context, now: now)[0].due, 1)
    }

    func testAnEmptyWeekStillDrawsSevenBars() throws {
        let (context, deck) = try makeStore()
        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.forecast.count, 7)
        XCTAssertEqual(summary.forecastPeak, 1, "the scale must never be zero")
        XCTAssertNotNil(context)
    }

    // MARK: - Per-deck counts

    func testDeckLinesSeparateNewFromDue() throws {
        let (context, deck) = try makeStore()
        try card(dueInDays: -1, in: context, deck: deck, row: 1)
        try card(dueInDays: -1, in: context, deck: deck, row: 2)
        try card(dueInDays: 5, in: context, deck: deck, row: 3)
        try card(dueInDays: 0, state: .new, in: context, deck: deck, row: 4)
        try card(dueInDays: -1, suspended: true, in: context, deck: deck, row: 5)

        let line = try XCTUnwrap(StatsSummary.deckLines(in: context, decks: [deck], now: now).first)
        XCTAssertEqual(line.total, 4, "a suspended card is not in the deck's working set")
        XCTAssertEqual(line.due, 2)
        XCTAssertEqual(line.newCards, 1)
    }

    func testDeletedDecksAndNotesAreExcludedEverywhere() throws {
        let (context, deck) = try makeStore()
        let live = try card(dueInDays: 0, in: context, deck: deck, row: 1)
        let gone = try card(dueInDays: 0, in: context, deck: deck, row: 2)
        gone.note.deletedAt = now
        try context.save()

        XCTAssertEqual(StatsSummary.forecast(in: context, now: now)[0].due, 1)
        XCTAssertEqual(StatsSummary.deckLines(in: context, decks: [deck], now: now).first?.total, 1)
        XCTAssertNotNil(live)

        // §4.3: a deck that disappears from the Sheet is soft-deleted *and* has
        // its cards suspended, which is why the queries do not need a second
        // clause for it.
        deck.deletedAt = now
        for note in deck.notes { for card in note.cards { card.isSuspended = true } }
        try context.save()
        XCTAssertEqual(StatsSummary.forecast(in: context, now: now)[0].due, 0)
        XCTAssertTrue(StatsSummary.deckLines(in: context, decks: [deck], now: now).isEmpty)
    }

    // MARK: - The invariant the queries rest on

    /// `StatsSummary` queries `lastReview == nil` because SwiftData refuses a
    /// predicate that captures a `SchedulingState`. That substitution is only
    /// safe if the two really are equivalent, so this drives the real rating
    /// path and checks it rather than trusting a comment.
    func testNewIsExactlyLastReviewNil() throws {
        let (context, deck) = try makeStore()
        let note = Note(deck: deck, front: "f", back: "b", sheetRow: 1)
        context.insert(note)
        let made = try XCTUnwrap(context.syncCards(for: note, now: now).first)
        try context.save()

        XCTAssertEqual(made.state, .new)
        XCTAssertNil(made.lastReview, "a card starts new and unreviewed")

        let scheduler = Scheduler()
        let log = try context.rate(made, .good, with: scheduler, now: now)
        XCTAssertNotEqual(made.state, .new)
        XCTAssertNotNil(made.lastReview, "the rating that leaves .new is the one that sets lastReview")

        // And undo restores both from the one snapshot, so they cannot part.
        made.restore(from: try log.decodedPrevState())
        XCTAssertEqual(made.state, .new)
        XCTAssertNil(made.lastReview)
    }

    // MARK: - Formatting

    func testUkrainianDayPlurals() {
        XCTAssertEqual(StatsSummary.dayCount(1, locale: Locale(identifier: "uk")), "1 день")
        XCTAssertEqual(StatsSummary.dayCount(2, locale: Locale(identifier: "uk")), "2 дні")
        XCTAssertEqual(StatsSummary.dayCount(5, locale: Locale(identifier: "uk")), "5 днів")
        XCTAssertEqual(StatsSummary.dayCount(11, locale: Locale(identifier: "uk")), "11 днів", "the teens are the exception")
        XCTAssertEqual(StatsSummary.dayCount(21, locale: Locale(identifier: "uk")), "21 день")
        XCTAssertEqual(StatsSummary.dayCount(112, locale: Locale(identifier: "uk")), "112 днів")
        XCTAssertEqual(StatsSummary.dayCount(0, locale: Locale(identifier: "uk")), "0 днів")
    }

    func testPercentRounds() {
        XCTAssertEqual(StatsSummary.percent(0.9049), "90 %")
        XCTAssertEqual(StatsSummary.percent(1), "100 %")
    }

    // MARK: - The acceptance criterion

    /// §6.5: "renders in under 300 ms with 10k cards". Measured on the
    /// computation, which is the part that scales — the view draws a fixed
    /// number of bars and rows however many cards there are.
    func testTenThousandCardsComputeWellUnderTheBudget() throws {
        let (context, deck) = try makeStore()
        for row in 0..<10_000 {
            let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", sheetRow: row)
            context.insert(note)
            let made = try XCTUnwrap(context.syncCards(for: note, now: now).first)
            made.state = .review
            made.due = calendar.date(byAdding: .day, value: row % 30 - 5, to: now) ?? now
            made.lastReview = now
            made.reps = 3
        }
        for index in 0..<2_000 {
            context.insert(try ReviewLog(
                cardId: "c\(index)", direction: .forward, rating: Grade.good.rawValue,
                reviewedAt: calendar.date(byAdding: .day, value: -(index % 40), to: now) ?? now,
                elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                prevState: CardSchedulingSnapshot()
            ))
        }
        try context.save()

        let started = Date()
        let summary = StatsSummary.load(from: context, now: now)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(summary.decks.first?.total, 10_000)
        XCTAssertLessThan(elapsed, 0.3, "§6.5 asks for under 300 ms with 10k cards")
    }
}
