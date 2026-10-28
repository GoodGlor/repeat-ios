import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #5 acceptance (§5.2).
final class QueueBuilderTests: XCTestCase {

    /// Seeded so "randomised within the same day" is still assertable.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    @discardableResult
    private func addCard(
        _ ctx: ModelContext, to deck: Deck, row: Int,
        state: SchedulingState = .new, due: Date? = nil,
        suspended: Bool = false, reverse: Bool = false
    ) -> [Card] {
        let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", reverse: reverse, sheetRow: row)
        ctx.insert(note)
        let cards = ctx.syncCards(for: note, now: due ?? now)
        for card in cards {
            card.state = state
            card.due = due ?? now
            card.isSuspended = suspended
            if state != .new { card.reps = 3; card.stability = 10; card.lastReview = due }
        }
        return cards
    }

    private func plan(
        _ decks: [Deck], config: QueueConfig = QueueConfig(),
        recentLogs: [ReviewLog] = [], logsToday: [ReviewLog] = [], at when: Date? = nil, seed: UInt64 = 42
    ) -> QueuePlan {
        var rng = SeededGenerator(seed: seed)
        return QueueBuilder.plan(
            decks: decks, now: when ?? now, config: config,
            recentLogs: recentLogs, logsToday: logsToday, calendar: calendar, using: &rng
        )
    }

    // MARK: - Composition and order

