import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #9. Two jobs: prove every acceptance line in the scheduling cards is
/// covered, and close the gaps that writing each card in isolation left.
///
/// **Coverage map — acceptance line → test**
///
/// #4 FSRS wrapper
/// - preview matches applied scheduling … `SchedulerTests.testPreviewMatchesWhatApplyingActuallySchedules`
/// - custom `fsrs_params` change intervals … `SchedulerTests.testCustomWeightsChangeIntervalsWithoutARebuild`
/// - new → learning → review follows the steps … `SchedulerTests.testNewCardEntersTheConfiguredLearningSteps`,
///   `testGoodOnTheLastLearningStepGraduatesToReview`, `TransitionMatrixTests.testEveryStateAndGradeCombinationLandsInALegalState`
///
/// #5 Queue builder
/// - right cards in the right order … `QueueBuilderTests.testDueReviewsComeBeforeNewCardsAndOldestDayFirst`
/// - per-deck and global caps … `testPerDeckNewCardCapIsRespected`, `testGlobalCapIsAppliedOnTopOfPerDeckCaps`,
///   and `testTheNewCardCapNeverWithholdsADueReview` below
/// - day rollover … `QueueBuilderTests.testAPlanFromYesterdayIsStale`
/// - suspended excluded … `QueueBuilderTests.testSuspendedCardsNeverAppear`
///
/// #7 Undo
/// - restores every field exactly … `UndoTests.testUndoRestoresEverySchedulingFieldExactly`,
///   `TransitionMatrixTests.testSnapshotRoundTripsThroughItsEncodedForm`
/// - one `rating=0` row for an uploaded review … `UndoTests.testUndoOfAnUploadedReviewAppendsExactlyOneUndoMarker`
final class SchedulingAcceptanceTests: XCTestCase {

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
    private func addNote(
        _ ctx: ModelContext, to deck: Deck, row: Int,
        state: SchedulingState = .new, due: Date? = nil, suspended: Bool = false
    ) -> [Card] {
        let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", sheetRow: row)
        ctx.insert(note)
        let cards = ctx.syncCards(for: note, now: due ?? now)
        for card in cards {
            card.state = state
            card.due = due ?? now
            card.isSuspended = suspended
            if state != .new {
                card.reps = 4; card.stability = 12; card.difficulty = 5
                card.scheduledDays = 12; card.lastReview = (due ?? now).addingTimeInterval(-12 * 86_400)
            }
        }
        return cards
    }

    private func plan(_ decks: [Deck], config: QueueConfig = QueueConfig()) -> QueuePlan {
        var generator = SystemRandomNumberGenerator()
        return QueueBuilder.plan(decks: decks, now: now, config: config, calendar: calendar, using: &generator)
    }

    // MARK: - Gaps the per-card tests left

