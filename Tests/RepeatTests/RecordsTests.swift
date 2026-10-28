import XCTest
@testable import Repeat

/// §5.2 — the records, derived from the log the way the streak is.
final class RecordsTests: XCTestCase {

    /// Fixed calendar so the weekday facts below hold on any machine: in 2027,
    /// 1 January is a Friday, 31 January a Sunday, 1 February a Monday.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour))!
    }

    /// `count` reviews on one day, a minute apart.
    private func reviews(_ month: Int, _ day: Int, count: Int) -> [Date] {
        (0..<count).map { date(month, day).addingTimeInterval(Double($0) * 60) }
    }

    private func startOfDay(_ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: date(month, day))
    }

    // MARK: - make

    func testLongestStreakIsTheLongestRunAnywhereNotTheCurrentOne() {
        let dates = [1, 2, 3].map { date(1, $0) }
            + [6, 7, 8, 9, 10].map { date(1, $0) }
            + [date(1, 13)]
        let records = Records.make(reviewDates: dates, calendar: calendar)
        XCTAssertEqual(records.longestStreak, 5, "6–10 January, across the gap after the 3rd")
    }

    func testSeveralReviewsInOneDayAreOneDayOfStreak() {
        let dates = reviews(1, 5, count: 4) + reviews(1, 6, count: 1)
        XCTAssertEqual(Records.make(reviewDates: dates, calendar: calendar).longestStreak, 2)
    }

    func testBestDayTieGoesToTheEarliest() {
        let dates = reviews(1, 9, count: 3) + reviews(1, 3, count: 3) + reviews(1, 5, count: 2)
        let best = Records.make(reviewDates: dates, calendar: calendar).bestDay
        XCTAssertEqual(best, Records.Entry(start: startOfDay(1, 3), count: 3),
                       "a record's date must never move once it is set")
    }

    func testBestWeekIsMondayToSundayEvenAcrossAMonthEnd() {
        XCTAssertEqual(calendar.component(.weekday, from: date(2, 1)), 2, "1 February 2027 is a Monday")
        // Sunday 31 January ends one week; Monday 1 February starts the next.
        let dates = reviews(1, 31, count: 5) + reviews(2, 1, count: 4) + reviews(2, 2, count: 2)
        let best = Records.make(reviewDates: dates, calendar: calendar).bestWeek
        XCTAssertEqual(best, Records.Entry(start: startOfDay(2, 1), count: 6),
                       "the Sunday belongs to the week before, so 5 loses to 4 + 2")
    }

    /// §5.2 says Monday, whatever the device's region says.
    func testTheWeekRuleIgnoresTheDevicesFirstWeekday() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let dates = reviews(1, 31, count: 5) + reviews(2, 1, count: 4)
        let best = Records.make(reviewDates: dates, calendar: sundayFirst).bestWeek
        XCTAssertEqual(best, Records.Entry(start: sundayFirst.startOfDay(for: date(1, 25)), count: 5),
                       "with Sunday-first weeks the 31st and the 1st would wrongly share a week")
    }

    func testEmptyHistoryHasNoRecords() {
        XCTAssertEqual(Records.make(reviewDates: [], calendar: calendar), .empty)
        XCTAssertEqual(Records.empty.longestStreak, 0)
        XCTAssertNil(Records.empty.bestDay)
        XCTAssertNil(Records.empty.bestWeek)
        XCTAssertNil(Records.empty.longestStreakStart)
    }

    // MARK: - longest run identity

    func testTheLongestStreakRemembersWhereItStarted() {
        let dates = [1, 2, 3].map { date(1, $0) } + [6, 7, 8, 9, 10].map { date(1, $0) }
        let records = Records.make(reviewDates: dates, calendar: calendar)
        XCTAssertEqual(records.longestStreak, 5)
        XCTAssertEqual(records.longestStreakStart, startOfDay(1, 6))
    }

    /// Two runs of equal length: the earlier one holds the record, so a current
    /// run that merely *ties* it is not yet a new record.
    func testATiedLongestStreakBelongsToTheEarlierRun() {
        let dates = [1, 2, 3].map { date(1, $0) } + [10, 11, 12].map { date(1, $0) }
        let records = Records.make(reviewDates: dates, calendar: calendar)
        XCTAssertEqual(records.longestStreak, 3)
        XCTAssertEqual(records.longestStreakStart, startOfDay(1, 1))
    }

    // MARK: - newlySet

    private func records(streak: Int, from streakStart: Date?, day: (Int, Date)?, week: (Int, Date)?) -> Records {
        Records(longestStreak: streak,
                longestStreakStart: streakStart,
                bestDay: day.map { Records.Entry(start: $0.1, count: $0.0) },
                bestWeek: week.map { Records.Entry(start: $0.1, count: $0.0) })
    }

    /// The first session sets every record. Announcing three of them to someone
    /// who has just learned what the app is would be noise, not reward.
    func testTheFirstSessionEverSetsEverythingAndAnnouncesNothing() {
        let after = records(streak: 1, from: startOfDay(1, 1),
                            day: (10, startOfDay(1, 1)), week: (10, startOfDay(12, 28)))
        XCTAssertEqual(Records.newlySet(before: .empty, after: after), [])
    }

    /// The case the final review caught: on your record run, every evening
    /// used to say "new longest streak". Extending the run that already holds
    /// the record is not a new record.
    func testExtendingTheRecordRunIsNotANewRecord() {
        let before = records(streak: 14, from: startOfDay(1, 1), day: (10, startOfDay(1, 3)), week: (70, startOfDay(1, 4)))
        let after = records(streak: 15, from: startOfDay(1, 1), day: (10, startOfDay(1, 3)), week: (70, startOfDay(1, 4)))
        XCTAssertEqual(Records.newlySet(before: before, after: after), [])
    }

    func testOvertakingAnOlderRunIsANewRecord() {
        let before = records(streak: 3, from: startOfDay(1, 1), day: nil, week: nil)
        let after = records(streak: 4, from: startOfDay(1, 10), day: nil, week: nil)
        XCTAssertEqual(Records.newlySet(before: before, after: after), [.longestStreak(4)])
    }

    /// A second session today that raises today's own count does not set the
    /// record again; a different day beating today's would.
    func testABestDayIsNamedOnceHoweverManySessionsExtendIt() {
        let morning = records(streak: 7, from: startOfDay(1, 1), day: (12, startOfDay(1, 7)), week: (70, startOfDay(1, 4)))
        let evening = records(streak: 7, from: startOfDay(1, 1), day: (20, startOfDay(1, 7)), week: (78, startOfDay(1, 4)))
        XCTAssertEqual(Records.newlySet(before: morning, after: evening), [],
                       "same day, same week — the record did not move")

        let nextWeek = records(streak: 7, from: startOfDay(1, 1), day: (21, startOfDay(1, 14)), week: (79, startOfDay(1, 11)))
        XCTAssertEqual(Records.newlySet(before: evening, after: nextWeek), [.bestDay(21), .bestWeek(79)])
    }

    func testABeatenRecordIsNamedStreakFirst() {
        let before = records(streak: 7, from: startOfDay(1, 1), day: (10, startOfDay(1, 3)), week: (70, startOfDay(1, 4)))
        let after = records(streak: 8, from: startOfDay(1, 10), day: (12, startOfDay(1, 17)), week: (72, startOfDay(1, 11)))
        XCTAssertEqual(Records.newlySet(before: before, after: after),
                       [.longestStreak(8), .bestDay(12), .bestWeek(72)])
    }

    func testEqualledIsNotBeaten() {
        let same = records(streak: 7, from: startOfDay(1, 1), day: (10, startOfDay(1, 3)), week: (70, startOfDay(1, 4)))
        XCTAssertEqual(Records.newlySet(before: same, after: same), [])
    }

    /// Same floor as `StreakChip`: "new longest streak — 1 day" is not a record.
    func testASecondDayIsTheFirstStreakWorthNaming() {
        let oneDayRecord = records(streak: 1, from: startOfDay(1, 1), day: (5, startOfDay(1, 1)), week: (5, startOfDay(12, 28)))
        let twoDayNewRun = records(streak: 2, from: startOfDay(1, 5), day: (5, startOfDay(1, 1)), week: (5, startOfDay(12, 28)))
        XCTAssertEqual(Records.newlySet(before: oneDayRecord, after: twoDayNewRun), [.longestStreak(2)])
        XCTAssertEqual(Records.newlySet(before: .empty, after: oneDayRecord), [])
    }
}