    func testDueReviewsComeBeforeNewCardsAndOldestDayFirst() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)

        let old = addCard(ctx, to: deck, row: 0, state: .review, due: now.addingTimeInterval(-3 * 86_400))
        let recent = addCard(ctx, to: deck, row: 1, state: .review, due: now.addingTimeInterval(-1 * 86_400))
        let fresh = addCard(ctx, to: deck, row: 2)

        let result = plan([deck])
        XCTAssertEqual(result.cardIds, [old[0].id, recent[0].id, fresh[0].id])
        XCTAssertEqual(result.dueReviewCount, 2)
        XCTAssertEqual(result.newCardCount, 1)
    }

    func testCardsDueLaterTodayAreNotInTheQueue() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0, state: .review, due: now.addingTimeInterval(3600))
        XCTAssertTrue(plan([deck]).isEmpty, "not owed yet — it comes back through StudyQueue")
    }

    func testLearningCardsWhoseTimerExpiredAreDue() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        let card = addCard(ctx, to: deck, row: 0, state: .learning, due: now.addingTimeInterval(-60))
        XCTAssertEqual(plan([deck]).cardIds, [card[0].id])
    }

    func testSuspendedCardsNeverAppear() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0, state: .review, due: now.addingTimeInterval(-86_400), suspended: true)
        addCard(ctx, to: deck, row: 1, suspended: true)
        XCTAssertTrue(plan([deck]).isEmpty)
    }

    func testSoftDeletedDecksAndNotesAreExcluded() throws {
        let ctx = try makeContext()
        let live = Deck(sheetTitle: "Live", sheetId: 1); ctx.insert(live)
        let gone = Deck(sheetTitle: "Gone", sheetId: 2); ctx.insert(gone); gone.deletedAt = now
        addCard(ctx, to: gone, row: 0)
        let deleted = addCard(ctx, to: live, row: 0)
        deleted[0].note.deletedAt = now
        let kept = addCard(ctx, to: live, row: 1)
        XCTAssertEqual(plan([live, gone]).cardIds, [kept[0].id])
    }

    func testNewCardsFollowSheetRowOrderNotInsertionOrder() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        let third = addCard(ctx, to: deck, row: 9)
        let first = addCard(ctx, to: deck, row: 1)
        let second = addCard(ctx, to: deck, row: 4)
        XCTAssertEqual(plan([deck]).cardIds, [first[0].id, second[0].id, third[0].id])
    }

    func testBothDirectionsOfAReverseNoteAreOfferedForwardFirst() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0, reverse: true)
        let ids = plan([deck]).cardIds
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids[0].hasSuffix("#fwd"))
        XCTAssertTrue(ids[1].hasSuffix("#rev"))
    }

    /// Same-day order is shuffled, but between-day order is not — the
    /// longest-overdue material must still come first.
    func testSameDayDueCardsAreShuffledWhileDayOrderIsPreserved() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        let dayOne = now.addingTimeInterval(-2 * 86_400)
        let dayTwo = now.addingTimeInterval(-1 * 86_400)
        var early: Set<String> = [], late: Set<String> = []
        for row in 0..<6 {
            let due = row < 3 ? dayOne.addingTimeInterval(Double(row)) : dayTwo.addingTimeInterval(Double(row))
            let card = addCard(ctx, to: deck, row: row, state: .review, due: due)
            if row < 3 { early.insert(card[0].id) } else { late.insert(card[0].id) }
        }

        let a = plan([deck], seed: 1).cardIds
        let b = plan([deck], seed: 99).cardIds
        XCTAssertEqual(Set(a.prefix(3)), early, "day 1 stays ahead of day 2")
        XCTAssertEqual(Set(a.suffix(3)), late)
        XCTAssertNotEqual(a, b, "within a day the order varies")
    }

    // MARK: - New-card caps

    func testPerDeckNewCardCapIsRespected() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 3); ctx.insert(deck)
        for row in 0..<10 { addCard(ctx, to: deck, row: row) }
        XCTAssertEqual(plan([deck]).newCardCount, 3)
    }

    func testGlobalCapIsAppliedOnTopOfPerDeckCaps() throws {
        let ctx = try makeContext()
        var decks: [Deck] = []
        for index in 0..<4 {
            let deck = Deck(sheetTitle: "Deck \(index)", sheetId: index, newCardsPerDay: 15, sortOrder: index)
            ctx.insert(deck)
            for row in 0..<15 { addCard(ctx, to: deck, row: row) }
            decks.append(deck)
        }
        let result = plan(decks, config: QueueConfig(globalNewCardCap: 30))
        XCTAssertEqual(result.newCardCount, 30, "60 allowed per-deck, 30 allowed overall")
    }

    /// The ceiling is a *day's* ceiling, not a build's. Home rebuilds the plan on
    /// appear, on foreground and after every sync; each build used to start the
    /// count at zero, so once the first thirty were studied the next build handed
    /// out thirty more from the decks not yet touched — sixty in a day against a
    /// setting that says thirty.
    func testTheGlobalCapCountsWhatTheDayAlreadyIntroduced() throws {
        let ctx = try makeContext()
        var decks: [Deck] = []
        var cards: [Card] = []
        for index in 0..<4 {
            let deck = Deck(sheetTitle: "Deck \(index)", sheetId: index, newCardsPerDay: 15, sortOrder: index)
            ctx.insert(deck)
            for row in 0..<15 { cards += addCard(ctx, to: deck, row: row) }
            decks.append(deck)
        }
        let config = QueueConfig(globalNewCardCap: 30)
        let first = plan(decks, config: config)
        XCTAssertEqual(first.newCardCount, 30)

        // Study them all: each leaves `.new` and writes its log row.
        var logs: [ReviewLog] = []
        for card in cards where first.cardIds.contains(card.id) {
            card.state = .learning
            card.lastReview = now
            card.due = now.addingTimeInterval(600)
            logs.append(try ReviewLog(
                cardId: card.id, direction: .forward, rating: 3, reviewedAt: now,
                elapsedDays: 0, scheduledDays: 0, stateBefore: .new, prevState: CardSchedulingSnapshot()))
        }

        let second = plan(decks, config: config, logsToday: logs)
        XCTAssertEqual(second.newCardCount, 0, "the day's thirty are spent")

        // And a partial day leaves exactly the remainder.
        let third = plan(decks, config: config, logsToday: Array(logs.prefix(25)))
        XCTAssertEqual(third.newCardCount, 5)
    }

    /// The ceiling is a maximum, never a target: it cannot hand out cards a deck
    /// has not allowed. Raising the app-wide setting to 30 while the only deck
    /// still says 15 is the shape of the bug that sent someone looking for a
    /// second stepper they could not find, so it is pinned rather than assumed.
    func testTheGlobalCeilingDoesNotRaiseADeckBelowIt() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 15); ctx.insert(deck)
        for row in 0..<40 { addCard(ctx, to: deck, row: row) }

        XCTAssertEqual(plan([deck], config: QueueConfig(globalNewCardCap: 30)).newCardCount, 15,
                       "the deck's own allowance is the binding one")

        deck.newCardsPerDay = 30
        XCTAssertEqual(plan([deck], config: QueueConfig(globalNewCardCap: 30)).newCardCount, 30,
                       "and raising it is what actually changes the day")
    }

    /// A card that is no longer `.new` looks identical whether it was introduced
    /// today or last month, so this can only come from the log.
    func testNewCardsAlreadyIntroducedTodayReduceTodaysAllowance() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 5); ctx.insert(deck)
        var introduced: [ReviewLog] = []
        for row in 0..<10 {
            let card = addCard(ctx, to: deck, row: row)[0]
            if row < 2 {
                card.state = .learning
                card.due = now.addingTimeInterval(3600)
                introduced.append(try ReviewLog(
                    cardId: card.id, direction: .forward, rating: 3, reviewedAt: now,
                    elapsedDays: 0, scheduledDays: 0, stateBefore: .new, prevState: CardSchedulingSnapshot()
                ))
            }
        }
        XCTAssertEqual(plan([deck], logsToday: introduced).newCardCount, 3, "5 per day minus 2 already introduced")
        XCTAssertEqual(plan([deck]).newCardCount, 5, "with no log of today, the full allowance stands")
    }

    // MARK: - The invariant #84's queries rest on

    /// #84 selects due reviews with `lastReview != nil`, because SwiftData refuses
    /// a predicate that captures a `SchedulingState` at all.
    ///
    /// `StatsTests` already pins the substitution at the model level. This pins it
    /// where it now decides *what you are shown*: a card rated through the real
    /// path must turn up in the next queue as a review, not vanish from it.
    func testACardRatedThroughTheRealPathIsFoundAsADueReview() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 5)
        ctx.insert(deck)
        let card = addCard(ctx, to: deck, row: 0)[0]
        try ctx.save()

        XCTAssertEqual(plan([deck]).newCardCount, 1, "it starts out new")

        // Rate it, then bring its due date back so it is owed again.
        _ = try ctx.rate(card, .good, with: Scheduler(), now: now)
        card.due = now.addingTimeInterval(-60)
        try ctx.save()

        let after = plan([deck])
        XCTAssertEqual(after.dueReviewCount, 1, "the rated card is now a due review")
        XCTAssertEqual(after.newCardCount, 0, "and is no longer offered as new")
        XCTAssertEqual(after.cardIds, [card.id])
    }

    /// The safety net, tested against data the app cannot produce.
    ///
    /// If `lastReview` and `state` ever did part company, the damaging direction is
    /// this one: a card partway through its learning steps handed back as if it had
    /// never been seen, resetting real scheduling state. `QueueBuilder` therefore
    /// treats the predicate as a filter and `state` as the authority, and this is
    /// the test that says so — it fails if that second check is ever removed as
    /// redundant.
    func testALearningCardIsNeverOfferedAsNewEvenIfItsLastReviewIsMissing() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 5)
        ctx.insert(deck)
        let card = addCard(ctx, to: deck, row: 0)[0]
        card.state = .learning
        card.lastReview = nil          // impossible in production; the point of the test
        card.due = now.addingTimeInterval(3600)
        try ctx.save()

        let result = plan([deck])
        XCTAssertEqual(result.newCardCount, 0,
                       "a learning card must not be handed back as new")
        XCTAssertTrue(result.cardIds.isEmpty)
    }

    // MARK: - Estimate

    func testEstimateUsesMeasuredGapsAndIgnoresBreaks() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0, state: .review, due: now.addingTimeInterval(-86_400))

        var logs: [ReviewLog] = []
        var at = now.addingTimeInterval(-7200)
        for index in 0..<10 {
            // A four-hour gap after the fifth review is a break, not a card.
            at = at.addingTimeInterval(index == 5 ? 14_400 : 10)
            logs.append(try ReviewLog(cardId: "c\(index)", direction: .forward, rating: 3, reviewedAt: at,
                                      elapsedDays: 0, scheduledDays: 1, stateBefore: .review,
                                      prevState: CardSchedulingSnapshot()))
        }
        XCTAssertEqual(QueueBuilder.secondsPerCard(from: logs), 10, accuracy: 0.01)
    }

    func testEstimateFallsBackToTwentySecondsWithoutEnoughData() throws {
        XCTAssertEqual(QueueBuilder.secondsPerCard(from: []), 20)
        let single = try ReviewLog(cardId: "c", direction: .forward, rating: 3, reviewedAt: now,
                                   elapsedDays: 0, scheduledDays: 1, stateBefore: .review,
                                   prevState: CardSchedulingSnapshot())
        XCTAssertEqual(QueueBuilder.secondsPerCard(from: [single]), 20)
    }

    func testUndoMarkersAreNotCountedAsReviews() throws {
        let undo = try ReviewLog(cardId: "c", direction: .forward, rating: 0, reviewedAt: now,
                                 elapsedDays: 0, scheduledDays: 0, stateBefore: .review,
                                 prevState: CardSchedulingSnapshot())
        let real = try ReviewLog(cardId: "c", direction: .forward, rating: 3, reviewedAt: now,
                                 elapsedDays: 0, scheduledDays: 1, stateBefore: .review,
                                 prevState: CardSchedulingSnapshot())
        XCTAssertEqual(QueueBuilder.secondsPerCard(from: [undo, real]), 20, "one real review is not two")
    }

    func testEstimatedMinutesRoundsUpFromZero() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0)
        let result = plan([deck])
        XCTAssertEqual(result.estimatedSeconds, 20)
        XCTAssertEqual(result.estimatedMinutes, 1, "one card is 'about a minute', never 'zero minutes'")
    }

    // MARK: - Day rollover

    func testAPlanFromYesterdayIsStale() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1); ctx.insert(deck)
        addCard(ctx, to: deck, row: 0)
        let result = plan([deck])
        XCTAssertFalse(result.isStale(at: now.addingTimeInterval(3600), calendar: calendar))
        XCTAssertTrue(result.isStale(at: now.addingTimeInterval(86_400), calendar: calendar))
    }
}