    /// The caps in §5.2 govern how much *new* material is introduced. Applying
    /// them to due reviews would quietly stop showing cards that are already owed
    /// — the cards the whole app exists to show.
    func testTheNewCardCapNeverWithholdsADueReview() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 2)
        ctx.insert(deck)
        for row in 0..<40 {
            addNote(ctx, to: deck, row: row, state: .review, due: now.addingTimeInterval(-86_400))
        }
        for row in 40..<50 { addNote(ctx, to: deck, row: row) }

        let result = plan([deck], config: QueueConfig(globalNewCardCap: 5))
        XCTAssertEqual(result.dueReviewCount, 40, "every owed review is offered")
        XCTAssertEqual(result.newCardCount, 2, "new material stays capped")
        XCTAssertEqual(result.count, 42)
    }

    func testADeckThatIntroducesNoNewCardsStillOffersItsReviews() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Paused", sheetId: 1, newCardsPerDay: 0)
        ctx.insert(deck)
        addNote(ctx, to: deck, row: 0, state: .review, due: now.addingTimeInterval(-86_400))
        addNote(ctx, to: deck, row: 1)

        let result = plan([deck])
        XCTAssertEqual(result.newCardCount, 0)
        XCTAssertEqual(result.dueReviewCount, 1)
    }

    func testAnEmptyStoreProducesAnEmptyPlanRatherThanFailing() throws {
        XCTAssertTrue(plan([]).isEmpty)
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Empty", sheetId: 1)
        ctx.insert(deck)
        XCTAssertTrue(plan([deck]).isEmpty)
    }

    func testADeckWhereEverythingIsSuspendedContributesNothing() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1)
        ctx.insert(deck)
        for row in 0..<5 {
            addNote(ctx, to: deck, row: row, state: .review,
                    due: now.addingTimeInterval(-86_400), suspended: true)
        }
        let result = plan([deck])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.estimatedSeconds, 0)
    }

    /// Every planned card is shown exactly once when nothing is failed — no card
    /// silently skipped, none shown twice.
    func testASessionShowsEveryPlannedCardExactlyOnce() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 50)
        ctx.insert(deck)
        for row in 0..<12 {
            addNote(ctx, to: deck, row: row, state: row < 6 ? .review : .new,
                    due: row < 6 ? now.addingTimeInterval(-86_400) : now)
        }
        try ctx.save()

        let queuePlan = plan([deck])
        let session = StudySession(context: ctx, plan: queuePlan, decks: [deck])

        var shown: [String] = []
        var iterations = 0
        while let card = session.current, iterations < 100 {
            iterations += 1
            shown.append(card.id)
            session.reveal(now: now)
            session.rate(.easy, now: now)
        }

        XCTAssertEqual(shown.count, queuePlan.count)
        XCTAssertEqual(Set(shown), Set(queuePlan.cardIds))
        XCTAssertEqual(Set(shown).count, shown.count, "no card shown twice")
        XCTAssertEqual(session.summary?.reviewed, queuePlan.count)
    }

    /// A card failed repeatedly must not be able to keep a session alive forever.
    func testAFailedCardConvergesRatherThanLoopingForever() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 5)
        ctx.insert(deck)
        addNote(ctx, to: deck, row: 0)
        try ctx.save()

        let session = StudySession(context: ctx, plan: plan([deck]), decks: [deck])
        var iterations = 0
        while session.summary == nil, iterations < 40 {
            iterations += 1
            if session.current == nil {
                guard let until = session.waitingUntil else { break }
                session.refresh(now: until)
                continue
            }
            let at = session.current?.due ?? now
            session.reveal(now: at)
            // Fail three times, then pass — the card must leave the session.
            session.rate(iterations <= 3 ? .again : .easy, now: at)
        }
        XCTAssertNotNil(session.summary, "the session ended")
        XCTAssertLessThan(iterations, 40)
    }

    // MARK: - The log is a faithful record

    /// `_log` feeds the FSRS optimizer and #41's replay, so each row has to
    /// describe the review that actually happened.
    func testEveryLogRowMatchesTheReviewItRecords() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 10)
        ctx.insert(deck)
        for row in 0..<4 {
            addNote(ctx, to: deck, row: row, state: .review, due: now.addingTimeInterval(-86_400))
        }
        try ctx.save()

        let session = StudySession(context: ctx, plan: plan([deck]), decks: [deck])
        let grades: [Grade] = [.good, .hard, .easy, .good]
        var stateBefore: [String: SchedulingState] = [:]
        for grade in grades {
            guard let card = session.current else { break }
            stateBefore[card.id] = card.state
            session.reveal(now: now)
            session.rate(grade, now: now)
        }

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.count, 4)
        for log in logs {
            XCTAssertNotNil(Grade(rawValue: log.rating), "rating \(log.rating) is not a grade")
            XCTAssertEqual(log.reviewedAt, now)
            XCTAssertFalse(log.uploaded)
            XCTAssertEqual(log.stateBefore, stateBefore[log.cardId])
            XCTAssertNoThrow(try log.decodedPrevState())
            XCTAssertEqual(try log.decodedPrevState().state, log.stateBefore,
                           "the snapshot and the recorded prior state must agree")
        }
    }
}
