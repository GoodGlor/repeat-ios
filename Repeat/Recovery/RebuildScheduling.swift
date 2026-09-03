import Foundation
import SwiftData
import GoogleSheets
import Scheduling

/// "Rebuild scheduling from `_log`" (§6.6) — the second recovery path of D4.
enum RebuildScheduling {

    struct Report: Equatable {
        /// Reviews replayed, undo markers already excluded.
        var reviewsReplayed = 0
        var undoMarkers = 0
        var malformedRows = 0
        /// Cards whose schedule came back from the log.
        var cardsRebuilt = 0
        /// Cards with no reviews in the log — returned to `new`.
        var cardsReset = 0
        /// Log rows naming a card that no longer exists. Reported, never silently
        /// dropped: it is how the owner learns the Sheet and the phone disagree.
        var unknownCards = 0
        /// The snapshot taken before anything was replaced.
        var backup: URL?
    }

    enum RebuildError: Error, CustomStringConvertible {
        case noLogSheet

        var description: String {
            switch self {
            case .noLogSheet:
                Localized.string("У Таблиці немає аркуша _log — відновлювати нема з чого.")
            }
        }
    }

    // MARK: - Reading

    /// Fetches the whole `_log` worksheet.
    static func fetchLog(client: SheetsClient) async throws -> [[String]] {
        let properties = try await client.sheetProperties()
        guard properties.contains(where: { $0.title == MetaSheet.logTitle }) else {
            throw RebuildError.noLogSheet
        }
        let range = A1.allRows(sheet: MetaSheet.logTitle, width: LogPush.header.count)
        return try await client.batchGet(ranges: [range]).first?.values ?? []
    }

    /// Reads and parses without touching the store, so the confirmation dialog
    /// can say how many reviews are about to be replayed before anything is
    /// replaced.
    static func preview(client: SheetsClient) async throws -> LogReplay.Parse {
        LogReplay.parse(try await fetchLog(client: client))
    }

    // MARK: - Applying

    /// Replays a parsed log over the store.
    ///
    /// The replay itself runs off the main actor: 5k rows of FSRS is real work,
    /// and §8 asks for a rebuild that does not block the UI. Only value types
    /// cross the boundary — the models are read and written on the caller's
    /// actor, before and after.
    @MainActor
    @discardableResult
    static func apply(_ parse: LogReplay.Parse,
                      in context: ModelContext,
                      config: SchedulerConfig,
                      backupDirectory: URL = BackupStore.directory,
                      now: Date = .now) async throws -> Report {
        var report = Report(
            reviewsReplayed: parse.reviewCount,
            undoMarkers: parse.undoMarkers,
            malformedRows: parse.malformed
        )

        // Before anything is replaced (#36). A rebuild is destructive by design,
        // and this is the only thing that makes it reversible.
        report.backup = try? BackupRunner.run(in: context, directory: backupDirectory, now: now)

        let rows = parse.rows
        let rebuilt = await Task.detached(priority: .userInitiated) {
            LogReplay.replay(rows, scheduler: Scheduler(config: config))
        }.value

        let cards = try context.fetch(FetchDescriptor<Card>())
        var seen = Set<String>(minimumCapacity: rebuilt.count)

        for card in cards {
            if var snapshot = rebuilt[card.id] {
                // Suspension is not in `_log` — it is a local decision (§5.4), and
                // a rebuild that silently unsuspended every leech would undo work
                // the owner did on purpose.
                snapshot.isSuspended = card.isSuspended
                card.restore(from: snapshot)
                seen.insert(card.id)
                report.cardsRebuilt += 1
            } else {
                var fresh = CardSchedulingSnapshot()
                // `due` is kept rather than reset to `now`: a never-reviewed card
                // has no history to replay, so the deterministic answer is the one
                // it already has. Resetting to `.now` would also make two runs
                // disagree, which is the one guarantee this feature sells.
                fresh.due = card.due
                fresh.isSuspended = card.isSuspended
                card.restore(from: fresh)
                report.cardsReset += 1
            }
        }

        report.unknownCards = rebuilt.keys.filter { !seen.contains($0) }.count
        try context.save()
        return report
    }

    /// The whole operation, for callers that do not need the two-step preview.
    @MainActor
    @discardableResult
    static func run(client: SheetsClient,
                    in context: ModelContext,
                    config: SchedulerConfig,
                    backupDirectory: URL = BackupStore.directory,
                    now: Date = .now) async throws -> Report {
        let parse = try await preview(client: client)
        return try await apply(parse, in: context, config: config,
                               backupDirectory: backupDirectory, now: now)
    }
}
