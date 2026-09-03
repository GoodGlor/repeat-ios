import Foundation
import SwiftData
import GoogleSheets

/// What one push wrote (§4.4).
struct PushResult: Equatable {
    var appended = 0
    var updated = 0
    var markedDeleted = 0
    /// Notes whose deck is missing or unreadable, so there is nowhere to write.
    var skipped = 0
}

/// The write half of sync for card content (§4.4). `_log` is #17.
///
/// The phone never removes a row. A deletion sets `deleted=TRUE`, so a mistaken
/// tap in the app cannot destroy a row in the owner's own spreadsheet — the Sheet
/// is the source of truth for content, and this side of the sync stays additive.
struct SheetPush {
    let client: SheetsClient

    init(client: SheetsClient) {
        self.client = client
    }

    func run(
        discovery: DiscoveryResult,
        in context: ModelContext,
        now: Date = .now
    ) async throws -> PushResult {
        var result = PushResult()

        let pending = try context.fetch(FetchDescriptor<Note>()).filter(\.pendingUpload)
        guard !pending.isEmpty else { return result }

        let byDeck = Dictionary(grouping: pending) { $0.deck.sheetTitle }

        for (title, notes) in byDeck.sorted(by: { $0.key < $1.key }) {
            guard let header = discovery.readable[title] else {
                // No usable header means no way to know which column is which;
                // writing blind would scatter values across the wrong columns.
                result.skipped += notes.count
                continue
            }

            let rowsById = try await locateRows(in: title, header: header)

            var updates: [ValueRange] = []
            var appendRows: [[String]] = []
            var appended: [Note] = []
            var updatedNotes: [Note] = []

            for note in notes.sorted(by: { $0.sheetRow < $1.sheetRow }) {
                let values = row(for: note, header: header, now: now)
                if let sheetRow = rowsById[note.id] {
                    note.sheetRow = sheetRow
                    updates.append(ValueRange(
                        range: A1.row(sheet: title, width: header.headerRow.count, row: sheetRow),
                        values: [values]
                    ))
                    updatedNotes.append(note)
                    if note.deletedAt != nil { result.markedDeleted += 1 } else { result.updated += 1 }
                } else {
                    // A note the Sheet has never seen. A locally deleted one that
                    // never reached the Sheet needs no row at all.
                    guard note.deletedAt == nil else {
                        updatedNotes.append(note)
                        continue
                    }
                    appendRows.append(values)
                    appended.append(note)
                }
            }

            // Writes first, flags after: a failure here must leave the work queued
            // (§4.4), so the next trigger retries rather than losing the edit.
            if !updates.isEmpty {
                try await client.batchUpdate(updates, raw: false)
            }
            if !appendRows.isEmpty {
                // One append per deck per sync (§4.4).
                try await client.append(range: A1.allRows(sheet: title), values: appendRows)
                result.appended += appendRows.count
            }

            for note in updatedNotes + appended {
                note.pendingUpload = false
                note.lastSyncedHash = note.contentHash
                note.updatedAt = now
            }
        }

        try context.save()
        return result
    }

    /// Builds id → row number for the deck.
    ///
    /// §4.4 caches the row index on the note and re-fetches when it misses. Rows
    /// move whenever the owner sorts or inserts in Sheets, and a stale index would
    /// overwrite a different card — so the id column is read and the cached index
    /// is only ever a hint, never trusted.
    private func locateRows(in title: String, header: HeaderMap) async throws -> [UUID: Int] {
        guard let idColumn = header.index(of: "id") else { return [:] }
        let range = "\(A1.quote(title))!\(A1.column(idColumn)):\(A1.column(idColumn))"
        let fetched = try await client.batchGet(ranges: [range])
        guard let values = fetched.first?.values else { return [:] }

        var rows: [UUID: Int] = [:]
        for (offset, row) in values.enumerated().dropFirst() {
            guard let raw = row.first, let id = UUID(uuidString: raw) else { continue }
            // First occurrence wins, matching the pull's duplicate-id rule.
            if rows[id] == nil { rows[id] = offset + 1 }
        }
        return rows
    }

    /// The note as a full row, in the sheet's own column order.
    ///
    /// Every column is written, including extras, at the position the header
    /// gives it — the phone never adds, reorders or drops a column (D1).
    private func row(for note: Note, header: HeaderMap, now: Date) -> [String] {
        var values = [String](repeating: "", count: header.headerRow.count)
        func set(_ column: String, _ value: String) {
            guard let index = header.index(of: column), index < values.count else { return }
            values[index] = value
        }

        set("id", note.id.uuidString)
        set("front", note.front)
        set("back", note.back)
        set("example", note.example ?? "")
        set("tags", note.tags.joined(separator: ","))
        set("reverse", note.reverse ? "TRUE" : "FALSE")
        set("updated_at", Self.timestamp.string(from: now))
        set("deleted", note.deletedAt != nil ? "TRUE" : "FALSE")

        for key in note.extraOrder {
            set(key, note.extras[key] ?? "")
        }
        return values
    }

    /// §3.1: ISO 8601 UTC. Fixed to UTC rather than the device's zone, so the
    /// column stays comparable across a phone that travels.
    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
