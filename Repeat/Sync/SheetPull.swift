import Foundation
import SwiftData
import GoogleSheets

/// What one pull changed (§4.3). Returned rather than logged so #19 can show it
/// and the tests can assert it.
struct PullResult: Equatable {
    var created = 0
    var contentUpdated = 0
    var softDeleted = 0
    var restored = 0
    var idsWrittenBack = 0
    /// Notes left alone because a local edit has not been pushed yet.
    var protectedPendingUploads = 0
    /// Rows with neither front nor back (§3.1).
    var ignoredBlankRows = 0
    /// Rows carrying an id that another row in the same tab also claims.
    var duplicateRows = 0
    var cardsAdded = 0
    var cardsRemoved = 0
    var conflicts = 0
}

/// The read half of sync (§4.3).
///
/// Content flows one way here: from the Sheet into `Note`. No path in this file
/// touches a `Card`'s scheduling fields, which is the invariant the whole design
/// rests on — the phone owns scheduling, the Sheet owns content.
struct SheetPull {
    let client: SheetsClient

    init(client: SheetsClient) {
        self.client = client
    }

    nonisolated(nonsending) func run(
        discovery: DiscoveryResult,
        in context: ModelContext,
        now: Date = .now
    ) async throws -> PullResult {
        var result = PullResult()
        let titles = discovery.readable.keys.sorted()
        guard !titles.isEmpty else { return result }

        // §4.3 step 2: every deck tab in one request.
        let ranges = try await client.batchGet(ranges: titles.map { A1.allRows(sheet: $0) })
        let rowsByTitle = Dictionary(ranges.map { ($0.sheetTitle, $0.values) },
                                     uniquingKeysWith: { first, _ in first })

        let decks = try context.fetch(FetchDescriptor<Deck>())
        var notesById = Dictionary(
            try context.fetch(FetchDescriptor<Note>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var idWriteBacks: [ValueRange] = []
        var seenNoteIds: Set<UUID> = []

        for title in titles {
            guard let header = discovery.readable[title],
                  let deck = decks.first(where: { $0.sheetTitle == title })
            else { continue }
            let rows = rowsByTitle[title] ?? []
            guard rows.count > 1 else { continue }

            var claimedIds: Set<UUID> = []

            for (offset, row) in rows.enumerated().dropFirst() {
                // Sheet rows are 1-based and row 1 is the header.
                let sheetRow = offset + 1

                let front = header.value("front", in: row) ?? ""
                let back = header.value("back", in: row) ?? ""
                if front.isEmpty && back.isEmpty {
                    result.ignoredBlankRows += 1
                    continue
                }

                let existingId = header.value("id", in: row).flatMap(UUID.init(uuidString:))
                let id: UUID
                if let existingId {
                    guard claimedIds.insert(existingId).inserted else {
                        // Two rows claiming one id: taking the second would make the
                        // pull's result depend on row order. Keep the first, report it.
                        result.duplicateRows += 1
                        continue
                    }
                    id = existingId
                } else {
                    // §4.3 step 2: a hand-added row gets an id, written back in step 5.
                    id = UUID()
                    if let column = header.index(of: "id") {
                        idWriteBacks.append(ValueRange(
                            range: A1.cell(sheet: title, column: column, row: sheetRow),
                            values: [[id.uuidString]]
                        ))
                        result.idsWrittenBack += 1
                    }
                }
                seenNoteIds.insert(id)

                let extras = header.extras(in: row)
                let incoming = IncomingRow(
                    front: front,
                    back: back,
                    example: header.value("example", in: row),
                    tags: header.value("tags", in: row)?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty } ?? [],
                    reverse: header.boolean("reverse", in: row),
                    extras: extras.values,
                    extraOrder: extras.order,
                    sheetRow: sheetRow,
                    isDeleted: header.boolean("deleted", in: row)
                )

                if let note = notesById[id] {
                    apply(incoming, to: note, in: context, now: now, result: &result)
                } else {
                    guard !incoming.isDeleted else { continue }
                    let note = incoming.makeNote(id: id, deck: deck)
                    context.insert(note)
                    notesById[id] = note
                    result.cardsAdded += context.syncCards(for: note, now: now).count
                    result.created += 1
                }
            }
        }

        // A locally known note whose row is gone was deleted in Sheets (§4.3 step 3).
        for (id, note) in notesById where !seenNoteIds.contains(id) {
            guard note.deletedAt == nil, let deckTitle = note.deck.sheetTitle as String?,
                  discovery.readable[deckTitle] != nil
            else { continue }
            // …unless the phone is the reason it is not there. A note typed in the
            // app and not yet pushed has no row to be missing from, and §4.4 step
            // 4 gives push the first word on a `pendingUpload` note. Without this,
            // adding a card offline and reconnecting deletes it: the pull runs
            // first, finds no row, and soft-deletes the card before the push in
            // the same run ever gets to append it.
            guard !note.pendingUpload else {
                result.protectedPendingUploads += 1
                continue
            }
            softDelete(note, at: now, result: &result)
        }

        // §4.3 step 5.
        if !idWriteBacks.isEmpty {
            try await client.batchUpdate(idWriteBacks, raw: true)
        }

        try context.save()
        // #153: the only place tags change, so the only place the queue's tag
        // index can go stale. Any content change counts — a row's tags are part
        // of its content, and telling which changed would cost more than the
        // rebuild it saves.
        if result.created + result.contentUpdated + result.softDeleted + result.restored > 0 {
            TagIndexCache.shared.invalidate()
        }
        return result
    }

    // MARK: - Applying a row to a known note

    private func apply(
        _ incoming: IncomingRow,
        to note: Note,
        in context: ModelContext,
        now: Date,
        result: inout PullResult
    ) {
        note.sheetRow = incoming.sheetRow

        if incoming.isDeleted {
            if note.deletedAt == nil { softDelete(note, at: now, result: &result) }
            return
        }
        if note.deletedAt != nil {
            note.deletedAt = nil
            for card in note.cards { card.isSuspended = false }
            result.restored += 1
        }

        let incomingHash = incoming.contentHash
        guard incomingHash != note.contentHash else { return }

        if note.pendingUpload {
            // The row is unchanged since both sides last agreed, so the local edit
            // is simply newer: push wins once (§4.3 step 4). With no recorded
            // ancestor this cannot be established, so the conservative branch runs
            // and the edit is preserved in the conflicts list rather than dropped.
            guard incomingHash != note.lastSyncedHash else {
                result.protectedPendingUploads += 1
                return
            }
            // Both sides changed. §4.5 is fixed and never prompts: the Sheet wins,
            // and the discarded edit is kept so it can be re-applied.
            context.insert(SyncConflict(
                noteId: note.id,
                deckTitle: note.deck.sheetTitle,
                occurredAt: now,
                front: note.front,
                back: note.back,
                example: note.example,
                winningFront: incoming.front,
                winningBack: incoming.back
            ))
            note.pendingUpload = false
            result.conflicts += 1
        }

        let hadReverse = note.reverse
        incoming.apply(to: note)
        note.lastSyncedHash = incomingHash
        result.contentUpdated += 1

        // Scheduling is untouched by all of the above; only a reverse flip adds or
        // removes a card (§4.3 step 3).
        if hadReverse != incoming.reverse {
            let before = note.cards.count
            let after = context.syncCards(for: note, now: now).count
            if after > before { result.cardsAdded += after - before }
            if after < before { result.cardsRemoved += before - after }
        }
    }

    private func softDelete(_ note: Note, at now: Date, result: inout PullResult) {
        note.deletedAt = now
        for card in note.cards { card.isSuspended = true }
        result.softDeleted += 1
    }
}

/// One deck row, parsed. A value type so applying it cannot accidentally reach a
/// `Card`.
private struct IncomingRow {
    var front: String
    var back: String
    var example: String?
    var tags: [String]
    var reverse: Bool
    var extras: [String: String]
    var extraOrder: [String]
    var sheetRow: Int
    var isDeleted: Bool

    var contentHash: String {
        ContentHash.of(front: front, back: back, example: example, tags: tags,
                       reverse: reverse, extras: extras, extraOrder: extraOrder)
    }

    func makeNote(id: UUID, deck: Deck) -> Note {
        Note(id: id, deck: deck, front: front, back: back, example: example, tags: tags,
             reverse: reverse, extras: extras, extraOrder: extraOrder, sheetRow: sheetRow)
    }

    func apply(to note: Note) {
        note.front = front
        note.back = back
        note.example = example
        note.tags = tags
        note.reverse = reverse
        note.extras = extras
        note.extraOrder = extraOrder
        note.refreshContentHash()
    }
}
