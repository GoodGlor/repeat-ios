import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #113 — §5.7's XP and levels.
///
/// Filed under a standing recommendation to **cut** this feature. These tests
/// pin what it does so the decision can be made against something real.
@MainActor
final class XPTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self,
            SyncConflict.self, StreakFreeze.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    // MARK: - Fixtures

    private func log(_ rating: Int, card: String = "c1", at offset: Int) throws -> ReviewLog {
        try ReviewLog(
            cardId: card, direction: .forward, rating: rating,
            reviewedAt: start.addingTimeInterval(Double(offset) * 60),
            elapsedDays: 0, scheduledDays: 1, stateBefore: .review,
            prevState: CardSchedulingSnapshot()
        )
    }

    // MARK: - Points

    func testEachGradeIsWorthWhatTheSpecSays() {
        XCTAssertEqual(XP.points(forRating: 1), 1)
        XCTAssertEqual(XP.points(forRating: 2), 2)
        XCTAssertEqual(XP.points(forRating: 3), 3)
        XCTAssertEqual(XP.points(forRating: 4), 4)
    }

    /// Rating 0 is an undo marker, not a grade (§5.5). It is worth nothing on its
    /// own; what it does is cancel something else, below.
    func testAnUndoMarkerIsWorthNothingByItself() {
        XCTAssertEqual(XP.points(forRating: 0), 0)
    }

    // MARK: - Level boundaries

    /// §5.7: level *n* needs 100·n·(n+1)/2.
    func testTheLevelThresholdsAreTheSpecsFormula() {
        XCTAssertEqual(XP.threshold(forLevel: 0), 0)
        XCTAssertEqual(XP.threshold(forLevel: 1), 100)
        XCTAssertEqual(XP.threshold(forLevel: 2), 300)
        XCTAssertEqual(XP.threshold(forLevel: 3), 600)
        XCTAssertEqual(XP.threshold(forLevel: 7), 2_800)
    }

    /// Every boundary tested from both sides, because an off-by-one here is a
    /// level someone reaches a hundred points late and never notices.
    func testALevelIsReachedExactlyAtItsThresholdAndNotOneSooner() {
        XCTAssertEqual(XP.level(xp: 0), 0)
        XCTAssertEqual(XP.level(xp: 99), 0)
        XCTAssertEqual(XP.level(xp: 100), 1)
        XCTAssertEqual(XP.level(xp: 299), 1)
        XCTAssertEqual(XP.level(xp: 300), 2)
        XCTAssertEqual(XP.level(xp: 599), 2)
        XCTAssertEqual(XP.level(xp: 600), 3)
        XCTAssertEqual(XP.level(xp: 2_800), 7)
        XCTAssertEqual(XP.level(xp: 2_799), 6)
    }

    func testProgressWithinALevel() {
        XCTAssertEqual(XP.progress(xp: 100).into, 0)
        XCTAssertEqual(XP.progress(xp: 100).outOf, 200, "level 1 spans 100 to 300")
        XCTAssertEqual(XP.progress(xp: 250).into, 150)
        XCTAssertEqual(XP.progress(xp: 250).outOf, 200)
    }

    // MARK: - From the log

    func testTotalSumsEveryGrade() throws {
        let logs = [try log(3, at: 0), try log(4, at: 1), try log(1, at: 2)]
        XCTAssertEqual(XP.total(logs: logs), 8)
    }

    /// The acceptance line. An uploaded review cannot be withdrawn from the
    /// Sheet, so undo writes a `rating: 0` marker beside it and the original row
    /// stays — filtering markers out the way `Streak` does would leave the
    /// undone review's points standing.
    func testAnUndoTakesBackThePointsItsReviewEarned() throws {
        let logs = [try log(4, at: 0), try log(0, at: 1)]
        XCTAssertEqual(XP.total(logs: logs), 0, "the Easy that was undone is not worth 4 any more")
    }

    func testAnUndoTakesBackTheMostRecentRatingOfThatCard() throws {
        // Good, then Easy, then undo: the Easy goes, the Good stays.
        let logs = [try log(3, at: 0), try log(4, at: 1), try log(0, at: 2)]
        XCTAssertEqual(XP.total(logs: logs), 3)
    }

    func testTwoUndosTakeBackTwoReviews() throws {
        let logs = [try log(3, at: 0), try log(4, at: 1), try log(0, at: 2), try log(0, at: 3)]
        XCTAssertEqual(XP.total(logs: logs), 0)
    }

    /// An undo cancels a review of **its own** card, never a neighbour's.
    func testAnUndoOnOneCardDoesNotTakePointsFromAnother() throws {
        let logs = [
            try log(4, card: "a", at: 0),
            try log(4, card: "b", at: 1),
            try log(0, card: "b", at: 2),
        ]
        XCTAssertEqual(XP.total(logs: logs), 4, "only b's review was taken back")
    }

    /// A marker with nothing to cancel — possible after a restore, or a log
    /// hand-edited in the Sheet — must not push the total below zero.
    func testAStrayUndoMarkerCannotDriveTheTotalNegative() throws {
        XCTAssertEqual(XP.total(logs: [try log(0, at: 0)]), 0)
    }

    /// The order the rows arrive in must not change the answer: `_log` comes back
    /// from a spreadsheet, and #41's replay had to learn the same lesson.
    func testTheAnswerDoesNotDependOnTheOrderTheRowsArriveIn() throws {
        let logs = [try log(3, at: 0), try log(4, at: 1), try log(0, at: 2)]
        XCTAssertEqual(XP.total(logs: logs.reversed()), 3)
    }

    func testLevelFromTheLog() throws {
        var logs: [ReviewLog] = []
        for index in 0..<25 { logs.append(try log(4, at: index)) }  // 100 XP
        XCTAssertEqual(XP.total(logs: logs), 100)
        XCTAssertEqual(XP.level(logs: logs), 1)
    }
}
