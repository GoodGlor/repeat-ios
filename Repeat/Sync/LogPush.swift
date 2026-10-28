import Foundation
import SwiftData
import GoogleSheets
import Scheduling

/// What one `_log` push wrote.
struct LogPushResult: Equatable {
    var uploaded = 0
    /// How many append requests it took — 500 rows each (§4.4).
    var requests = 0
    /// True when this push had to create the `_log` tab first.
    var createdSheet = false
}

/// Pushes the append-only review log (§3.1, §4.4).
///
/// This is the one table the phone owns end to end, and the input the FSRS
/// optimizer will later run on — so it has to be complete. Two properties matter
/// more than speed:
///
/// - **No gaps.** A row is marked `uploaded` only after the request carrying it
///   returned 200. A crash or a dead network mid-push leaves the rest queued for
///   the next trigger rather than silently dropping a day of reviews.
/// - **No duplicates.** Marking happens per chunk, so a failure on chunk 3 does
///   not re-send chunks 1 and 2.
///
/// The cost of that ordering is a narrow window: if the append succeeds but the
/// save fails, rows are re-sent next time. Duplicates in an append-only log are
/// recoverable (the optimizer sees the same review twice); missing rows are not.
struct LogPush {
    /// §4.4: chunked ≤ 500 rows per request.
    static let chunkSize = 500

    /// The `_log` header, in the order §3.1 fixes.
    static let header = [
        "card_id", "direction", "rating", "reviewed_at",
        "elapsed_days", "scheduled_days", "state_before",
    ]

    let client: SheetsClient

    init(client: SheetsClient) {
        self.client = client
    }

    nonisolated(nonsending) func run(
        discovery: DiscoveryResult,
        in context: ModelContext
    ) async throws -> LogPushResult {
        var result = LogPushResult()

        // Oldest first: `_log` is a history, and a replay (#41) reads it top to
        // bottom. Sorting in the fetch rather than after keeps the order stable
        // even when a chunk boundary falls between two reviews of the same card.
        let descriptor = FetchDescriptor<ReviewLog>(
            predicate: #Predicate { $0.uploaded == false },
            sortBy: [SortDescriptor(\.reviewedAt, order: .forward)]
        )
        let pending = try context.fetch(descriptor)
        guard !pending.isEmpty else { return result }

        // Creating the tab is part of the first push, not of setup: a spreadsheet
        // the owner built by hand has no `_log` until there is something to write.
        if !discovery.hasLogSheet {
            try await client.addSheet(title: MetaSheet.logTitle)
            try await client.append(range: range, values: [Self.header])
            result.createdSheet = true
        }

        for chunk in stride(from: 0, to: pending.count, by: Self.chunkSize) {
            let slice = Array(pending[chunk..<min(chunk + Self.chunkSize, pending.count)])
            try await client.append(range: range, values: slice.map(Self.row(for:)))

            // Flags after the write, and saved per chunk — this is what makes an
            // interrupted push resumable rather than lossy.
            for log in slice { log.uploaded = true }
            try context.save()

            result.uploaded += slice.count
            result.requests += 1
        }

        return result
    }

    private var range: String {
        A1.allRows(sheet: MetaSheet.logTitle, width: Self.header.count)
    }

    /// One log row, in the column order §3.1 fixes. Positional rather than
    /// header-mapped: unlike a deck tab, this sheet has no owner-authored layout
    /// to respect — the phone writes it and only the phone reads it.
    static func row(for log: ReviewLog) -> [String] {
        [
            log.cardId,
            log.direction.rawValue,
            String(log.rating),
            SheetPush.timestamp.string(from: log.reviewedAt),
            String(log.elapsedDays),
            String(log.scheduledDays),
            log.stateBefore.logName,
        ]
    }
}
