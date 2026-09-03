import Foundation
import BackgroundTasks

/// `BGAppRefreshTask` once a day, §4.2 trigger 5.
///
/// The identifier is declared in `project.yml` under
/// `BGTaskSchedulerPermittedIdentifiers`; registering one that isn't listed
/// crashes at launch, so the two must stay in step.
enum BackgroundRefresh {
    static let identifier = "com.goodglor.repeat.refresh"
    /// "Once a day if the app hasn't been opened" (§4.2). iOS treats this as the
    /// earliest it may run, not a promise — a phone that is never idle and never
    /// charged may go days without one, which is why every foreground also syncs.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Must be called before the app finishes launching, or `BGTaskScheduler`
    /// raises.
    /// `afterSync` runs on the main actor once the sync finishes, successfully or
    /// not. It is how §8's "backup runs without the app being opened that day" is
    /// met: this task is the only code that runs on a day nobody opens the app.
    /// Kept as a closure rather than a `ModelContainer` so this type stays free of
    /// SwiftData — and so a test can observe it without a store.
    static func register(coordinator: @escaping @MainActor @Sendable () -> SyncCoordinator?,
                         afterSync: @escaping @MainActor @Sendable () -> Void = {}) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Reschedule first: if the run below crashes or is killed, the next
            // one is already booked.
            schedule()
            handle(task: task, coordinator: coordinator, afterSync: afterSync)
        }
    }

    static func schedule(after interval: TimeInterval = interval, now: Date = .now) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        // Throws in the simulator and whenever the entitlement is missing. A
        // failure here costs a day's background sync, not correctness — every
        // foreground syncs too — so it is logged rather than raised.
        do { try BGTaskScheduler.shared.submit(request) }
        catch { print("[Repeat] background refresh not scheduled: \(error)") }
    }

    private static func handle(task: BGTask,
                               coordinator: @escaping @MainActor @Sendable () -> SyncCoordinator?,
                               afterSync: @escaping @MainActor @Sendable () -> Void) {
        let work = Task { @MainActor in
            guard let coordinator = coordinator() else {
                task.setTaskCompleted(success: false)
                return
            }
            let report = await coordinator.performAndWait(.backgroundRefresh)
            // Runs even when the sync did not: a phone that is offline for a week
            // still deserves its nightly snapshot of local scheduling.
            afterSync()
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
