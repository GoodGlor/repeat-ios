import Foundation
import BackgroundTasks

/// `BGAppRefreshTask` once a day, §4.2 trigger 5.
///
/// The identifier is declared in `project.yml` under
/// `BGTaskSchedulerPermittedIdentifiers`; registering one that isn't listed
/// crashes at launch, so the two must stay in step.
enum BackgroundRefresh {
    static let identifier = "com.goodglor.repeat.refresh"
    /// "Once a day if the app hasn't been opened" (§4.2), anchored to **05:00
    /// local** rather than to 24 hours after whenever the last run happened.
    ///
    /// iOS treats this as the earliest it may run, not a promise — a phone that is
    /// never idle and never charged may go days without one, which is why every
    /// foreground also syncs.
    ///
    /// #139: `now + 24h` made the slot walk forward to wherever iOS last chose to
    /// run it, and the handler reschedules itself first thing, so the walk
    /// compounds. Once it settled past the streak hour the reminder was armed too
    /// late to be armed at all — #110's rule is that the streak reminder can only
    /// ever be scheduled for *tonight*, because with no review today the streak
    /// breaks at midnight. A drifted slot meant silence every night, permanently.
    ///
    /// 05:00 because it is earlier than any reminder hour the owner can pick, so
    /// the refresh that arms tonight's reminder always runs before it could fire.
    static let anchorMinutes = 5 * 60

    /// Must be called before the app finishes launching, or `BGTaskScheduler`
    /// raises.
    /// `afterSync` runs on the main actor once the sync finishes, successfully or
    /// not, and is awaited, so the task is not reported complete under it. It is
    /// how §8's "backup runs without the app being opened that day" is met: this
    /// task is the only code that runs on a day nobody opens the app.
    /// Kept as a closure rather than a `ModelContainer` so this type stays free of
    /// SwiftData — and so a test can observe it without a store.
    static func register(coordinator: @escaping @MainActor @Sendable () -> SyncCoordinator?,
                         afterSync: @escaping @MainActor @Sendable () async -> Void = {}) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Reschedule first: if the run below crashes or is killed, the next
            // one is already booked.
            schedule()
            handle(task: task, coordinator: coordinator, afterSync: afterSync)
        }
    }

    /// The next moment the wall clock reads `anchorMinutes`.
    ///
    /// Through `ReminderTime` (#128) rather than by adding seconds, so it does not
    /// drift an hour across a DST boundary the way both evening reminders did.
    static func nextBegin(after now: Date = .now, calendar: Calendar = .current) -> Date {
        ReminderTime.next(after: now, minutes: anchorMinutes, calendar: calendar)
    }

    static func schedule(now: Date = .now, calendar: Calendar = .current) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = nextBegin(after: now, calendar: calendar)
        // Throws in the simulator and whenever the entitlement is missing. A
        // failure here costs a day's background sync, not correctness — every
        // foreground syncs too — so it is logged rather than raised.
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("[Repeat] background refresh not scheduled: \(error)") }
    }

    private static func handle(task: BGTask,
                               coordinator: @escaping @MainActor @Sendable () -> SyncCoordinator?,
                               afterSync: @escaping @MainActor @Sendable () async -> Void) {
        let work = Task { @MainActor in
            guard let coordinator = coordinator() else {
                task.setTaskCompleted(success: false)
                return
            }
            let report = await coordinator.performAndWait(.backgroundRefresh)
            // Runs even when the sync did not: a phone that is offline for a week
            // still deserves its nightly snapshot of local scheduling.
            await afterSync()
            task.setTaskCompleted(success: report.didRun)
        }
        // The budget is seconds, not minutes. Cancelling propagates through the
        // actor's `Task.checkCancellation` calls, so an interrupted run stops at
        // the next step boundary with everything still queued — #17's per-chunk
        // saves mean even a half-finished `_log` push keeps what it sent.
        task.expirationHandler = {
            work.cancel()
            // Cancelling `work` alone is not enough: the actor's run is
            // unstructured so that coalesced callers can share it, so it has to
            // be told directly.
            Task { @MainActor in coordinator()?.cancelRunningSync() }
        }
    }
}
