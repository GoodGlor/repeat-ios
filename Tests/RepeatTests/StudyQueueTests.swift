import XCTest
import Scheduling
@testable import Repeat

/// The live half of §5.2: same-day repeats stay in the session, cards due later
/// today do not.
final class StudyQueueTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeQueue(_ ids: [String]) -> StudyQueue {
        StudyQueue(plan: QueuePlan(
            cardIds: ids, dueReviewCount: ids.count, newCardCount: 0,
            secondsPerCard: 20, studyDay: Calendar.current.startOfDay(for: now)
        ))
    }

    func testCardsAreServedInPlanOrder() {
        let queue = makeQueue(["a", "b", "c"])
        XCTAssertEqual(queue.next(now: now), "a")
        queue.recordAnswer(cardId: "a", resultingState: .review, nextDue: now.addingTimeInterval(86_400), now: now)
        XCTAssertEqual(queue.next(now: now), "b")
        XCTAssertEqual(queue.completedCount, 1)
    }

    func testAGraduatedCardLeavesTheSession() {
        let queue = makeQueue(["a"])
        queue.recordAnswer(cardId: "a", resultingState: .review, nextDue: now.addingTimeInterval(3 * 86_400), now: now)
        XCTAssertNil(queue.next(now: now))
        XCTAssertTrue(queue.isFinished)
    }

    func testALearningCardComesBackWhenItsTimerExpires() {
        let queue = makeQueue(["a", "b"])
        let readyAt = now.addingTimeInterval(600)
        queue.recordAnswer(cardId: "a", resultingState: .learning, nextDue: readyAt, now: now)

        XCTAssertEqual(queue.next(now: now), "b", "not yet — 10 minutes out")
        XCTAssertFalse(queue.isFinished)
        XCTAssertEqual(queue.nextAvailableAt(), readyAt)

        queue.recordAnswer(cardId: "b", resultingState: .review, nextDue: now.addingTimeInterval(86_400), now: now)
        XCTAssertNil(queue.next(now: now), "nothing to show yet, but the session is not over")
        XCTAssertFalse(queue.isFinished)

        XCTAssertEqual(queue.next(now: readyAt), "a", "timer expired — back to the front")
    }

    /// A learning card scheduled past midnight is tomorrow's problem, not a
    /// same-day repeat.
    func testALearningCardDueTomorrowDoesNotStayInTheSession() {
        let queue = makeQueue(["a"])
        queue.recordAnswer(cardId: "a", resultingState: .learning, nextDue: now.addingTimeInterval(86_400), now: now)
        XCTAssertTrue(queue.isFinished)
        XCTAssertNil(queue.nextAvailableAt())
    }

    func testRelearningCardsAlsoComeBack() {
        let queue = makeQueue(["a"])
        let readyAt = now.addingTimeInterval(600)
        queue.recordAnswer(cardId: "a", resultingState: .relearning, nextDue: readyAt, now: now)
        XCTAssertFalse(queue.isFinished)
        XCTAssertEqual(queue.next(now: readyAt), "a")
    }

    /// The progress bar counts the plan, so re-shown learning cards must not make
    /// it move backwards or exceed its total (§6.3).
    func testProgressCountsThePlanNotRepeats() {
        let queue = makeQueue(["a", "b"])
        XCTAssertEqual(queue.total, 2)
        let readyAt = now.addingTimeInterval(60)
        queue.recordAnswer(cardId: "a", resultingState: .learning, nextDue: readyAt, now: now)
        XCTAssertEqual(queue.completedCount, 1)
        queue.recordAnswer(cardId: "a", resultingState: .review, nextDue: now.addingTimeInterval(86_400), now: readyAt)
        XCTAssertEqual(queue.completedCount, 1, "answering the same card twice is still one card done")
        XCTAssertLessThanOrEqual(queue.completedCount, queue.total)
    }

    func testUndoPutsTheCardBackAtTheFront() {
        let queue = makeQueue(["a", "b"])
        queue.recordAnswer(cardId: "a", resultingState: .review, nextDue: now.addingTimeInterval(86_400), now: now)
        XCTAssertEqual(queue.next(now: now), "b")

        queue.reinsertAtFront(cardId: "a")
        XCTAssertEqual(queue.next(now: now), "a")
        XCTAssertEqual(queue.completedCount, 0)
    }

    func testUndoOfALearningCardRemovesItFromTheWaitingSet() {
        let queue = makeQueue(["a"])
        queue.recordAnswer(cardId: "a", resultingState: .learning, nextDue: now.addingTimeInterval(600), now: now)
        queue.reinsertAtFront(cardId: "a")
        XCTAssertNil(queue.nextAvailableAt())
        XCTAssertEqual(queue.next(now: now), "a")
    }
}
