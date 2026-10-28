import Foundation
import SwiftData
import Scheduling

/// One schedulable direction of a `Note`. These fields are the phone's alone and
/// leave the device only as `_log` rows (§3.2).
@Model
final class Card {
    /// `"<note uuid>#fwd"` or `"#rev"`. Composed from the note id rather than being
    /// independent so that scheduling survives any content edit, and so a card can
    /// be matched back to its row after a "Re-download everything" (§6.6).
    @Attribute(.unique) var id: String
    var note: Note
    var direction: Direction

    var state: SchedulingState
    var due: Date
    var stability: Double
    var difficulty: Double
    var elapsedDays: Int
    var scheduledDays: Int
    var reps: Int
    var lapses: Int
    var lastReview: Date?

    /// 0-based index into the configured learning / relearning steps. Only
    /// meaningful in `.learning` and `.relearning`. Persisted because FSRS carries
    /// it on its own card: without it, a card part-way through `1m, 10m` would
    /// restart its steps every time the app relaunched.
    var learningStepIndex: Int

    /// Leech (§5.4) or manual. Suspended cards are excluded from every queue.
    var isSuspended: Bool

    init(note: Note, direction: Direction, due: Date = .now) {
        self.id = Card.id(noteId: note.id, direction: direction)
        self.note = note
        self.direction = direction
        self.state = .new
        self.due = due
        self.stability = 0
        self.difficulty = 0
        self.elapsedDays = 0
        self.scheduledDays = 0
        self.reps = 0
        self.lapses = 0
        self.lastReview = nil
        self.learningStepIndex = 0
        self.isSuspended = false
    }

    static func id(noteId: UUID, direction: Direction) -> String {
        "\(noteId.uuidString)#\(direction.rawValue)"
    }

    /// The inverse of `id(noteId:direction:)`, so a caller holding many cards
    /// can group them by note **without** faulting `card.note` for each — on
    /// 10k cards that walk is a second of the budget (handoff's SwiftData
    /// note). `nil` for ids that were never a card's, such as the synthetic
    /// ones debug seeds write into the log.
    static func noteId(inCardId id: String) -> UUID? {
        guard let hash = id.firstIndex(of: "#") else { return nil }
        return UUID(uuidString: String(id[..<hash]))
    }
}
