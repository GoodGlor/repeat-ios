import Foundation
import SwiftData
import UserNotifications
import Scheduling

/// The one entry point the app uses to bring the evening's notifications in line
/// (§5.5, §7.2, #110).
///
/// There are two evening reminders and the spec allows one a day. That rule is a
/// property of the **pair**, not of either one, so it lives here rather than in
/// `DailyReminder` — which predates gamification and should not learn what a
/// streak is — and rather than at the three call sites, where each would have to
/// re-implement it and one that forgot would deliver two notifications in an
/// evening.
///
/// The streak reminder wins because it is the stronger reason: the due-reminder
/// says work is waiting, which will be just as true tomorrow, while the streak
/// reminder says something the owner already has is about to be lost tonight.
enum EveningReminder {
    struct Outcome: Equatable {
        var streak: StreakReminder.Plan?
        var due: DailyReminder.Plan?
    }

    @discardableResult
    nonisolated(nonsending) static func refresh(
        decks: [Deck],
        logs: [ReviewLog],
        enabled: Bool,
        reminderMinutes: Int,
        streakMinutes: Int,
        frozenDays: Set<Date> = [],
        queueConfig: QueueConfig = QueueConfig(),
        now: Date = .now,
        calendar: Calendar = .current,
        using scheduler: any NotificationScheduling
    ) async -> Outcome {
        // The log is walked once, here, for the *condition* — independent of
        // whether tonight's fire time has already passed. `plan` below applies
        // the timing rule on top of that same risk rather than recomputing it
        // (#116).
        let risk = StreakReminder.lengthAtRisk(
            logs: logs, enabled: enabled, frozenDays: frozenDays, now: now, calendar: calendar
        )
        let streak = StreakReminder.plan(
            lengthAtRisk: risk, streakMinutes: streakMinutes, now: now, calendar: calendar
        )

        // Same *evening*, not "is there a streak reminder at all": the
        // due-reminder rolls to tomorrow once its hour has passed, and a
        // reminder for tomorrow morning collides with nothing tonight.
        let dueFireDate = DailyReminder.nextFireDate(
            after: now, reminderMinutes: reminderMinutes, calendar: calendar
        )

        // Keyed on the *condition*, not `streak`: once the streak reminder's own
        // hour has passed, `streak` goes back to `nil` even on the evening it
        // already fired — but the evening's one notification (§5.5) has already
        // been spent, so the due-reminder must still stand down. `streakMinutes >
        // 0` excludes the off setting (a streak time of midnight): see
        // `StreakReminder`'s doc comment.
        let collides = risk != nil && streakMinutes > 0
            && calendar.isDate(
                StreakReminder.fireDateToday(
                    streakMinutes: streakMinutes, now: now, calendar: calendar),
                inSameDayAs: dueFireDate
            )

        // Suppression rides `enabled:` deliberately. `DailyReminder.refresh` with
        // `false` already means "remove the pending request and schedule
        // nothing" — exactly what §5.5 asks for — so the rule costs #27 no change
        // at all, and its nine tests, including the one pinning the 2026-09-04
        // pull-to-refresh crash, stay untouched. Removal matters as much as the
        // skip: an earlier refresh may have left a due-reminder pending before
        // the streak became the stronger reason.
        // #129: the streak reminder goes **first**, and the due-reminder only
        // stands down once it is known to have landed.
        //
        // The old order scheduled the due-reminder first and the streak reminder
        // after, ending in `try? await add`. If the centre refused — authorisation
        // revoked, the 64-request limit reached — the evening's one notification
        // became *none*, silently, on the exact night the feature exists for.
        // Ordering it this way makes "one a day" a consequence of a success
        // rather than an assumption about one.
        //
        // `apply` answers `true` when there was nothing to schedule, and that
        // case has to stay `true`: once the streak reminder's hour has passed
        // `streak` is `nil` even on an evening it already fired in, and §5.5's
        // one notification is spent, so the due-reminder must still stand down.
        // That is #110's blocking bug; this must not undo it.
        let streakDelivered = await StreakReminder.apply(
            streak, using: scheduler, calendar: calendar
        )

        let due = await DailyReminder.refresh(
            decks: decks, logs: logs, enabled: enabled && !(collides && streakDelivered),
            reminderMinutes: reminderMinutes, queueConfig: queueConfig,
            now: now, calendar: calendar, using: scheduler
        )

        return Outcome(streak: streak, due: due)
    }

    /// Convenience for Home, Settings and the sync actor, which all hold a
    /// context. `nonisolated(nonsending)` for the reason `DailyReminder.refresh`
    /// records: the context is the caller's, and a context is only ever used on
    /// the actor that owns it.
    @discardableResult
    nonisolated(nonsending) static func refresh(
        in context: ModelContext,
        enabled: Bool,
        reminderMinutes: Int,
        streakMinutes: Int,
        queueConfig: QueueConfig = QueueConfig(),
        now: Date = .now,
        using scheduler: any NotificationScheduling = SystemNotificationScheduler()
    ) async -> Outcome {
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        return await refresh(
            decks: decks, logs: logs, enabled: enabled,
            reminderMinutes: reminderMinutes, streakMinutes: streakMinutes,
            frozenDays: Freeze.days(in: context),
            queueConfig: queueConfig, now: now, using: scheduler
        )
    }
}
