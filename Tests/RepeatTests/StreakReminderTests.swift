import XCTest
import SwiftData
import UserNotifications
import Scheduling
@testable import Repeat

/// #110 — the reminder that fires only when a live streak has nothing today.
final class StreakReminderTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2027-01-15 08:00 UTC — morning, so an evening time is still ahead today.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let evening = 20 * 60

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    /// One review `daysAgo` days before `now`. `rating: 0` is an undo marker.
    @discardableResult
    private func log(_ rating: Int, daysAgo: Int, in context: ModelContext) throws -> ReviewLog {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let entry = try ReviewLog(
            cardId: "c-\(daysAgo)-\(rating)-\(UUID().uuidString)", direction: .forward,
            rating: rating, reviewedAt: date, elapsedDays: 1, scheduledDays: 1,
            stateBefore: .review, prevState: CardSchedulingSnapshot()
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    private func logs(_ context: ModelContext) throws -> [ReviewLog] {
        try context.fetch(FetchDescriptor<ReviewLog>())
    }

    /// A streak of `length` days ending yesterday — nothing reviewed today.
    private func streakEndingYesterday(_ length: Int, in context: ModelContext) throws {
        for day in 1...length { try log(3, daysAgo: day, in: context) }
    }

    // MARK: - Acceptance: when there is something to lose

    func testAStreakWithNothingTodaySchedulesForThisEvening() throws {
        let context = try makeContext()
        try streakEndingYesterday(12, in: context)

        let plan = streakPlan(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar)

        let unwrapped = try XCTUnwrap(plan)
        XCTAssertEqual(unwrapped.length, 12)
        XCTAssertEqual(unwrapped.fireDate,
                       calendar.startOfDay(for: now).addingTimeInterval(20 * 3600))
    }

    // MARK: - Acceptance: silence on every day it would be false

    func testNoStreakSchedulesNothing() throws {
        let context = try makeContext()
        // A gap: reviews five and six days ago, nothing since. The streak is over.
        try log(3, daysAgo: 5, in: context)
        try log(3, daysAgo: 6, in: context)

        XCTAssertNil(streakPlan(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar))
    }

    func testAnEmptyLogSchedulesNothing() throws {
        XCTAssertNil(streakPlan(
            logs: [], enabled: true, streakMinutes: evening, now: now, calendar: calendar))
    }

    func testAReviewAlreadyTodaySchedulesNothing() throws {
        let context = try makeContext()
        try streakEndingYesterday(12, in: context)
        try log(3, daysAgo: 0, in: context)

        XCTAssertNil(streakPlan(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar))
    }

    func testRemindersOffScheduleNothing() throws {
        let context = try makeContext()
        try streakEndingYesterday(4, in: context)

        XCTAssertNil(streakPlan(
            logs: try logs(context), enabled: false, streakMinutes: evening,
            now: now, calendar: calendar))
    }

    /// The shelf-life rule. `DailyReminder` rolls to tomorrow when tonight's time
    /// has passed; this one cannot. With no review today the streak is broken at
    /// midnight, so a request for tomorrow evening would announce a streak that no
    /// longer exists.
    func testATimeAlreadyPastTodaySchedulesNothingRatherThanTomorrow() throws {
        let context = try makeContext()
        try streakEndingYesterday(9, in: context)

        // 07:00, and `now` is 08:00.
        XCTAssertNil(streakPlan(
            logs: try logs(context), enabled: true, streakMinutes: 7 * 60,
            now: now, calendar: calendar))
    }

    /// An undo is not a review — it is the removal of one. A day whose only entry
    /// is a rating-0 marker still has the streak at risk.
    func testAnUndoMarkerTodayIsNotAReview() throws {
        let context = try makeContext()
        try streakEndingYesterday(3, in: context)
        try log(0, daysAgo: 0, in: context)

        let plan = try XCTUnwrap(streakPlan(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar))
        XCTAssertEqual(plan.length, 3)
    }

    // MARK: - Acceptance: Ukrainian plural agreement

    func testTheBodyAgreesWithUkrainianPlurals() {
        let uk = Locale(identifier: "uk_UA")
        XCTAssertEqual(StreakReminder.body(length: 1, locale: uk),
                       "Серія 1 день — сьогодні ще без повторень")
        XCTAssertEqual(StreakReminder.body(length: 2, locale: uk),
                       "Серія 2 дні — сьогодні ще без повторень")
        XCTAssertEqual(StreakReminder.body(length: 5, locale: uk),
                       "Серія 5 днів — сьогодні ще без повторень")
        // 21 is `one` in Ukrainian, the case an English-shaped rule gets wrong.
        XCTAssertEqual(StreakReminder.body(length: 21, locale: uk),
                       "Серія 21 день — сьогодні ще без повторень")
        XCTAssertEqual(StreakReminder.body(length: 22, locale: uk),
                       "Серія 22 дні — сьогодні ще без повторень")
    }

    // MARK: - Scheduling through the seam

    func testTheRequestCarriesTheStudyDeepLinkAndTheFireTime() async throws {
        let context = try makeContext()
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        await schedule(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar, using: scheduler)

        let pending = await scheduler.pendingRequests()
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.identifier, StreakReminder.identifier)
        XCTAssertEqual(request.content.userInfo[NotificationRouter.userInfoKey] as? String,
                       DeepLink.study)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats, "a repeating trigger would fire with a frozen streak")
        XCTAssertEqual(trigger.dateComponents.hour, 20)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
    }

    /// Acceptance: "a review landing removes the pending request". The refresh that
    /// runs at session end recomputes to `nil` — but the removal happens first and
    /// unconditionally, which is what actually cancels it.
    func testAReviewLandingRemovesThePendingRequest() async throws {
        let context = try makeContext()
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        await schedule(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar, using: scheduler)
        let firstPending = await scheduler.pendingRequests()
        XCTAssertEqual(firstPending.count, 1)

        // The session ends; a review lands today; the app refreshes.
        try log(3, daysAgo: 0, in: context)
        let plan = await schedule(
            logs: try logs(context), enabled: true, streakMinutes: evening,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(plan)
        let remainingPending = await scheduler.pendingRequests()
        XCTAssertTrue(remainingPending.isEmpty)
        XCTAssertEqual(scheduler.removals, [[StreakReminder.identifier],
                                            [StreakReminder.identifier]])
    }

    func testChangingTheTimeReschedulesRatherThanStacking() async throws {
        let context = try makeContext()
        try streakEndingYesterday(6, in: context)
        let scheduler = FakeScheduler()

        await schedule(
            logs: try logs(context), enabled: true, streakMinutes: 19 * 60,
            now: now, calendar: calendar, using: scheduler)
        await schedule(
            logs: try logs(context), enabled: true, streakMinutes: 21 * 60,
            now: now, calendar: calendar, using: scheduler)

        let pending = await scheduler.pendingRequests()
        XCTAssertEqual(pending.count, 1)
        let trigger = try XCTUnwrap(pending.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 21)
    }

    /// The 2026-09-04 crash: `apply` runs on the caller's actor rather than
    /// hopping to the cooperative pool, which is what keeps model reads on the
    /// thread that owns them.
    ///
    /// Calls `apply` directly rather than through `schedule` below: a plain
    /// `async` helper on this class is *nonisolated*, so awaiting it would leave
    /// the main actor and the probe would be measuring the helper, not the code
    /// under test. `EveningReminderTests` pins the same property on the
    /// production entry point.
    @MainActor
    func testApplyStaysOnTheActorThatCalledIt() async throws {
        let context = try makeContext()
        try streakEndingYesterday(3, in: context)
        let scheduler = ThreadProbeScheduler()

        let risk = StreakReminder.lengthAtRisk(
            logs: try logs(context), enabled: true, now: now, calendar: calendar)
        let plan = StreakReminder.plan(
            lengthAtRisk: risk, streakMinutes: evening, now: now, calendar: calendar)
        await StreakReminder.apply(plan, using: scheduler, calendar: calendar)

        XCTAssertEqual(scheduler.onMainThread.count, 2, "expected a removal and an add")
        XCTAssertTrue(scheduler.onMainThread.allSatisfy { $0 },
                      "apply left the main actor — main thread per call: \(scheduler.onMainThread)")
    }

    /// `lengthAtRisk` + `plan`, the pair `EveningReminder` computes. Was
    /// `StreakReminder.plan(logs:…)`, deleted with `refresh` in #130 — it existed
    /// only to serve `refresh` and these tests.
    ///
    /// Named `streakPlan` rather than `plan` so it cannot shadow the `let plan =`
    /// bindings at the call sites.
    private func streakPlan(
        logs: [ReviewLog],
        enabled: Bool,
        streakMinutes: Int,
        now: Date,
        calendar: Calendar
    ) -> StreakReminder.Plan? {
        let risk = StreakReminder.lengthAtRisk(
            logs: logs, enabled: enabled, now: now, calendar: calendar)
        return StreakReminder.plan(
            lengthAtRisk: risk, streakMinutes: streakMinutes, now: now, calendar: calendar)
    }

    /// The two halves `EveningReminder` calls, in the order it calls them.
    ///
    /// Was `StreakReminder.refresh`, which #130 deleted: it had no production
    /// caller and it bypassed §5.5's arbitration entirely, so a test driving it
    /// was exercising a path the app never takes. Same parameter labels, so what
    /// these tests assert is unchanged — only the road to it is the real one.
    @discardableResult
    private func schedule(
        logs: [ReviewLog],
        enabled: Bool,
        streakMinutes: Int,
        now: Date,
        calendar: Calendar,
        using scheduler: any NotificationScheduling
    ) async -> StreakReminder.Plan? {
        let plan = streakPlan(logs: logs, enabled: enabled, streakMinutes: streakMinutes,
                              now: now, calendar: calendar)
        await StreakReminder.apply(plan, using: scheduler, calendar: calendar)
        return plan
    }
}
