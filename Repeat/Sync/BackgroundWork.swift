import Foundation
import SwiftData

/// Everything the daily background refresh does besides the sync itself (#139).
///
/// This lived as a closure inside `RepeatApp.init`, which is never
/// unit-instantiated — so none of it was reachable by a test, and one of the two
/// faults #139 fixes was a line that had simply never been written there. Pulling
/// it out leaves the closure a single call, which is about as little untested
/// wiring as this can be reduced to.
enum BackgroundWork {

    /// - Parameters:
    ///   - sceneIsActive: #109's guard. A badge is never announced while the owner
    ///     could be looking at it.
    ///   - scheduler: injected so a test can watch what was armed.
    @MainActor
    static func run(
        in context: ModelContext,
        settings: AppSettings,
        sceneIsActive: Bool,
        now: Date = .now,
        using scheduler: any NotificationScheduling = SystemNotificationScheduler()
    ) async {
        // §8: the day's snapshot must happen even if the app is never opened, and
        // even if this task is already expiring — it is the one thing §8 promises
        // unconditionally, so it runs before the cancellation check.
        try? BackupRunner.runIfNeeded(in: context)
        guard !Task.isCancelled else { return }

        // §7.2 (#139): the evening reminders are armed **here**, not only where a
        // sync completes.
        //
        // `SyncActor` calls `EveningReminder.refresh` immediately after
        // `verdict = .completed`, and every early return skips it — an empty work
        // set, `.notConfigured`, and all three `.failed` paths. So on an offline
        // day, or any day the sync fails, nothing armed the reminder at all. And
        // nothing else could: `HomeView.rebuildPlan()` is the only other caller and
        // it needs the app open, which is the one thing this feature assumes has
        // not happened.
        //
        // Arming twice on a day the sync does complete is harmless: `apply` removes
        // the pending request before it adds one.
        await EveningReminder.refresh(
            in: context,
            enabled: settings.reminderEnabled,
            reminderMinutes: settings.reminderMinutes,
            streakMinutes: settings.streakReminderMinutes,
            queueConfig: settings.queueConfig,
            now: now,
            using: scheduler
        )

        // §5.5 (#109): the one evaluation that runs with the app inactive. Home's
        // never does — it runs on `.active` — so this is the only caller, and the
        // scene check is the belt to that brace.
        await AchievementNotification.refresh(
            in: context,
            sceneIsActive: sceneIsActive,
            enabled: settings.reminderEnabled,
            queueConfig: settings.queueConfig,
            now: now,
            using: scheduler
        )
    }
}
