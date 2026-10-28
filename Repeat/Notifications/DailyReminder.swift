import Foundation
import SwiftData
import UserNotifications
import Scheduling

/// One local notification a day, and never a false one (§7.2).
///
/// The difficulty is that a notification scheduled tonight has to still be true
/// tomorrow evening, and iOS will not re-evaluate it. Two things keep it honest:
///
/// 1. **The count is computed for the moment it will fire**, not for now. The
///    queue builder is asked what the plan looks like *at* the reminder time, so
///    "cards to review" means cards that will actually be waiting then.
/// 2. **Nothing is scheduled when that count is zero**, and every refresh
///    replaces the pending request. The app refreshes on foreground, at session
///    end and after every sync — including the daily background refresh, which is
///    what §7.2 means by "checked in the background refresh task".
enum DailyReminder {
    /// One identifier, forever. This is what makes changing the time *reschedule*
    /// rather than stack: every refresh removes it first, and a second `add` with
    /// the same identifier would replace it regardless.
    static let identifier = "com.goodglor.repeat.daily-reminder"

    struct Plan: Equatable {
        var fireDate: Date
        var count: Int
    }

    /// When the reminder should next fire, and how many cards will be waiting.
    ///
    /// `nil` when there is nothing worth saying — reminders off, or a queue that
    /// will be empty at that hour. A notification reading "0 cards" is worse than
    /// no notification at all.
    static func plan(
        decks: [Deck],
        logs: [ReviewLog],
        enabled: Bool,
        reminderMinutes: Int,
        queueConfig: QueueConfig = QueueConfig(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Plan? {
        guard enabled else { return nil }
        let fireDate = nextFireDate(after: now, reminderMinutes: reminderMinutes, calendar: calendar)

        // The plan *at the fire time*: cards due by then, under the same caps
        // Home applies. Asking "what is due now" would promise cards that are
        // already answered, and hide ones that come due in between.
        var generator = SystemRandomNumberGenerator()
        let upcoming = QueueBuilder.plan(
            decks: decks,
            now: fireDate,
            config: queueConfig,
            recentLogs: logs,
            logsToday: logs.filter { calendar.isDate($0.reviewedAt, inSameDayAs: fireDate) },
            calendar: calendar,
            using: &generator
        )

        guard upcoming.count > 0 else { return nil }
        return Plan(fireDate: fireDate, count: upcoming.count)
    }

    /// The next occurrence of the chosen time, **strictly** after `now`: a refresh
    /// running at exactly 21:00:00 must schedule tomorrow's reminder, not one
    /// firing in the same instant.
    static func nextFireDate(
        after now: Date,
        reminderMinutes: Int,
        calendar: Calendar = .current
    ) -> Date {
        // #128: asked of the calendar rather than added to midnight, so the hour
        // survives a DST transition.
        ReminderTime.next(after: now, minutes: reminderMinutes, calendar: calendar)
    }

    /// §7.2's body. It used to read "Картки до повторення: N" — the count pushed
    /// after a colon precisely to dodge the three plural forms Ukrainian needs.
    /// #38 supplies them, so it can be a sentence.
    static func body(count: Int, locale: Locale = .current) -> String {
        Localized.string("\(count) картка чекає на повторення", locale: locale)
    }

    static var title: String { Localized.string("Час повторити") }

    // MARK: - Applying

    /// Brings the scheduled notification in line with the plan. Idempotent.
    ///
    /// `nonisolated(nonsending)`: the body runs on the **caller's** actor. Without
    /// it a `nonisolated async` function hops to the cooperative pool on entry, so
    /// `decks` and `logs` — SwiftData models belonging to whoever called — were
    /// being read on a background thread while the main thread rendered them. On
    /// the owner's phone, pull-to-refresh made that a crash three times out of
    /// three (2026-09-04), each with a different signal: SIGSEGV in
    /// `ReviewLog.stateBefore`, a SwiftData assertion, and an over-release abort.
    @discardableResult
    nonisolated(nonsending) static func refresh(
        decks: [Deck],
        logs: [ReviewLog],
        enabled: Bool,
        reminderMinutes: Int,
        queueConfig: QueueConfig = QueueConfig(),
        now: Date = .now,
        calendar: Calendar = .current,
        using scheduler: any NotificationScheduling
    ) async -> Plan? {
        // Removed first, always. Rescheduling without this is how a changed
        // reminder time ends up delivering two notifications.
        await scheduler.removePending(identifiers: [identifier])

        guard let plan = plan(
            decks: decks, logs: logs, enabled: enabled, reminderMinutes: reminderMinutes,
            queueConfig: queueConfig, now: now, calendar: calendar
        ) else { return nil }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body(count: plan.count)
        content.sound = .default
        content.userInfo = ["url": DeepLink.study]

        // A one-shot date trigger, not a repeating one: a repeating daily trigger
        // would keep firing with a count frozen at whatever was true the day it
        // was created — the false notification this card exists to prevent.
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: plan.fireDate
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await scheduler.add(request)
        return plan
    }

    /// Convenience for the app and the sync actor, which both hold a context.
    ///
    /// The context is the caller's — Home passes the **main** one — and a context
    /// is only ever used on the actor that owns it. Same annotation, same reason.
    @discardableResult
    nonisolated(nonsending) static func refresh(
        in context: ModelContext,
        enabled: Bool,
        reminderMinutes: Int,
        queueConfig: QueueConfig = QueueConfig(),
        now: Date = .now,
        using scheduler: any NotificationScheduling = SystemNotificationScheduler()
    ) async -> Plan? {
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        return await refresh(
            decks: decks, logs: logs, enabled: enabled, reminderMinutes: reminderMinutes,
            queueConfig: queueConfig, now: now, using: scheduler
        )
    }
}
