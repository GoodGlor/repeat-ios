import XCTest
import SwiftData
@testable import Repeat

/// #112 — the one piece of gamification this app stores rather than derives.
@MainActor
final class FreezeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendar = Calendar(identifier: .gregorian)

    /// Noon, so adding whole days can never land on a DST edge and change the
    /// start-of-day the whole feature is keyed on.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        container = try ModelContainer(
            for: Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self,
            SyncConflict.self, StreakFreeze.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// `daysAgo(0)` is today.
    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    }

    private func reviewDays(_ daysAgo: [Int]) -> Set<Date> {
        Set(daysAgo.map(day))
    }

    // MARK: - Streak.length with freezes

    /// The card's acceptance, in one test: a freeze bridges one day and not two.
    func testAFreezeBridgesOneDayAndNotTwo() {
        // Reviewed 4, 3 and 1 days ago; nothing 2 days ago.
        let dates = [day(4), day(3), day(1)]

        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 1,
                       "without a freeze the gap two days ago ends the run")
        XCTAssertEqual(
            Streak.length(reviewDates: dates, frozenDays: [day(2)], now: now, calendar: calendar), 3,
            "the freeze bridges the gap; the three real days count, the frozen one does not"
        )

        // Two missing days, one freeze: it cannot reach across both.
        let wider = [day(5), day(4), day(1)]
        XCTAssertEqual(
            Streak.length(reviewDates: wider, frozenDays: [day(2)], now: now, calendar: calendar), 1,
            "one freeze must not bridge two days"
        )
        XCTAssertEqual(
            Streak.length(reviewDates: wider, frozenDays: [day(2), day(3)],
                          now: now, calendar: calendar), 3,
            "two freezes may"
        )
    }

    /// Ruling 4: a freeze buys a day off, not a day's work.
    func testAFrozenDayDoesNotCountTowardTheLength() {
        let dates = [day(2), day(1)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 2)
        XCTAssertEqual(
            Streak.length(reviewDates: [day(3), day(1)], frozenDays: [day(2)],
                          now: now, calendar: calendar), 2,
            "three consecutive days, one of them frozen, still reads 2"
        )
    }

    func testFreezesChangeNothingForACallerThatPassesNone() {
        let dates = [day(2), day(1), day(0)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 3)
        XCTAssertEqual(Streak.length(reviewDates: dates, frozenDays: [], now: now, calendar: calendar), 3)
    }

    /// A freeze protects a streak; it does not manufacture one out of nothing.
    func testAFreezeAloneIsNotAStreak() {
        XCTAssertEqual(
            Streak.length(reviewDates: [], frozenDays: [day(1)], now: now, calendar: calendar), 0
        )
    }

    // MARK: - How many there are

    func testOneFreezeIsEarnedEverySevenDaysReviewed() {
        XCTAssertEqual(Freeze.earned(reviewDays: reviewDays(Array(0..<6))), 0)
        XCTAssertEqual(Freeze.earned(reviewDays: reviewDays(Array(0..<7))), 1)
        XCTAssertEqual(Freeze.earned(reviewDays: reviewDays(Array(0..<20))), 2)
    }

    func testNoMoreThanTwoAreHeldAtOnce() {
        let plenty = reviewDays(Array(0..<70))
        XCTAssertEqual(Freeze.earned(reviewDays: plenty), 10)
        XCTAssertEqual(Freeze.available(reviewDays: plenty, spent: 0), Freeze.maximumHeld)
        XCTAssertEqual(Freeze.available(reviewDays: plenty, spent: 9), 1)
        XCTAssertEqual(Freeze.available(reviewDays: plenty, spent: 10), 0)
        XCTAssertEqual(Freeze.available(reviewDays: plenty, spent: 99), 0,
                       "more spent than earned is still zero, never negative")
    }

    // MARK: - When one is spent

    private func spend(_ reviewDays: Set<Date>, frozen: Set<Date> = [], available: Int = 1) -> Date? {
        Freeze.dayToFreeze(reviewDays: reviewDays, frozen: frozen, available: available,
                           now: now, calendar: calendar)
    }

    func testYesterdayIsFrozenWhenItBrokeARun() {
        XCTAssertEqual(spend(reviewDays([3, 2])), day(1))
    }

    func testNothingIsSpentWhenYesterdayWasWorked() {
        XCTAssertNil(spend(reviewDays([2, 1])))
    }

    func testNothingIsSpentWithNoneAvailable() {
        XCTAssertNil(spend(reviewDays([3, 2]), available: 0))
    }

    /// The bound that makes the whole feature safe: coming back after a long
    /// absence must not reach back and rewrite history.
    func testNothingIsSpentAfterALongAbsence() {
        XCTAssertNil(spend(reviewDays([30, 29, 28])),
                     "the run ended weeks ago; a freeze cannot resurrect it")
    }

    func testSettlingTwiceInADayChangesNothing() {
        XCTAssertNil(spend(reviewDays([3, 2]), frozen: [day(1)]),
                     "yesterday is already covered")
    }

    /// A freeze may follow a freeze, as long as each was spent on its own day.
    func testAFreezeMayExtendARunThatAlreadyEndsInOne() {
        XCTAssertEqual(spend(reviewDays([3]), frozen: [day(2)]), day(1))
    }

    // MARK: - Writing it down

    func testSettleWritesOneRowAndIsIdempotent() {
        let days = reviewDays(Array(2..<12))   // ten days, ending the day before yesterday
        XCTAssertEqual(Freeze.available(reviewDays: days, spent: 0), 1)

        let first = Freeze.settle(in: context, reviewDays: days, now: now, calendar: calendar)
        XCTAssertEqual(first?.day, day(1))
        XCTAssertEqual(Freeze.rows(in: context).count, 1)

        let second = Freeze.settle(in: context, reviewDays: days, now: now, calendar: calendar)
        XCTAssertNil(second, "a second settle on the same day must write nothing")
        XCTAssertEqual(Freeze.rows(in: context).count, 1)
        XCTAssertEqual(Freeze.days(in: context), [day(1)])
    }

    func testSettleWritesNothingWithoutEnoughDaysBehindIt() {
        // Only three days reviewed, so nothing has been earned yet.
        let days = reviewDays([4, 3, 2])
        XCTAssertEqual(Freeze.available(reviewDays: days, spent: 0), 0)
        XCTAssertNil(Freeze.settle(in: context, reviewDays: days, now: now, calendar: calendar))
        XCTAssertTrue(Freeze.rows(in: context).isEmpty)
    }

    func testTheNewestUnannouncedFreezeIsTheOneTheDoneScreenNames() {
        let old = StreakFreeze(day: day(9), spentAt: now, announcedAt: now)
        let fresh = StreakFreeze(day: day(1), spentAt: now)
        context.insert(old)
        context.insert(fresh)

        XCTAssertEqual(Freeze.unannounced(in: context)?.day, day(1))

        fresh.announcedAt = now
        XCTAssertNil(Freeze.unannounced(in: context), "nothing left to name")
    }
}
