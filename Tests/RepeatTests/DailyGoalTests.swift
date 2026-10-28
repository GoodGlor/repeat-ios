import XCTest
@testable import Repeat

/// M9 §5.1 — a target fixed at the start of the day, so the ring only ever moves
/// forward. `HomeSummary.todayProgress` (#89) used a moving denominator; this is
/// the one thing the goal changes about it.
final class DailyGoalTests: XCTestCase {

    /// The first build of the day sets the target: everything done plus
    /// everything planned — the same number #89's ratio used.
    func testWithNoCacheTheTargetIsTodayAsItStands() {
        let goal = DailyGoal.make(reviewedToday: 3, dueCount: 7, cachedTarget: nil)
        XCTAssertEqual(goal.target, 10)
        XCTAssertEqual(goal.done, 3)
        XCTAssertEqual(goal.progress, 0.3, accuracy: 0.0001)
        XCTAssertFalse(goal.isClosed)
    }

    /// Cards added mid-day raise the plan, not the target (spec §5.1).
    func testCardsAddedMidDayDoNotReopenAClosedGoal() {
        let goal = DailyGoal.make(reviewedToday: 10, dueCount: 5, cachedTarget: 10)
        XCTAssertEqual(goal.target, 10)
        XCTAssertEqual(goal.progress, 1, accuracy: 0.0001)
        XCTAssertTrue(goal.isClosed, "ten of ten is closed, whatever arrived since")
    }

    /// Catch-up mode can grade more than the morning's plan; the ring must not
    /// read 140 %, and the target follows what was actually done.
    func testTheTargetIsNeverBelowWhatWasDone() {
        let goal = DailyGoal.make(reviewedToday: 14, dueCount: 0, cachedTarget: 10)
        XCTAssertEqual(goal.target, 14)
        XCTAssertEqual(goal.progress, 1, accuracy: 0.0001)
        XCTAssertTrue(goal.isClosed)
    }

    /// A fresh install: nothing on either side. No goal, not "closed".
    func testNothingToDoIsNoGoalNotAClosedOne() {
        let goal = DailyGoal.make(reviewedToday: 0, dueCount: 0, cachedTarget: nil)
        XCTAssertEqual(goal.target, 0)
        XCTAssertEqual(goal.progress, 0)
        XCTAssertFalse(goal.isClosed)
    }

    /// A day that started empty and then received cards adopts them as the goal:
    /// a cached zero is "no goal yet", not "the goal is zero".
    func testACachedZeroIsReplacedWhenWorkArrives() {
        let goal = DailyGoal.make(reviewedToday: 0, dueCount: 6, cachedTarget: 0)
        XCTAssertEqual(goal.target, 6)
        XCTAssertFalse(goal.isClosed)
    }

    /// The morning promised 60; the owner accepted the catch-up offer, which moved
    /// 40 to later days, and graded the 20 that stayed. The queue is empty and the
    /// day is closed — the ring must not sit at 33 % beside "На сьогодні все".
    /// Additions still never raise the target; only an empty queue lowers it.
    func testAnEmptyQueueClosesTheDayEvenWhenTheMorningPromisedMore() {
        let goal = DailyGoal.make(reviewedToday: 20, dueCount: 0, cachedTarget: 60)
        XCTAssertEqual(goal.target, 20)
        XCTAssertTrue(goal.isClosed)
    }

    // MARK: - The cache

    private func freshDefaults() -> UserDefaults {
        let name = "daily-goal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// 2027-01-15 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_800_000_000 + 4 * 3600)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testTheCacheAnswersForTheDayItWasStoredOn() {
        let cache = DailyGoalCache(defaults: freshDefaults(), calendar: utc)
        XCTAssertNil(cache.target(on: noon), "nothing stored yet")
        cache.store(12, on: noon)
        XCTAssertEqual(cache.target(on: noon), 12)
        XCTAssertEqual(cache.target(on: noon.addingTimeInterval(8 * 3600)), 12, "same day, later")
    }

    func testTheCacheIsSilentAboutAnotherDay() {
        let cache = DailyGoalCache(defaults: freshDefaults(), calendar: utc)
        cache.store(12, on: noon)
        XCTAssertNil(cache.target(on: noon.addingTimeInterval(86_400)), "tomorrow starts fresh")
        XCTAssertNil(cache.target(on: noon.addingTimeInterval(-86_400)), "yesterday is not today")
    }
}
