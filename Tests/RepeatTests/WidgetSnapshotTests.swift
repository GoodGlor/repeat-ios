import XCTest
@testable import Repeat

/// #111 — the widget's rendering decisions, which until this card lived in
/// `RepeatWidget/` where no test could reach them.
final class WidgetSnapshotTests: XCTestCase {

    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var today: Date { calendar.startOfDay(for: now) }

    private func count(due: Int, target: Int = 0, done: Int = 0,
                       streak: Int = 0, day: Date? = nil) -> DueCount {
        DueCount(due: due, day: day ?? today, goalTarget: target,
                 goalDone: done, streak: streak, generatedAt: now)
    }

    private func make(_ count: DueCount?) -> WidgetSnapshot {
        WidgetSnapshot.make(from: count, on: now, calendar: calendar)
    }

    // MARK: - Staleness: everything expires together

    func testNoFileAtAllIsStale() {
        let snapshot = make(nil)
        XCTAssertTrue(snapshot.isStale)
        XCTAssertNil(snapshot.due)
        XCTAssertNil(snapshot.streak)
        XCTAssertFalse(snapshot.showsRing)
        XCTAssertEqual(snapshot.goalProgress, 0)
    }

    /// The streak in a file from another day may well still be true — and is
    /// dropped anyway. One rule for the file, so the two numbers cannot disagree
    /// about which day they describe.
    func testAFileFromAnotherDayTakesTheStreakDownWithIt() throws {
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let snapshot = make(count(due: 42, target: 50, done: 8, streak: 30, day: yesterday))

        XCTAssertTrue(snapshot.isStale)
        XCTAssertNil(snapshot.due)
        XCTAssertNil(snapshot.streak, "a live streak is still dropped — one rule for one file")
        XCTAssertFalse(snapshot.showsRing)
    }

    // MARK: - A fresh file

    func testAFreshFileCarriesTheCountTheRingAndTheStreak() {
        let snapshot = make(count(due: 12, target: 30, done: 18, streak: 9))

        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(snapshot.due, 12)
        XCTAssertTrue(snapshot.showsRing)
        XCTAssertEqual(snapshot.goalProgress, 0.6, accuracy: 0.0001)
        XCTAssertEqual(snapshot.goalDone, 18, "the medium layout says \"18 з 30\", not a fraction")
        XCTAssertEqual(snapshot.goalTarget, 30)
        XCTAssertEqual(snapshot.streak, 9)
    }

    // MARK: - The ring

    /// A fresh install has nothing due and nothing done. An empty ring beside an
    /// empty count is a scoreboard reporting that you have not started — the same
    /// mistake the study screen's "0 %" made before #89.
    func testNoGoalDrawsNoRingRatherThanAnEmptyOne() {
        let snapshot = make(count(due: 0, target: 0, done: 0))
        XCTAssertFalse(snapshot.showsRing)
        XCTAssertEqual(snapshot.goalProgress, 0)
    }

    func testAClosedDayIsAFullRingAndNotStale() {
        let snapshot = make(count(due: 0, target: 20, done: 20, streak: 4))
        XCTAssertTrue(snapshot.isDone)
        XCTAssertFalse(snapshot.isStale, "done is good news; stale is no news")
        XCTAssertEqual(snapshot.goalProgress, 1)
        XCTAssertTrue(snapshot.showsRing)
    }

    /// Catch-up mode can grade more than the morning promised. A ring past full is
    /// a lie about the target, not a fact about the work.
    func testARingNeverOverdraws() {
        XCTAssertEqual(make(count(due: 0, target: 10, done: 25)).goalProgress, 1)
    }

    // MARK: - The streak

    /// "1 day" is not a streak, it is today.
    func testAStreakOfOneIsNotShown() {
        XCTAssertNil(make(count(due: 3, streak: 1)).streak)
        XCTAssertNil(make(count(due: 3, streak: 0)).streak)
        XCTAssertEqual(make(count(due: 3, streak: 2)).streak, 2)
    }
}
