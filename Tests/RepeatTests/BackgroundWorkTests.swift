import XCTest
import SwiftData
import UserNotifications
import Scheduling
@testable import Repeat

/// #139 — the work the daily background refresh does when the app is never opened.
///
/// Until this card that work was a closure inside `RepeatApp.init`, which is never
/// unit-instantiated, so none of it was covered. The fault it was hiding: the
/// evening reminder was armed only where a sync *completed*, so an offline day
/// armed nothing at all — on precisely the day the app is never opened, which is
/// the day the feature exists for.
@MainActor
final class BackgroundWorkTests: XCTestCase {

    /// 2027-01-15 08:00 UTC — morning, so an evening reminder is still ahead.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    /// Its own defaults suite: `AppSettings` is `UserDefaults.standard` by default
    /// and these tests must not depend on, or disturb, the process's real settings.
    private func settings(remindersOn: Bool) throws -> AppSettings {
        let name = "background-work-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.reminderEnabled = remindersOn
        return settings
    }

    /// A deck with cards due now, so the daily reminder has something to announce.
    private func seedDueWork(in context: ModelContext) throws {
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        for index in 0..<3 {
            let note = Note(deck: deck, front: "f\(index)", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            card.state = .review
            card.due = now.addingTimeInterval(-3600)
            card.reps = 3
            card.lastReview = now.addingTimeInterval(-86_400)
            context.insert(card)
        }
        try context.save()
    }

    // MARK: - The fault this card exists for

    /// **No sync happens in this test at all.** That is the point: this is the
    /// offline day, the `.notConfigured` day and the failed-sync day, all of which
    /// returned before `SyncActor` ever reached `EveningReminder.refresh`.
    func testTheEveningReminderIsArmedWithNoSyncAtAll() async throws {
        let context = try makeContext()
        try seedDueWork(in: context)
        let scheduler = FakeScheduler()

        await BackgroundWork.run(in: context, settings: try settings(remindersOn: true),
                                 sceneIsActive: false, now: now, using: scheduler)

        let pending = await scheduler.pendingRequests()
        XCTAssertFalse(pending.isEmpty,
                       "nothing was armed — this is the day the app is never opened")
        XCTAssertTrue(pending.contains { $0.identifier == DailyReminder.identifier },
                      "armed: \(pending.map(\.identifier))")
    }

    func testRemindersOffStillArmNothing() async throws {
        let context = try makeContext()
        try seedDueWork(in: context)
        let scheduler = FakeScheduler()

        await BackgroundWork.run(in: context, settings: try settings(remindersOn: false),
                                 sceneIsActive: false, now: now, using: scheduler)

        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty, "armed: \(pending.map(\.identifier))")
    }

    /// Running it twice is what happens on a day the sync *does* complete —
    /// `SyncActor` arms the reminder as well. `apply` removes before it adds, so
    /// the owner still gets one.
    func testRunningTwiceLeavesOneRequest() async throws {
        let context = try makeContext()
        try seedDueWork(in: context)
        let scheduler = FakeScheduler()
        let appSettings = try settings(remindersOn: true)

        await BackgroundWork.run(in: context, settings: appSettings,
                                 sceneIsActive: false, now: now, using: scheduler)
        await BackgroundWork.run(in: context, settings: appSettings,
                                 sceneIsActive: false, now: now, using: scheduler)

        let pending = await scheduler.pendingRequests()
        XCTAssertEqual(pending.filter { $0.identifier == DailyReminder.identifier }.count, 1)
    }

    // MARK: - The slot no longer drifts

    func testTheSlotIsTomorrowsAnchorOnceTodaysHasPassed() throws {
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now))
        let next = BackgroundRefresh.nextBegin(after: morning, calendar: calendar)

        XCTAssertGreaterThan(next, morning)
        XCTAssertEqual(calendar.component(.hour, from: next), 5)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)
    }

    func testTheSlotIsTodaysAnchorWhenItIsStillAhead() throws {
        let veryEarly = try XCTUnwrap(calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now))
        let next = BackgroundRefresh.nextBegin(after: veryEarly, calendar: calendar)

        XCTAssertTrue(calendar.isDate(next, inSameDayAs: veryEarly), "\(next)")
        XCTAssertEqual(calendar.component(.hour, from: next), 5)
    }

    /// The defect, pinned. `now + 24h` walked the slot forward to wherever iOS last
    /// ran it; three runs at three different hours used to give three different
    /// times of day, and once one landed after the streak hour the reminder could
    /// never be armed again. They now all name the same wall-clock moment.
    func testTheSlotDoesNotDriftWithWhenTheLastRunHappened() throws {
        let hours = [1, 9, 23]
        let wallClocks = try hours.map { hour -> DateComponents in
            let ran = try XCTUnwrap(
                calendar.date(bySettingHour: hour, minute: 17, second: 0, of: now))
            let next = BackgroundRefresh.nextBegin(after: ran, calendar: calendar)
            XCTAssertGreaterThan(next, ran)
            return calendar.dateComponents([.hour, .minute], from: next)
        }
        XCTAssertEqual(Set(wallClocks.map { "\($0.hour ?? -1):\($0.minute ?? -1)" }).count, 1,
                       "the slot still depends on when the last run happened: \(wallClocks)")

        let old = now.addingTimeInterval(BackgroundWorkTests.oldInterval)
        XCTAssertNotEqual(BackgroundRefresh.nextBegin(after: now, calendar: calendar), old,
                          "still adding 24 hours")
    }

    /// The anchor has to be earlier in the day than any reminder the owner can set,
    /// or the refresh that arms tonight's reminder can run after it would have
    /// fired — which is the whole of fault 2.
    func testTheAnchorIsEarlierThanEveryReminderHourTheOwnerCanChoose() {
        XCTAssertLessThan(BackgroundRefresh.anchorMinutes, AppSettings.defaultReminderMinutes)
        XCTAssertLessThan(BackgroundRefresh.anchorMinutes, AppSettings.defaultStreakReminderMinutes)
    }

    private static let oldInterval: TimeInterval = 24 * 60 * 60
}
