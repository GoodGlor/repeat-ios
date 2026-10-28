import XCTest
@testable import Repeat

/// §5.2 — a year of days, shaded by reviews. The value is tested; the drawing is
/// looked at (screenshots in Task 4).
final class HeatmapTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// Friday 15 January 2027, 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    func testTheGridIsAYearOfWeeksEndingWithThisOne() {
        XCTAssertEqual(calendar.component(.weekday, from: now), 6, "the fixture is a Friday")
        let map = Heatmap.make(reviewDates: [], now: now, calendar: calendar)

        XCTAssertEqual(map.cells.count, Heatmap.weeks)
        XCTAssertTrue(map.cells.allSatisfy { $0.count == Heatmap.daysPerWeek && $0.allSatisfy { $0 == 0 } },
                      "an empty history is an all-zero grid, not a missing one")
        XCTAssertEqual(calendar.component(.weekday, from: map.start), 2, "column 0 starts on a Monday")
        XCTAssertEqual(map.start,
                       calendar.date(byAdding: .day, value: -(51 * 7 + 4), to: calendar.startOfDay(for: now)),
                       "Friday is four days into its week; 51 more weeks back is the start")
        XCTAssertEqual(map.todayWeekday, 4, "Monday 0 … Friday 4")
        XCTAssertEqual(map.totalReviews, 0)
        XCTAssertEqual(map.activeDays, 0)
    }

    func testADayLandsInItsWeekAndWeekdayCell() {
        let map = Heatmap.make(reviewDates: [now, daysAgo(7)], now: now, calendar: calendar)
        XCTAssertEqual(map.cells[51][4], 4, "today, one of the two busiest days, is the last column's Friday")
        XCTAssertEqual(map.cells[50][4], 4, "a week earlier is one column left")
        XCTAssertEqual(map.cells[51][0], 0, "Monday of this week had nothing")
        XCTAssertEqual(map.activeDays, 2)
        XCTAssertEqual(map.totalReviews, 2)
    }

    func testShadesAreQuartersOfTheBusiestDayRoundedUp() {
        XCTAssertEqual(Heatmap.level(count: 0, peak: 8), 0)
        XCTAssertEqual(Heatmap.level(count: 1, peak: 8), 1, "one review is never invisible")
        XCTAssertEqual(Heatmap.level(count: 2, peak: 8), 1)
        XCTAssertEqual(Heatmap.level(count: 3, peak: 8), 2)
        XCTAssertEqual(Heatmap.level(count: 4, peak: 8), 2)
        XCTAssertEqual(Heatmap.level(count: 6, peak: 8), 3)
        XCTAssertEqual(Heatmap.level(count: 8, peak: 8), 4)
        XCTAssertEqual(Heatmap.level(count: 1, peak: 1), 4, "the only day there is, is the busiest")
    }

    func testReviewsOutsideTheYearAreNeitherDrawnNorCounted() {
        let old = calendar.date(byAdding: .day, value: -400, to: now)!
        let map = Heatmap.make(reviewDates: [old, old, daysAgo(1)], now: now, calendar: calendar)
        XCTAssertEqual(map.totalReviews, 1)
        XCTAssertEqual(map.cells.flatMap { $0 }.filter { $0 > 0 }.count, 1)
    }

    /// The view skips rows below `todayWeekday`; the value backs it by not
    /// counting a date that has not happened.
    func testTomorrowIsNotInTheYear() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let map = Heatmap.make(reviewDates: [tomorrow], now: now, calendar: calendar)
        XCTAssertEqual(map.totalReviews, 0)
        XCTAssertEqual(map.cells[51][5], 0)
    }
}
