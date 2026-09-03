import Foundation
import SwiftData

/// A local edit discarded because the Sheet changed too (§4.5).
///
/// The rule is fixed and never prompts mid-flow, which is right — but discarding
/// someone's typing without a trace would not be. This keeps what was lost so
/// "Sync conflicts" on Home (§6.2) can offer it back with one tap.
@Model
final class SyncConflict {
    @Attribute(.unique) var id: UUID
    var noteId: UUID
    var deckTitle: String
    var occurredAt: Date

    /// The discarded local version.
    var front: String
    var back: String
    var example: String?

    /// What the Sheet had instead, so the two can be compared before re-applying.
    var winningFront: String
    var winningBack: String

    init(
        id: UUID = UUID(),
        noteId: UUID,
        deckTitle: String,
        occurredAt: Date = .now,
        front: String,
        back: String,
        example: String?,
        winningFront: String,
        winningBack: String
    ) {
        self.id = id
        self.noteId = noteId
        self.deckTitle = deckTitle
        self.occurredAt = occurredAt
        self.front = front
        self.back = back
        self.example = example
        self.winningFront = winningFront
        self.winningBack = winningBack
    }
}
