import Foundation
import SwiftData
import Scheduling

/// Takes the nightly snapshot and puts one back (§8).
enum BackupRunner {
    /// Day of the last successful run, so a backup happens once a day whether the
    /// trigger was a foreground or the background task.
    static let lastRunKey = "backup.lastRunDay"

    struct RestoreReport: Equatable {
        /// Cards that existed and were rewound.
        var restored: Int
        /// Entries whose card is no longer in the store — a note deleted in the
        /// Sheet since the backup was taken. Skipped, never resurrected.
        var missing: Int
        /// Cards present now but absent from the backup — added since. Left
        /// exactly as they are; a restore must not un-create them or reset
        /// scheduling they have legitimately accrued.
        var untouched: Int
    }

    // MARK: - Taking a backup

    /// Reads only each card's own properties. Deliberately does not touch
    /// `card.note`: crossing that relationship for 10k cards costs ~1.2 s (see
    /// the performance note in the handoff), and nothing here needs it.
    static func makeBackup(in context: ModelContext, now: Date = .now) throws -> SchedulingBackup {
        let cards = try context.fetch(FetchDescriptor<Card>())
        let entries = cards
            .map { SchedulingBackup.Entry(id: $0.id, scheduling: $0.snapshot) }
            .sorted { $0.id < $1.id }
        return SchedulingBackup(createdAt: now, entries: entries)
    }

    /// Writes today's backup and prunes to the newest seven.
    @discardableResult
    static func run(in context: ModelContext,
                    directory: URL = BackupStore.directory,
                    defaults: UserDefaults = .standard,
                    now: Date = .now,
                    calendar: Calendar = .current) throws -> URL {
        let backup = try makeBackup(in: context, now: now)
        let url = try BackupStore.write(backup, in: directory, calendar: calendar)
        BackupStore.prune(in: directory, calendar: calendar)
        defaults.set(calendar.startOfDay(for: now), forKey: lastRunKey)
        return url
    }

    static func hasRun(on day: Date,
                       defaults: UserDefaults = .standard,
                       calendar: Calendar = .current) -> Bool {
        guard let last = defaults.object(forKey: lastRunKey) as? Date else { return false }
        return calendar.isDate(last, inSameDayAs: day)
    }

    /// The entry point both triggers call. Returns `nil` when today's backup
    /// already exists.
    ///
    /// Not tied to a clock: "nightly" in a phone app means "the first time we run
    /// on a new day", because an app that is never open at midnight would
    /// otherwise never back up at all.
    @discardableResult
    static func runIfNeeded(in context: ModelContext,
                            directory: URL = BackupStore.directory,
                            defaults: UserDefaults = .standard,
                            now: Date = .now,
                            calendar: Calendar = .current) throws -> URL? {
        guard !hasRun(on: now, defaults: defaults, calendar: calendar) else { return nil }
        return try run(in: context, directory: directory, defaults: defaults,
                       now: now, calendar: calendar)
    }

    // MARK: - Restoring

    /// Rewinds scheduling to a snapshot, matching by card id.
    ///
    /// Safe when the Sheet has changed since the backup was taken, which is the
    /// acceptance line that matters: ids are stable across a pull, so a card that
    /// was edited still matches and gets its schedule back, a card deleted since
    /// is counted and skipped, and a card added since is left alone. Only
    /// scheduling fields move — nothing here touches note content, so a restore
    /// cannot undo an edit that came from the Sheet.
    @discardableResult
    static func restore(_ backup: SchedulingBackup, in context: ModelContext) throws -> RestoreReport {
        let cards = try context.fetch(FetchDescriptor<Card>())
        var byId = [String: Card](minimumCapacity: cards.count)
        for card in cards { byId[card.id] = card }

        var restored = 0
        var missing = 0
        for entry in backup.entries {
            guard let card = byId.removeValue(forKey: entry.id) else {
                missing += 1
                continue
            }
            card.restore(from: entry.scheduling)
            restored += 1
        }
        try context.save()
        return RestoreReport(restored: restored, missing: missing, untouched: byId.count)
    }
}
