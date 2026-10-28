import Foundation
import SwiftData

/// One row of a deck worksheet. Content is owned by the Sheet; scheduling is not
/// stored here at all (§3.2).
@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var deck: Deck

    var front: String
    var back: String
    var example: String?
    var tags: [String]
    var reverse: Bool

    /// Columns not named in §3.1, keyed by header (D1). Displayed under the answer
    /// in `extraOrder`, which preserves the Sheet's own column order.
    var extras: [String: String]
    var extraOrder: [String]

    /// 0-based position of this note's row in its deck worksheet. New cards are
    /// introduced in sheet row order (§5.2), so the owner's own ordering in Sheets
    /// decides what is learned first. Populated by the pull in #14; until then it
    /// is the order notes were created.
    var sheetRow: Int

    var contentHash: String

    /// `contentHash` as of the last time this note and the Sheet agreed.
    ///
    /// Needed to tell §4.5's conflict apart from an ordinary local edit. Once a
    /// note is edited on the phone, `contentHash` describes the *local* content,
    /// so comparing it against the row proves nothing about whether the row also
    /// changed. This is the last value both sides shared.
    ///
    /// Optional, and deliberately so on two counts. SwiftData cannot lightly
    /// migrate an existing store when a *mandatory* attribute appears — it fails
    /// the whole store, which for this app means the only copy of scheduling
    /// state. And `nil` says something true that a default of `""` would not:
    /// there is no known common ancestor, so a difference must be treated as a
    /// conflict and the local edit preserved rather than silently dropped.
    var lastSyncedHash: String?

    var updatedAt: Date

    /// Soft delete (§4.3). Named `deletedAt` rather than the spec's `isDeleted`
    /// because `PersistentModel` already declares `isDeleted`, and shadowing it
    /// would make `note.isDeleted` mean two different things depending on where it
    /// is read. The timestamp also supplies the 30-day purge clock for free.
    var deletedAt: Date?

    /// Created or edited on the phone and not yet pushed. Protects the note from
    /// being overwritten by exactly one pull (§4.3 step 4).
    var pendingUpload: Bool

    @Relationship(deleteRule: .cascade, inverse: \Card.note)
    var cards: [Card] = []

    init(
        id: UUID = UUID(),
        deck: Deck,
        front: String,
        back: String,
        example: String? = nil,
        tags: [String] = [],
        reverse: Bool = false,
        extras: [String: String] = [:],
        extraOrder: [String] = [],
        sheetRow: Int = 0,
        updatedAt: Date = .now,
        pendingUpload: Bool = false
    ) {
        self.id = id
        self.deck = deck
        self.front = front
        self.back = back
        self.example = example
        self.tags = tags
        self.reverse = reverse
        self.extras = extras
        self.extraOrder = extraOrder
        self.sheetRow = sheetRow
        self.updatedAt = updatedAt
        self.pendingUpload = pendingUpload
        let hash = ContentHash.of(
            front: front, back: back, example: example, tags: tags,
            reverse: reverse, extras: extras, extraOrder: extraOrder
        )
        self.contentHash = hash
        self.lastSyncedHash = hash
    }

    /// Recomputes `contentHash` from the current field values. Call after any edit;
    /// sync compares hashes, so an edit that skips this is invisible to the Sheet.
    func refreshContentHash() {
        contentHash = ContentHash.of(
            front: front, back: back, example: example, tags: tags,
            reverse: reverse, extras: extras, extraOrder: extraOrder
        )
    }

    /// The directions this note should have cards for, given `reverse` (D2).
    var expectedDirections: [Direction] {
        reverse ? [.forward, .reverse] : [.forward]
    }

    /// Extras in display order, skipping empties — an extra with no value renders
    /// nothing rather than a blank line (D1). The `image` column is the card's
    /// picture (#149), shown as a picture, never as a link under the answer.
    var displayExtras: [(key: String, value: String)] {
        extraOrder.compactMap { key in
            guard key != CardPicture.column,
                  let value = extras[key], !value.isEmpty else { return nil }
            return (key, value)
        }
    }
}
