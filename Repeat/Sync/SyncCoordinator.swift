import Foundation
import SwiftData
import Observation

/// The app's single entry point to sync (§4.2).
///
/// Everything the UI knows about syncing goes through here: one call per trigger,
/// never awaited. `trigger(_:)` returns immediately and the work happens on the
/// actor — §4.2's "sync never blocks the UI" is a property of this method's
/// signature rather than a discipline every call site has to remember.
@MainActor
@Observable
final class SyncCoordinator {
    /// What Home's status line shows (§4.2, #19).
    enum Status: Equatable {
        case idle
        case syncing
        /// Changes are queued; the phone will send them when it can.
        case offline
        /// `needsAttention` distinguishes "Google is having a bad day" from
        /// "your key is wrong", which need different words and a Settings link.
        case failed(message: String, needsAttention: Bool)
        case notConfigured
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastReport: SyncReport?

    private let actor: SyncActor
    private let reachability: NetworkReachability?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var debounce: Task<Void, Never>?

    init(
        actor: SyncActor,
        reachability: NetworkReachability? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.actor = actor
        self.reachability = reachability
        self.sleep = sleep
    }

    /// Wires the app's container in one line.
    ///
    /// The credential is read on each run rather than captured: the actor is off
    /// the main actor and `SheetsSettings` is `@Observable` UI state, so passing
    /// the object across would be both unsafe and stale.
    convenience init(
        container: ModelContainer,
        reachability: NetworkReachability? = PathReachability(),
        queueConfig: QueueConfig = AppSettings().queueConfig,
        reminder: SyncActor.ReminderConfiguration = {
            let settings = AppSettings()
            return .init(enabled: settings.reminderEnabled, minutes: settings.reminderMinutes)
        }()
    ) {
        self.init(
            actor: SyncActor(
                container: container,
                makeClient: { try SheetsSettings.makeClient() },
                queueConfig: queueConfig,
                reminder: reminder
            ),
            reachability: reachability
        )
    }

    func startMonitoring() {
        reachability?.start { [weak self] in
            Task { @MainActor in self?.trigger(.reconnected) }
        }
    }

    func stopMonitoring() {
        reachability?.stop()
        debounce?.cancel()
        debounce = nil
    }

    /// Asks for a sync. Never blocks, never throws, and is safe to call on every
    /// keystroke — the debounce and the actor's coalescing absorb the volume.
    func trigger(_ trigger: SyncTrigger) {
        guard let interval = trigger.debounceInterval else {
            Task { await self.perform(trigger) }
            return
        }
        // A burst of edits is one sync. Each new edit replaces the pending one
        // rather than adding to it.
        debounce?.cancel()
        debounce = Task { [weak self, sleep] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.perform(trigger)
        }
    }

    /// Asks the running sync to stop at its next step boundary — the background
    /// task's expiry handler, which has seconds rather than minutes.
    func cancelRunningSync() {
        debounce?.cancel()
        Task { [actor] in await actor.cancelCurrentRun() }
    }

    /// The awaitable form, for `.refreshable` and for the background task, which
    /// both have to know when the work is finished.
    @discardableResult
    func performAndWait(_ trigger: SyncTrigger) async -> SyncReport {
        await perform(trigger)
    }

    @discardableResult
    private func perform(_ trigger: SyncTrigger) async -> SyncReport {
        let previous = status
        status = .syncing
        let report = await actor.sync(trigger)
        apply(report, restoring: previous)
        return report
    }

    private func apply(_ report: SyncReport, restoring previous: Status) {
        switch report.verdict {
        case .completed:
            lastReport = report
            lastSyncedAt = report.finishedAt
            status = .idle
        case .throttled:
            // Nothing happened and nothing was wrong, so the line must go back to
            // what the last real run concluded — not flash "synced just now", and
            // not clear a standing error.
            status = previous == .syncing ? .idle : previous
        case .notConfigured:
            lastReport = report
            status = .notConfigured
        case .failed(let message, let needsAttention, let isOffline):
            lastReport = report
            status = isOffline ? .offline : .failed(message: message, needsAttention: needsAttention)
        }
    }
}
