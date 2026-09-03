import Foundation
import SwiftData
import GoogleSheets

/// Brings local `Deck`s in line with the spreadsheet's tabs (§4.3 step 1).
enum DeckReconciler {

    struct Outcome: Equatable {
        var created: [String] = []
        var renamed: [(from: String, to: String)] = []
        var softDeleted: [String] = []
        var restored: [String] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.created == rhs.created
                && lhs.softDeleted == rhs.softDeleted
                && lhs.restored == rhs.restored
                && lhs.renamed.map(\.from) == rhs.renamed.map(\.from)
                && lhs.renamed.map(\.to) == rhs.renamed.map(\.to)
        }
    }

    /// Decks are matched by `sheetId` — the tab's `gid` — not by title.
    ///
    /// That is what makes a rename a rename. Matching by title would look like a
    /// delete plus a create, and the new deck's cards would all be new: the whole
    /// deck's scheduling history, silently discarded by an edit that felt
    /// cosmetic.
    @discardableResult
    static func reconcile(
        properties: [SheetProperties],
        in context: ModelContext,
        now: Date = .now
    ) throws -> Outcome {
        var outcome = Outcome()
        let remote = properties.filter { !$0.isReserved }
        let existing = try context.fetch(FetchDescriptor<Deck>())
        var byGid = Dictionary(existing.map { ($0.sheetId, $0) }, uniquingKeysWith: { first, _ in first })

        // Renames are applied in two passes. `sheetTitle` is unique, so swapping
        // two tabs' names — A→B, B→A — would collide half-way through if done
        // directly.
        var pendingRenames: [(deck: Deck, title: String)] = []
        for sheet in remote {
            guard let deck = byGid[sheet.sheetId] else { continue }
            if deck.sheetTitle != sheet.title {
                outcome.renamed.append((from: deck.sheetTitle, to: sheet.title))
                pendingRenames.append((deck, sheet.title))
            }
        }
        for (deck, _) in pendingRenames {
            deck.sheetTitle = "\(deck.sheetTitle)\u{1F}pending-\(UUID().uuidString)"
        }
        for (deck, title) in pendingRenames {
            deck.sheetTitle = title
        }

        for sheet in remote {
            if let deck = byGid[sheet.sheetId] {
                deck.sortOrder = sheet.index
                // A tab that reappears is the same deck, with its scheduling.
                if deck.deletedAt != nil {
                    deck.deletedAt = nil
                    outcome.restored.append(deck.sheetTitle)
                }
            } else {
                let deck = Deck(sheetTitle: sheet.title, sheetId: sheet.sheetId, sortOrder: sheet.index)
                context.insert(deck)
                byGid[sheet.sheetId] = deck
                outcome.created.append(sheet.title)
            }
        }

        // A tab that is gone soft-deletes, keeping its cards for 30 days so an
        // accidental deletion in Sheets is recoverable (§4.3).
        let remoteGids = Set(remote.map(\.sheetId))
        for deck in existing where !remoteGids.contains(deck.sheetId) && deck.deletedAt == nil {
            deck.deletedAt = now
            for note in deck.notes {
                for card in note.cards { card.isSuspended = true }
            }
            outcome.softDeleted.append(deck.sheetTitle)
        }

        return outcome
    }

    /// Cards kept past the recovery window are purged (§4.3).
    static func purgeExpired(in context: ModelContext, now: Date = .now, keepFor: TimeInterval = 30 * 86_400) throws {
        for deck in try context.fetch(FetchDescriptor<Deck>()) {
            guard let deletedAt = deck.deletedAt, now.timeIntervalSince(deletedAt) > keepFor else { continue }
            context.delete(deck)
        }
    }
}
