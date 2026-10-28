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

    // MARK: - Records and the year

    /// One fetch feeds the streak, the records and the grid; the undo-marker
    /// filter is applied once, so none of them can disagree about a day.
    func testRecordsAndTheHeatmapComeFromTheSameLogsAndSkipUndoMarkers() throws {
        let (context, _) = try makeStore()
        try log(Grade.good.rawValue, daysAgo: 0, in: context)
        try log(Grade.good.rawValue, daysAgo: 0, in: context)
        try log(Grade.again.rawValue, daysAgo: 1, in: context)
        try log(0, daysAgo: 2, in: context)   // an undo marker on an otherwise empty day

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.records.longestStreak, 2, "today and yesterday; the marker's day does not count")
        XCTAssertEqual(summary.records.bestDay?.count, 2)
        XCTAssertEqual(summary.records.bestDay?.start, calendar.startOfDay(for: now))
        XCTAssertEqual(summary.heatmap.totalReviews, 3)
        XCTAssertEqual(summary.heatmap.activeDays, 2)
    }

    /// A five-week break used to turn a year of history into "Ще немає даних":
    /// the gate looked only at the last 30 days, and the year and the records
    /// now sit behind it.
    func testHistoryOlderThanTheWindowStillCountsAsHistory() throws {
        let (context, _) = try makeStore()
        try log(Grade.good.rawValue, daysAgo: 45, in: context)
        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.reviewsLast30, 0)
        XCTAssertEqual(summary.streak, 0)
        XCTAssertTrue(summary.hasHistory, "one review 45 days ago is history")
        XCTAssertEqual(summary.records.bestDay?.count, 1)
    }

    func testUkrainianCardPlurals() {
        let uk = Locale(identifier: "uk")
        XCTAssertEqual(StatsSummary.cardCount(1, locale: uk), "1 картка")
        XCTAssertEqual(StatsSummary.cardCount(3, locale: uk), "3 картки")
        XCTAssertEqual(StatsSummary.cardCount(10, locale: uk), "10 карток")
        XCTAssertEqual(StatsSummary.cardCount(70, locale: uk), "70 карток")
        XCTAssertEqual(StatsSummary.cardCount(201, locale: uk), "201 картка", "21, 31, 201 take the singular")
    }

    /// The exact text is the locale's; what is pinned is that both ends of the
    /// week are named. The fixture week (9–15 March 2026) shares no digit with
    /// its year, so a shifted week or an off-by-one Sunday cannot pass by
    /// accident — "2027" used to satisfy `contains("7")` on its own.
    func testAWeekSpanNamesMondayAndSunday() {
        let current = Calendar.current
        let monday = current.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        XCTAssertEqual(current.component(.weekday, from: monday), 2, "9 March 2026 is a Monday")
        let text = StatsSummary.weekSpan(from: monday, calendar: current)
        XCTAssertTrue(text.contains("9"), text)
        XCTAssertTrue(text.contains("15"), text)
        XCTAssertFalse(text.contains("16"), "the span ends on Sunday, not the next Monday: \(text)")
    }

    // MARK: - #106: learned this month

    func testTheWordsLearnedThisMonthReachTheSummary() throws {
        let (context, deck) = try makeStore()
        let made = try card(dueInDays: 20, in: context, deck: deck, row: 1)
        made.stability = 30
        let crossed = calendar.date(byAdding: .day, value: -10, to: now) ?? now
        let log = try ReviewLog(
            cardId: made.id, direction: .forward, rating: Grade.good.rawValue, reviewedAt: crossed,
            elapsedDays: 5, scheduledDays: 30, stateBefore: .review,
            prevState: CardSchedulingSnapshot(state: .review, stability: 10, lastReview: crossed)
        )
        context.insert(log)
        try context.save()

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertEqual(summary.learnedThisMonth.map(\.front), ["f1"])
        XCTAssertEqual(summary.learnedThisMonth.first?.learnedAt, crossed)
    }

    func testAMatureCardWithNoCrossingInTheLogIsNotAWordLearnedThisMonth() throws {
        // The backlog seed's shape: stable cards, and a log that never mentions
        // them. History, but nothing this list can honestly claim.
        let (context, deck) = try makeStore()
        let made = try card(dueInDays: 20, in: context, deck: deck, row: 1)
        made.stability = 60
        try log(Grade.good.rawValue, daysAgo: 1, in: context)

        let summary = StatsSummary.load(from: context, now: now)
        XCTAssertTrue(summary.hasHistory)
        XCTAssertEqual(summary.learnedThisMonth, [])
    }

    // MARK: - §5.4: the grid is the ledger

    func testTheGridListsTheWholeCatalogueWithTheLedgersDates() throws {
        let (context, _) = try makeStore()
        try log(3, daysAgo: 1, in: context)   // some history, so the section would show
        let name = "StatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let ledger = AchievementLedger(defaults: defaults)
        let earned = calendar.date(byAdding: .day, value: -3, to: now)!
        ledger.markShown([.firstSession, .reviews100], on: earned)

        let summary = StatsSummary.load(from: context, now: now, calendar: calendar, ledger: ledger)

        XCTAssertEqual(summary.achievements.map(\.badge), Achievements.Badge.allCases, "every badge, catalogue order")
        XCTAssertEqual(summary.achievements.first { $0.badge == .firstSession }?.earnedOn, earned)
        XCTAssertNil(summary.achievements.first { $0.badge == .streak7 }?.earnedOn)
        XCTAssertEqual(summary.earnedCount, 2)
    }

    // MARK: - The acceptance criterion

    /// §6.5: "renders in under 300 ms with 10k cards". Measured on the
    /// computation, which is the part that scales — the view draws a fixed
    /// number of bars and rows however many cards there are.
    /// #136 folded `reviewsLast7`, `reviewsLast30` and `retention` into one walk
    /// of the log, and left the three single-question functions in place because
    /// the tests drive them directly and they read clearly. That is only honest
    /// while the two agree, which is what this asserts — including the cases where
    /// a hand-merged loop goes wrong: an undo marker, a review exactly on the
    /// boundary, and a window with nothing in it.
    func testTheCombinedWalkAgreesWithTheThreeSeparateOnes() throws {
        let (context, _) = try makeStore()
        func log(_ rating: Int, daysAgo: Int) throws {
            context.insert(try ReviewLog(
                cardId: "c-\(daysAgo)-\(rating)-\(UUID().uuidString)", direction: .forward,
                rating: rating,
                reviewedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now,
                elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                prevState: CardSchedulingSnapshot()))
        }

        // Empty first: retention has no answer, and both must say so.
        let empty = StatsSummary.window([], now: now, calendar: calendar)
        XCTAssertEqual(empty.last7, StatsSummary.countReviews([], days: 7, now: now, calendar: calendar))
        XCTAssertNil(empty.retention)
        XCTAssertNil(StatsSummary.retention([], now: now, calendar: calendar))

        try log(Grade.good.rawValue, daysAgo: 0)
        try log(Grade.again.rawValue, daysAgo: 3)
        try log(Grade.easy.rawValue, daysAgo: 7)      // exactly on the 7-day edge
        try log(Grade.hard.rawValue, daysAgo: 29)
        try log(Grade.good.rawValue, daysAgo: 30)     // exactly on the 30-day edge
        try log(Grade.good.rawValue, daysAgo: 45)     // outside both
        try log(0, daysAgo: 1)                        // an undo marker, never a review
        try context.save()

        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
        let combined = StatsSummary.window(logs, now: now, calendar: calendar)

        XCTAssertEqual(combined.last7,
                       StatsSummary.countReviews(logs, days: 7, now: now, calendar: calendar))
        XCTAssertEqual(combined.last30,
                       StatsSummary.countReviews(logs, days: StatsSummary.retentionWindowDays,
                                                 now: now, calendar: calendar))
        XCTAssertEqual(combined.retention,
                       StatsSummary.retention(logs, now: now, calendar: calendar))
        XCTAssertNotNil(combined.retention, "the fixture has reviews in the window")
    }

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

            // #106: a heavy but realistic month. Every third card is known
            // (3,334 cards); of those, 200 crossed this month with one real
            // log each, about 1,470 crossed long ago and were reviewed again
            // since (two logs to decode before `becameKnown` gives up on this
            // month), and the rest have no log at all — `becameKnown` returns
            // nil at no cost.
            if row % 50 == 0 {
                made.stability = 30
                context.insert(try ReviewLog(
                    cardId: made.id, direction: made.direction, rating: Grade.good.rawValue,
                    reviewedAt: calendar.date(byAdding: .day, value: -5, to: now) ?? now,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(state: .review, stability: 10,
                                                      lastReview: calendar.date(byAdding: .day, value: -6, to: now) ?? now),
                    uploaded: true
                ))
            } else if row % 6 == 0 {
                made.stability = 30
                context.insert(try ReviewLog(
                    cardId: made.id, direction: made.direction, rating: Grade.good.rawValue,
                    reviewedAt: calendar.date(byAdding: .day, value: -60, to: now) ?? now,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(state: .review, stability: 10,
                                                      lastReview: calendar.date(byAdding: .day, value: -61, to: now) ?? now),
                    uploaded: true
                ))
                context.insert(try ReviewLog(
                    cardId: made.id, direction: made.direction, rating: Grade.good.rawValue,
                    reviewedAt: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(state: .review, stability: 25,
                                                      lastReview: calendar.date(byAdding: .day, value: -4, to: now) ?? now),
                    uploaded: true
                ))
            } else if row % 3 == 0 {
                made.stability = 30
            }
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
        XCTAssertEqual(summary.learnedThisMonth.count, 200, "the fixture's 200 crossings this month")
        print("MEASURED stats load, 10k cards, 200 words this month: \(String(format: "%.3f", elapsed))s (budget 0.300s)")
    }
}
