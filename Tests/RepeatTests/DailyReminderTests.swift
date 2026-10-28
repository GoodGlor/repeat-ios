import XCTest
import SwiftData
import UserNotifications
import Scheduling
@testable import Repeat

/// #27 — one notification a day, and never a false one.
final class DailyReminderTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let evening = 21 * 60

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    @discardableResult
    private func addCards(_ context: ModelContext, to deck: Deck, count: Int, due: Date) -> [Card] {
        var cards: [Card] = []
        for index in 0..<count {
            let note = Note(deck: deck, front: "f\(index)", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            // A reviewed card carries the evidence of its review. Setting `state`
            // without `lastReview` and `reps` describes a card the app cannot
            // produce — `rate()` writes all three from one snapshot — and #84's
            // queue reads `lastReview` as the queryable stand-in for "not new".
            // `QueueBuilderTests` has always built its fixtures this way.
            card.state = .review
            card.due = due
            card.reps = 3
            card.lastReview = due.addingTimeInterval(-86_400)
            context.insert(card)
            cards.append(card)
        }
        return cards
    }

    private func decks(_ context: ModelContext) throws -> [Deck] {
        try context.fetch(FetchDescriptor<Deck>())
    }

    // MARK: - Acceptance: no notification when there is nothing to review

    func testNothingIsScheduledWhenTheQueueWillBeEmpty() async throws {
        let (context, deck) = try makeStore()
        // Everything answered today and scheduled well past tomorrow evening.
        addCards(context, to: deck, count: 6, due: now.addingTimeInterval(9 * 86_400))
        try context.save()

        let scheduler = FakeScheduler()
        let plan = await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: evening,
            now: now, calendar: calendar, using: scheduler
        )

        XCTAssertNil(plan)
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty, "a notification reading 0 cards is worse than none")
        XCTAssertEqual(scheduler.removals, [[DailyReminder.identifier]],
                       "the stale request is removed even when nothing replaces it")
    }

    /// The count is computed for the moment it will fire, not for now — a card
    /// that comes due between now and then still counts.
    func testTheCountIsTheQueueAtTheFireTimeNotAtSchedulingTime() async throws {
        let (context, deck) = try makeStore()
        let fireDate = DailyReminder.nextFireDate(
            after: now, reminderMinutes: evening, calendar: calendar)

        addCards(context, to: deck, count: 2, due: now.addingTimeInterval(-3600))
        // Due at lunchtime tomorrow — nothing at 08:00 now, but waiting by 21:00.
        addCards(context, to: deck, count: 3, due: fireDate.addingTimeInterval(-2 * 3600))
        // Due after the reminder: not promised.
        addCards(context, to: deck, count: 4, due: fireDate.addingTimeInterval(3600))
        try context.save()

        let scheduler = FakeScheduler()
        let scheduledPlan = await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: evening,
            now: now, calendar: calendar, using: scheduler
        )
        let plan = try XCTUnwrap(scheduledPlan)

        XCTAssertEqual(plan.count, 5, "two overdue plus three that come due before the reminder")
        XCTAssertEqual(plan.fireDate, fireDate)

        let scheduled = await scheduler.pendingRequests()
        let request = try XCTUnwrap(scheduled.first)
        // Compared against the helper rather than a literal: the notification is
        // built in the reader's language, and this test asserts the *count* that
        // reached it, not which language the phone happens to be set to.
        XCTAssertEqual(request.content.body, DailyReminder.body(count: 5))
        XCTAssertEqual(request.identifier, DailyReminder.identifier)
    }

    func testTurningRemindersOffSchedulesNothing() async throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 5, due: now.addingTimeInterval(-60))
        try context.save()

        let scheduler = FakeScheduler()
        let plan = await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: false, reminderMinutes: evening,
            now: now, calendar: calendar, using: scheduler
        )

        XCTAssertNil(plan)
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Acceptance: changing the time reschedules rather than stacking

    func testChangingTheTimeReschedulesRatherThanStacking() async throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 4, due: now.addingTimeInterval(-60))
        try context.save()
        let scheduler = FakeScheduler()

        await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: 21 * 60,
            now: now, calendar: calendar, using: scheduler)
        await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: 9 * 60,
            now: now, calendar: calendar, using: scheduler)
        await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: 7 * 60 + 30,
            now: now, calendar: calendar, using: scheduler)

        let pending = await scheduler.pendingRequests()
        XCTAssertEqual(pending.count, 1, "three changes, one notification")

        let trigger = try XCTUnwrap(pending.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 7)
        XCTAssertEqual(trigger.dateComponents.minute, 30)
        XCTAssertFalse(trigger.repeats,
                       "a repeating trigger would keep firing with a frozen count")
    }

    // MARK: - The fire date

    func testTheNextFireDateIsStrictlyInTheFuture() {
        // 08:00 now, reminder at 21:00 → tonight.
        let tonight = DailyReminder.nextFireDate(after: now, reminderMinutes: evening, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: tonight).hour, 21)
        XCTAssertEqual(calendar.dateComponents([.day], from: tonight).day,
                       calendar.dateComponents([.day], from: now).day)

        // 08:00 now, reminder at 07:00 → tomorrow.
        let tomorrow = DailyReminder.nextFireDate(after: now, reminderMinutes: 7 * 60, calendar: calendar)
        XCTAssertGreaterThan(tomorrow, now)
        XCTAssertEqual(tomorrow.timeIntervalSince(now), 23 * 3600)

        // Exactly on the hour → tomorrow, not this instant.
        let onTheHour = calendar.startOfDay(for: now).addingTimeInterval(8 * 3600)
        let next = DailyReminder.nextFireDate(after: onTheHour, reminderMinutes: 8 * 60, calendar: calendar)
        XCTAssertEqual(next.timeIntervalSince(onTheHour), 86_400)
    }

    func testTheBodyAvoidsUkrainianPluralAgreement() {
        // Ukrainian needs three forms for a generated count (#38); the colon
        // sidesteps all of them.
        // The count used to sit after a colon to dodge Ukrainian's three plural
        // forms. #38 supplies them, so it reads as a sentence.
        XCTAssertEqual(DailyReminder.body(count: 1, locale: Locale(identifier: "uk")), "1 картка чекає на повторення")
        XCTAssertEqual(DailyReminder.body(count: 3, locale: Locale(identifier: "uk")), "3 картки чекають на повторення")
        XCTAssertEqual(DailyReminder.body(count: 11, locale: Locale(identifier: "uk")), "11 карток чекає на повторення")
        XCTAssertEqual(DailyReminder.body(count: 21, locale: Locale(identifier: "uk")), "21 картка чекає на повторення")
    }

    func testTheNotificationDeepLinksIntoASession() async throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 2, due: now.addingTimeInterval(-60))
        try context.save()
        let scheduler = FakeScheduler()

        await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: evening,
            now: now, calendar: calendar, using: scheduler)

        let scheduled = await scheduler.pendingRequests()
        let request = try XCTUnwrap(scheduled.first)
        XCTAssertEqual(request.content.userInfo["url"] as? String, DeepLink.study)
    }

    /// Suspended cards are not due, so a deck put aside must not generate a
    /// reminder.
    func testASuspendedDeckDoesNotGenerateAReminder() async throws {
        let (context, deck) = try makeStore()
        let cards = addCards(context, to: deck, count: 4, due: now.addingTimeInterval(-60))
        for card in cards { card.isSuspended = true }
        try context.save()

        let scheduler = FakeScheduler()
        let plan = await DailyReminder.refresh(
            decks: try decks(context), logs: [], enabled: true, reminderMinutes: evening,
            now: now, calendar: calendar, using: scheduler)

        XCTAssertNil(plan)
    }

    // MARK: - Isolation (the pull-to-refresh crash, 2026-09-04)

    /// Records which thread `refresh` was on each time it called in.
    ///
    /// `nonisolated(nonsending)` keeps these methods on their **caller's** executor,
    /// so what they record is the executor of `refresh`'s body — the thing under
    /// test — and not a hop of their own.
    private final class ThreadProbeScheduler: NotificationScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var onMainThread: [Bool] = []

        private func record() {
            lock.lock(); defer { lock.unlock() }
            onMainThread.append(pthread_main_np() != 0)
        }

        nonisolated(nonsending) func pendingRequests() async -> [UNNotificationRequest] { record(); return [] }
        nonisolated(nonsending) func removePending(identifiers: [String]) async { record() }
        nonisolated(nonsending) func add(_ request: UNNotificationRequest) async throws { record() }
        nonisolated(nonsending) func requestAuthorization() async -> Bool { record(); return true }
    }

    /// `refresh` reads a `ModelContext` and the models it fetches. Those belong to
    /// whoever called — Home hands over the **main** context — so the body has to
    /// run on the caller's actor. A plain `nonisolated async` function does not: it
    /// hops to the cooperative pool on entry. Three crash reports from the owner's
    /// phone put it exactly there, reading `ReviewLog.stateBefore` on thread 6 while
    /// the main thread was rendering the same objects.
    @MainActor
    func testRefreshStaysOnTheActorThatCalledIt() async throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 3, due: now)
        let scheduler = ThreadProbeScheduler()

        await DailyReminder.refresh(
            in: context, enabled: true, reminderMinutes: evening, now: now, using: scheduler
        )

        XCTAssertEqual(scheduler.onMainThread.count, 2, "expected a removal and an add")
        XCTAssertTrue(scheduler.onMainThread.allSatisfy { $0 },
                      "refresh left the main actor — main thread per call: \(scheduler.onMainThread)")
    }
}
