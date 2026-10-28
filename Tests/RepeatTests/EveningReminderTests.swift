import XCTest
import SwiftData
import UserNotifications
import Scheduling
@testable import Repeat

/// #110 — §5.5's rule of one: when both reminders would fire the same evening,
/// only the streak one does.
final class EveningReminderTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    /// Cards already due, so `DailyReminder` has something to announce.
    private func addDueCards(_ context: ModelContext, to deck: Deck, count: Int) throws {
        for index in 0..<count {
            let note = Note(deck: deck, front: "f\(index)", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            card.state = .review
            card.due = now.addingTimeInterval(-60)
            card.reps = 3
            card.lastReview = now.addingTimeInterval(-86_400)
            context.insert(card)
        }
        try context.save()
    }

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

    private func streakEndingYesterday(_ length: Int, in context: ModelContext) throws {
        for day in 1...length { try log(3, daysAgo: day, in: context) }
    }

    private func decks(_ context: ModelContext) throws -> [Deck] {
        try context.fetch(FetchDescriptor<Deck>())
    }

    private func logs(_ context: ModelContext) throws -> [ReviewLog] {
        try context.fetch(FetchDescriptor<ReviewLog>())
    }

    private func identifiers(_ scheduler: FakeScheduler) async -> Set<String> {
        Set(await scheduler.pendingRequests().map(\.identifier))
    }

    /// `now` (08:00) plus `hours` hours and `minutes` minutes, same calendar day.
    private func sameDay(plusHours hours: Int, minutes: Int = 0) -> Date {
        calendar.date(byAdding: .minute, value: minutes,
                      to: calendar.date(byAdding: .hour, value: hours, to: now)!)!
    }

    // MARK: - #129: a refusal must not silence the whole evening

    /// The bug: `apply` ended in `try? await add`, and by then the due-reminder
    /// had already been stood down and *removed*. A refusal therefore turned
    /// §5.5's one notification into none, silently, on the exact night the
    /// streak feature exists for.
    func testARefusedStreakReminderFallsBackToTheDueReminder() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()
        scheduler.addError = FakeScheduler.Failure.refused

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNotNil(outcome.due, "the evening must not go silent because the streak request was refused")
        XCTAssertEqual(outcome.due?.count, 5)
    }

    /// And the ordinary path is unchanged: the streak reminder still wins.
    func testAnAcceptedStreakReminderStillSuppressesTheDueReminder() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.due)
        // Hoisted: `await` inside an XCTAssert autoclosure does not compile.
        let pending = await identifiers(scheduler)
        XCTAssertEqual(pending, [StreakReminder.identifier])
    }

    /// The case that must **not** regress. After the streak reminder's own hour
    /// has passed, `plan` is `nil` even on an evening it already fired in — so
    /// nothing is scheduled, `apply` reports success because there was nothing to
    /// fail at, and the due-reminder still stands down. §5.5's one notification
    /// for the evening has been spent. This is #110's blocking bug.
    func testNothingToScheduleIsNotTreatedAsARefusal() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        // 20:30: the streak reminder's 20:00 has gone, the due-reminder's 21:00
        // has not.
        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: sameDay(plusHours: 12, minutes: 30), calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.streak, "its hour has passed")
        XCTAssertNil(outcome.due, "but the evening's one notification is already spent")
    }

    /// `apply`'s own contract, stated directly.
    func testApplyReportsWhetherTheEveningIsCovered() async throws {
        let plan = StreakReminder.Plan(fireDate: sameDay(plusHours: 12), length: 5)

        let ok = FakeScheduler()
        var covered = await StreakReminder.apply(plan, using: ok, calendar: calendar)
        XCTAssertTrue(covered, "accepted")

        let refusing = FakeScheduler()
        refusing.addError = FakeScheduler.Failure.refused
        covered = await StreakReminder.apply(plan, using: refusing, calendar: calendar)
        XCTAssertFalse(covered, "refused")

        covered = await StreakReminder.apply(nil, using: refusing, calendar: calendar)
        XCTAssertTrue(covered, "nothing to schedule is not a failure")
    }

    // MARK: - Acceptance: the due-reminder is suppressed that day

    /// Streak at 20:00, due-reminder at 21:00, both tonight. Only the streak one
    /// survives — and the due one is *removed*, not merely skipped, because a
    /// request from an earlier refresh may already be pending.
    func testTheStreakReminderWinsWhenBothWouldFireTheSameEvening() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.due, "the due-reminder must stand down")
        XCTAssertEqual(outcome.streak?.length, 12)
        let pending = await identifiers(scheduler)
        XCTAssertEqual(pending, [StreakReminder.identifier])
        XCTAssertTrue(scheduler.removals.contains([DailyReminder.identifier]),
                      "a pending due-reminder from an earlier refresh must be removed")
    }

    /// Suppression is per-evening, not blanket. Here the due-reminder's next fire
    /// is *tomorrow* morning — a different day — so both stand.
    func testBothStandWhenTheyFallOnDifferentDays() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(4, in: context)
        let scheduler = FakeScheduler()

        // 07:00 has passed (now is 08:00), so the due-reminder rolls to tomorrow.
        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 7 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNotNil(outcome.due)
        XCTAssertNotNil(outcome.streak)
        let pending = await identifiers(scheduler)
        XCTAssertEqual(pending, [StreakReminder.identifier, DailyReminder.identifier])
    }

    /// No streak to lose: the due-reminder is untouched by this card.
    func testTheDueReminderIsUnaffectedWhenThereIsNoStreak() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        let scheduler = FakeScheduler()

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNotNil(outcome.due)
        XCTAssertNil(outcome.streak)
        let pending = await identifiers(scheduler)
        XCTAssertEqual(pending, [DailyReminder.identifier])
    }

    /// A review lands, the app refreshes: the streak request goes, and the
    /// due-reminder — no longer suppressed — comes back on its own.
    func testAReviewTodayReleasesTheSuppressedDueReminder() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)
        let before = await identifiers(scheduler)
        XCTAssertEqual(before, [StreakReminder.identifier])

        try log(3, daysAgo: 0, in: context)
        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.streak)
        XCTAssertNotNil(outcome.due)
        let after = await identifiers(scheduler)
        XCTAssertEqual(after, [DailyReminder.identifier])
    }

    /// Reminders off: nothing is scheduled and both identifiers are cleared. The
    /// toggle in Settings is the app's only call site of `requestAuthorization`,
    /// so it governs both notifications (gotcha 63).
    func testTurningRemindersOffClearsBoth() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: false,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.due)
        XCTAssertNil(outcome.streak)
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    /// §7.2 counted in delivery attempts, not in pending requests: on a colliding
    /// evening exactly one `add` reaches the centre.
    func testOnlyOneNotificationIsEverAddedForAnEvening() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertEqual(scheduler.addCount, 1)
    }

    // MARK: - Acceptance: the streak reminder's hour has already passed tonight

    /// Finding 1's regression. The streak reminder fired at 20:00; a refresh at
    /// 20:30 recomputes `StreakReminder.plan` to `nil` (its own fire time has
    /// passed), but the evening's one notification is already spent — the
    /// due-reminder must not step in and fire a second one at 21:00.
    func testTheDueReminderStaysDownAfterTheStreakReminderHasFired() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: sameDay(plusHours: 12, minutes: 30), calendar: calendar, using: scheduler)

        XCTAssertNil(outcome.due, "the due-reminder must not take the streak reminder's place")
        XCTAssertNil(outcome.streak, "the streak reminder's own hour has already passed")
        XCTAssertEqual(scheduler.addCount, 0)
        let pending = await identifiers(scheduler)
        XCTAssertTrue(pending.isEmpty)
    }

    /// Same evening as above, but the streak reminder was actually scheduled by
    /// an earlier refresh (19:00) before the later one (20:30) recomputes it away.
    /// The due-reminder must stay absent across both.
    func testTheDueReminderStaysAbsentAfterAnEarlierRefreshScheduledTheStreakReminder() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        let first = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: sameDay(plusHours: 11), calendar: calendar, using: scheduler)
        XCTAssertNotNil(first.streak)
        let afterFirst = await identifiers(scheduler)
        XCTAssertEqual(afterFirst, [StreakReminder.identifier])

        let second = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 20 * 60,
            now: sameDay(plusHours: 12, minutes: 30), calendar: calendar, using: scheduler)

        XCTAssertNil(second.due, "the due-reminder must still stand down")
        let afterSecond = await identifiers(scheduler)
        XCTAssertTrue(afterSecond.isEmpty,
                      "the streak reminder recomputed to nil and was removed; nothing replaces it")
    }

    // MARK: - Acceptance: a streak time of midnight is off, not a suppressor

    /// Finding 2. `streakMinutes == 0` means the streak reminder is off — it must
    /// leave the due-reminder alone rather than suppressing it forever.
    func testAStreakTimeOfMidnightIsOffAndDoesNotSuppressTheDueReminder() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 5)
        try streakEndingYesterday(12, in: context)
        let scheduler = FakeScheduler()

        let outcome = await EveningReminder.refresh(
            decks: try decks(context), logs: try logs(context), enabled: true,
            reminderMinutes: 21 * 60, streakMinutes: 0,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNotNil(outcome.due, "midnight means the streak reminder is off, not suppressing")
        XCTAssertNil(outcome.streak)
        let pending = await identifiers(scheduler)
        XCTAssertEqual(pending, [DailyReminder.identifier])
    }

    // MARK: - Isolation

    /// The convenience overload fetches from a `ModelContext` belonging to the
    /// caller. Same rule as `DailyReminder.refresh`, same 2026-09-04 crash behind it.
    @MainActor
    func testRefreshStaysOnTheActorThatCalledIt() async throws {
        let (context, deck) = try makeStore()
        try addDueCards(context, to: deck, count: 3)
        try streakEndingYesterday(5, in: context)
        let scheduler = ThreadProbeScheduler()

        await EveningReminder.refresh(
            in: context, enabled: true, reminderMinutes: 21 * 60,
            streakMinutes: 20 * 60, now: now, using: scheduler)

        XCTAssertFalse(scheduler.onMainThread.isEmpty)
        XCTAssertTrue(scheduler.onMainThread.allSatisfy { $0 },
                      "refresh left the main actor — main thread per call: \(scheduler.onMainThread)")
    }

}
