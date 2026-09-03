import Foundation
import SwiftData
import GoogleSheets

/// What one sync run did, or why it did nothing.
struct SyncReport: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        case completed
        /// §4.2: an `appActive` trigger inside the 10-minute window.
        case throttled
        /// No key or no spreadsheet id yet — not an error, just nothing to do.
        case notConfigured
        /// The run failed. `message` is already owner-readable (§4.6).
        case failed(message: String, needsSettingsAttention: Bool, isOffline: Bool)
    }

    var verdict: Verdict = .completed
    var work: SyncWork = []
    var pull = PullResult()
    var push = PushResult()
    var log = LogPushResult()
    var finishedAt: Date?

    var didRun: Bool { if case .completed = verdict { true } else { false } }

    static let throttled = SyncReport(verdict: .throttled)
    static let notConfigured = SyncReport(verdict: .notConfigured)
}

/// Serialises every sync (§4.2, §4.5, §4.6).
///
/// The point of the actor is not concurrency — it is the *absence* of it. Pull
/// and push both rewrite the same rows, and the pull's own conflict rules assume
/// nothing else is mutating the store underneath it. One place decides the order,
/// and only one run happens at a time.
///
/// Coalescing rather than queueing: a trigger that arrives during a run cannot be
/// served by that run — the run may already have read the rows the trigger is
/// about — so it schedules exactly **one** follow-up, no matter how many triggers
/// pile up behind it. Ten foreground/background flips produce at most two runs,
/// never ten.
///
/// The offline queue is the store itself. `Note.pendingUpload` and
/// `ReviewLog.uploaded` already survive a relaunch, so "queue everything and
/// drain on reconnect" needs no separate queue — only a trigger when the network
/// returns, which is what `.reconnected` is for.
actor SyncActor {
    private let context: ModelContext
    private let makeClient: @Sendable () throws -> SheetsClient
    private let now: @Sendable () -> Date
    /// The same cap Home builds its plan with, so the published count is the one
    /// Home would show.
    private let queueConfig: QueueConfig
    /// Read at construction: the actor runs off the main actor and cannot reach
    /// `@Observable` settings, and a stale reminder time is corrected on the next
    /// foreground anyway.
    private let reminder: ReminderConfiguration

    struct ReminderConfiguration: Sendable {
        var enabled = false
        var minutes = AppSettings.defaultReminderMinutes
        var scheduler: any NotificationScheduling = SystemNotificationScheduler()
    }

    private var inFlight: Task<SyncReport, Never>?
    /// The union of work asked for while a run was in flight. One follow-up runs
    /// it, whatever number of triggers contributed.
    private var queued: SyncWork = []
    /// When the last *attempt* finished, successful or not. §4.2 throttles the
    /// trigger, not the success: a phone that cannot reach Google must not retry
    /// on every foreground.
    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessAt: Date?

    init(
        container: ModelContainer,
        makeClient: @escaping @Sendable () throws -> SheetsClient,
        now: @escaping @Sendable () -> Date = { .now },
        queueConfig: QueueConfig = QueueConfig(),
        reminder: ReminderConfiguration = ReminderConfiguration()
    ) {
        // The actor's own context. SwiftData contexts are not shareable, and the
        // UI's context must stay on the main thread — this is the one place sync
        // writes, and it is off the main actor by construction (§4.2: "sync never
        // blocks the UI").
        self.context = ModelContext(container)
        self.makeClient = makeClient
        self.now = now
        self.queueConfig = queueConfig
        self.reminder = reminder
    }

    /// Runs a sync for `trigger`, or explains why it didn't.
    ///
    /// Safe to call from anywhere, as often as you like — that is the whole
    /// contract. Callers do not check whether a sync is already running.
    @discardableResult
    func sync(_ trigger: SyncTrigger) async -> SyncReport {
        if let interval = trigger.throttleInterval,
           let last = lastAttemptAt,
           now().timeIntervalSince(last) < interval {
            return .throttled
        }

        if let inFlight {
            queued.formUnion(trigger.work)
            return await inFlight.value
        }
        return await start(work: trigger.work)
    }

    /// Stops the run in progress at its next step boundary.
    ///
    /// The run lives in an unstructured `Task` so several coalesced callers can
    /// share it, which means it does *not* inherit their cancellation — the
    /// background task's expiry handler has to say so explicitly. Everything
    /// unfinished stays queued in the store, so this is a pause, not a rollback.
    func cancelCurrentRun() {
        inFlight?.cancel()
    }

    /// Everything the status line needs (#19), read in one hop.
    func state() -> (lastSuccessAt: Date?, lastAttemptAt: Date?, isRunning: Bool) {
        (lastSuccessAt, lastAttemptAt, inFlight != nil)
    }

    // MARK: - The run

    private func start(work: SyncWork) async -> SyncReport {
        let task = Task { await self.run(work: work) }
        inFlight = task
        let report = await task.value
        inFlight = nil
        lastAttemptAt = report.finishedAt ?? now()
        if report.didRun { lastSuccessAt = lastAttemptAt }

        guard !queued.isEmpty else { return report }
        let follow = queued
        queued = []
        return await start(work: follow)
    }

    private func run(work: SyncWork) async -> SyncReport {
        var report = SyncReport(work: work)

        let client: SheetsClient
        do {
            client = try makeClient()
        } catch {
            report.verdict = .notConfigured
            report.finishedAt = now()
            return report
        }

        do {
            // Discovery runs for every work set, not only for a pull. A push
            // needs the header maps to know which column is which, and a `_log`
            // push needs to know whether the tab exists at all.
            let discovery = try await SheetDiscovery(client: client).run(in: context, now: now())
            // §5.1: `_meta` has the last word on weights and retention. Persisted
            // rather than returned, because scheduling has to work offline and
            // `_meta` is only readable when the network is.
            discovery.metaOverrides.save()
            try Task.checkCancellation()

            // Pull before push (§4.4 step 4): the Sheet wins on content, and the
            // pull deliberately leaves `pendingUpload` notes alone so the push
            // that follows still has them.
            if work.contains(.pull) {
                report.pull = try await SheetPull(client: client).run(
                    discovery: discovery, in: context, now: now())
                try Task.checkCancellation()
            }
            if work.contains(.push) {
                report.push = try await SheetPush(client: client).run(
                    discovery: discovery, in: context, now: now())
                try Task.checkCancellation()
            }
            if work.contains(.log) {
                report.log = try await LogPush(client: client).run(
                    discovery: discovery, in: context)
            }
            report.verdict = .completed
            // §7.1: on a day the app is never opened, the daily background
            // refresh is the only thing that can move the widget off yesterday's
            // number.
            DueCountPublisher.publish(from: context, config: queueConfig, now: now())
            // §7.2: the background refresh is the only thing that can cancel a
            // reminder which has become false since the app was last opened.
            await DailyReminder.refresh(
                in: context,
                enabled: reminder.enabled,
                reminderMinutes: reminder.minutes,
                queueConfig: queueConfig,
                now: now(),
                using: reminder.scheduler
            )
        } catch is CancellationError {
            // The background task's expiry handler cancels mid-run. Everything
            // unfinished is still queued in the store, so this is a pause, not a
            // failure — reporting it as one would light up the error banner every
            // time iOS reclaimed the budget.
            report.verdict = .failed(message: Localized.string("Синхронізацію перервано."),
                                     needsSettingsAttention: false, isOffline: false)
        } catch let error as SheetsError {
            report.verdict = .failed(
                message: error.description,
                needsSettingsAttention: error.needsSettingsAttention,
                isOffline: Self.isOffline(error))
        } catch {
            report.verdict = .failed(message: error.localizedDescription,
                                     needsSettingsAttention: false, isOffline: false)
        }

        report.finishedAt = now()
        return report
    }

    /// "Offline" and "Google is broken" read the same to the code but need
    /// opposite words on Home (§4.2): one says changes will sync later, the other
    /// asks the owner to look at Settings.
    private static func isOffline(_ error: SheetsError) -> Bool {
        switch error {
        case .transport:
            return true
        case .auth(let authError):
            // The token request is the FIRST network call of every sync, and on a
            // cold launch there is no cached token — so with no signal the failure
            // that actually surfaces is a token fetch that could not reach
            // `oauth2.googleapis.com`. `SheetsClient` rethrows that as `.auth`
            // because it came from the auth path, and this used to read it as a
            // credential problem: the phone said "Не вдалося синхронізувати"
            // and pointed at Settings when the only thing wrong was the network.
            //
            // A key is not rejected by a request that never arrived.
            if case .transport = authError { return true }
            return false
        default:
            return false
        }
    }
}
