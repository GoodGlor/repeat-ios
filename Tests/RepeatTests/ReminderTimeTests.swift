import XCTest
@testable import Repeat

/// #128 — the hour a reminder was set for has to survive a DST transition.
///
/// The old arithmetic was `startOfDay(for: now) + minutes × 60`, which assumes a
/// day is 86 400 seconds. Two days a year it is not.
final class ReminderTimeTests: XCTestCase {

    private var kyiv: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) throws -> Date {
        try XCTUnwrap(kyiv.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    /// Whether that local day is actually shorter or longer than 24 hours.
    ///
    /// Asked rather than assumed: Ukraine has repeatedly debated abolishing
    /// summer time, and a test that hardcoded "29 March 2026 is a DST day" would
    /// one day start failing for a reason that has nothing to do with this code.
    private func isTransitionDay(_ day: Date) throws -> Bool {
        let start = kyiv.startOfDay(for: day)
        let next = try XCTUnwrap(kyiv.date(byAdding: .day, value: 1, to: start))
        return kyiv.startOfDay(for: next).timeIntervalSince(start) != 86_400
    }

    /// The old arithmetic, kept here so the tests can show what it did.
    private func oldWay(minutes: Int, on day: Date) -> Date {
        kyiv.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
    }

    // MARK: - The bug

    func testTwentyHundredStaysTwentyHundredWhenTheClocksGoForward() throws {
        let day = try date(2026, 3, 29)
        try XCTSkipUnless(try isTransitionDay(day), "Europe/Kyiv no longer springs forward here")

        let fire = ReminderTime.today(minutes: 20 * 60, now: day, calendar: kyiv)
        XCTAssertEqual(kyiv.component(.hour, from: fire), 20)
        XCTAssertEqual(kyiv.component(.minute, from: fire), 0)
        XCTAssertTrue(kyiv.isDate(fire, inSameDayAs: day))

        XCTAssertEqual(kyiv.component(.hour, from: oldWay(minutes: 20 * 60, on: day)), 21,
                       "this is the bug: an hour of the day is missing, so adding seconds overshoots")
    }

    func testTwentyHundredStaysTwentyHundredWhenTheClocksGoBack() throws {
        let day = try date(2026, 10, 25)
        try XCTSkipUnless(try isTransitionDay(day), "Europe/Kyiv no longer falls back here")

        let fire = ReminderTime.today(minutes: 20 * 60, now: day, calendar: kyiv)
        XCTAssertEqual(kyiv.component(.hour, from: fire), 20)
        XCTAssertTrue(kyiv.isDate(fire, inSameDayAs: day))

        XCTAssertEqual(kyiv.component(.hour, from: oldWay(minutes: 20 * 60, on: day)), 19,
                       "the mirror image: an hour happens twice, so adding seconds falls short")
    }

    /// The obscure case #110's review found. A late reminder on a short day used
    /// to be pushed past midnight, which put it on the *next* day — and §5.5's
    /// collision check asks `isDate(_:inSameDayAs:)`, so it stopped seeing a
    /// collision and let two notifications through.
    func testALateReminderOnAShortDayNoLongerCrossesMidnight() throws {
        let day = try date(2026, 3, 29)
        try XCTSkipUnless(try isTransitionDay(day), "Europe/Kyiv no longer springs forward here")
        let evening = try date(2026, 3, 29, 21)

        let fire = ReminderTime.next(after: evening, minutes: 23 * 60 + 30, calendar: kyiv)
        XCTAssertTrue(kyiv.isDate(fire, inSameDayAs: day), "23:30 is still tonight")
        XCTAssertEqual(kyiv.component(.hour, from: fire), 23)
        XCTAssertEqual(kyiv.component(.minute, from: fire), 30)

        XCTAssertFalse(kyiv.isDate(oldWay(minutes: 23 * 60 + 30, on: day), inSameDayAs: day),
                       "the old arithmetic put a 23:30 reminder on the following day")
    }

    // MARK: - The contracts both reminders depend on

    /// `DailyReminder`'s: a refresh running at exactly the chosen minute must
    /// schedule tomorrow's, not one firing in the same instant.
    func testNextIsStrictlyAfterNow() throws {
        let at2100 = try date(2026, 6, 15, 21)
        let fire = ReminderTime.next(after: at2100, minutes: 21 * 60, calendar: kyiv)
        XCTAssertGreaterThan(fire, at2100)
        XCTAssertEqual(kyiv.component(.hour, from: fire), 21)
        XCTAssertFalse(kyiv.isDate(fire, inSameDayAs: at2100), "it rolled to tomorrow")
    }

    func testNextStaysTodayWhenTheTimeIsStillAhead() throws {
        let noon = try date(2026, 6, 15, 12)
        let fire = ReminderTime.next(after: noon, minutes: 21 * 60, calendar: kyiv)
        XCTAssertTrue(kyiv.isDate(fire, inSameDayAs: noon))
    }

    /// `StreakReminder`'s: tonight or not at all. A moment on another day would
    /// announce a streak that midnight had already ended.
    func testTodayNeverLandsOnAnotherDay() throws {
        for day in [try date(2026, 3, 29), try date(2026, 10, 25), try date(2026, 6, 15)] {
            for minutes in [0, 1, 60, 12 * 60, 20 * 60, 23 * 60 + 59] {
                let fire = ReminderTime.today(minutes: minutes, now: day, calendar: kyiv)
                XCTAssertTrue(kyiv.isDate(fire, inSameDayAs: day),
                              "minutes \(minutes) on \(day) escaped the day")
            }
        }
    }

    /// Midnight is a real answer, and `nextDate(after:)` is strict — so the
    /// search has to start before midnight or 00:00 would match tomorrow's.
    func testMidnightMatchesTodayRatherThanTomorrow() throws {
        let day = try date(2026, 6, 15)
        let fire = ReminderTime.today(minutes: 0, now: day, calendar: kyiv)
        XCTAssertEqual(fire, kyiv.startOfDay(for: day))
    }

    /// An ordinary day must give exactly what the old arithmetic gave, or this
    /// change is not a fix but a behaviour change.
    func testAnOrdinaryDayIsUnchanged() throws {
        let day = try date(2026, 6, 15)
        XCTAssertFalse(try isTransitionDay(day), "the control day must be an ordinary one")
        for minutes in [0, 9 * 60 + 30, 20 * 60, 21 * 60] {
            XCTAssertEqual(ReminderTime.today(minutes: minutes, now: day, calendar: kyiv),
                           oldWay(minutes: minutes, on: day), "minutes \(minutes)")
        }
    }
}
