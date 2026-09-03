import Foundation
import SwiftData

/// Turning a filled-in form into a `Note` (§6.4).
///
/// Outside the view because the interesting part is not the layout: a card added
/// here has to be indistinguishable from one pulled out of the Sheet, or the
/// push will not know what to do with it.
enum AddCardComposer {
    struct Draft: Equatable {
        var front = ""
        var back = ""
        var example = ""
        var reverse = false

        /// The inbox item this draft came from (§6.4), if any. Held so the item
        /// is consumed by the save that used it — and by no other. Clearing it on
        /// save is what makes "exactly once" true through "save and add another",
        /// which would otherwise consume the same capture on every card.
        var sourceItemID: UUID?
        /// Where the capture came from. Shown as context; see `save` for why it
        /// does not become a column.
        var sourceURL: String?

        /// Whitespace-only fields are empty fields. Someone who taps Save on a
        /// stray newline meant to add nothing.
        var trimmedFront: String { front.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trimmedBack: String { back.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trimmedExample: String { example.trimmingCharacters(in: .whitespacesAndNewlines) }

        var isSavable: Bool { !trimmedFront.isEmpty && !trimmedBack.isEmpty }

        /// Keeps the deck and the reverse toggle, clears the text. §6.4's "Save
        /// and add another" is for entering a run of cards of the same kind.
        ///
        /// The inbox link does **not** survive: it belonged to the card just
        /// saved.
        func cleared() -> Draft {
            Draft(front: "", back: "", example: "", reverse: reverse)
        }

        /// Opens the form on a quick capture (§6.4).
        ///
        /// The captured text becomes the front — it is what the person saw and
        /// wanted to remember. The answer is what they came here to write.
        static func from(_ item: InboxItem, reverse: Bool = false) -> Draft {
            Draft(front: item.text, back: "", example: "", reverse: reverse,
                  sourceItemID: item.id, sourceURL: item.sourceURL)
        }
    }

    /// Saves the draft as a note the push will pick up.
    ///
    /// `pendingUpload` is the whole point: there is no direct write to the Sheet
    /// here. The note joins the same queue as an edit made anywhere else, so a
    /// card typed on a train reaches the Sheet by exactly the path a card typed
    /// at home does — and reaches it at all, rather than being lost when the
    /// request fails.
    @discardableResult
    static func save(
        _ draft: Draft,
        to deck: Deck,
        in context: ModelContext,
        now: Date = .now
    ) throws -> Note {
        precondition(draft.isSavable)

        let note = Note(
            deck: deck,
            front: draft.trimmedFront,
            back: draft.trimmedBack,
            example: draft.trimmedExample.isEmpty ? nil : draft.trimmedExample,
            reverse: draft.reverse,
            // Row 0 marks "not in the Sheet yet". The push appends it and the
            // pull writes the real row index back (§4.3 step 5).
            sheetRow: 0,
            updatedAt: now,
            pendingUpload: true
        )
        context.insert(note)
        note.refreshContentHash()
        // `Note.init` records the two sides as agreed, which is right for a note
        // built from a pulled row and wrong here: the Sheet has never seen this
        // one, so there is no common ancestor. `nil` is what the field means by
        // that, and it makes a later disagreement preserve the local card instead
        // of discarding it (§4.5).
        note.lastSyncedHash = nil
        context.syncCards(for: note, now: now)

        // The source URL is not written onto the note. Extras are the Sheet's own
        // columns, and D1 is explicit that the phone never invents one — a
        // `source` column appearing in someone's spreadsheet because they shared
        // a link is precisely the surprise that rule exists to prevent. The URL
        // is shown in the form as context and dies with the capture.
        if let itemID = draft.sourceItemID {
            try consume(itemID, in: context)
        }

        try context.save()
        return note
    }

    /// Removes the capture a saved card came from. Idempotent: an id that is no
    /// longer there is not an error, because the capture is already gone.
    static func consume(_ itemID: UUID, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.id == itemID })
        for item in try context.fetch(descriptor) { context.delete(item) }
    }

    /// The deck the form opens on (§6.4: "last used preselected").
    ///
    /// A title rather than a persistent id: decks are identified by their
    /// worksheet name everywhere else, and one that has since been renamed or
    /// deleted should fall back rather than resurrect.
    enum LastDeck {
        static let key = "add.lastDeckTitle"

        static func resolve(
            among decks: [Deck],
            defaults: UserDefaults = .standard
        ) -> Deck? {
            let live = decks
                .filter { $0.deletedAt == nil && $0.malformedReason == nil }
                .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
            guard let remembered = defaults.string(forKey: key),
                  let match = live.first(where: { $0.sheetTitle == remembered })
            else { return live.first }
            return match
        }

        static func remember(_ deck: Deck, defaults: UserDefaults = .standard) {
            defaults.set(deck.sheetTitle, forKey: key)
        }
    }
}
