import Foundation
import SwiftData

/// Puts a discarded local edit back (§4.5, §6.2).
///
/// §4.5 is fixed and never prompts: when both sides changed, the Sheet wins. That
/// is the right default — but discarding someone's typing with no way back is
/// not. Re-applying is the escape hatch, and it deliberately goes through the
/// normal push path rather than writing to the Sheet directly: the edit becomes a
/// pending local edit again, and the next sync carries it up like any other.
enum ConflictResolver {
    enum Outcome: Equatable {
        case reapplied
        /// The note has since been deleted, so there is nothing to re-apply to.
        /// The conflict is cleared rather than left to accumulate forever.
        case noteGone
    }

    @discardableResult
    static func reapply(
        _ conflict: SyncConflict,
        in context: ModelContext,
        now: Date = .now
    ) throws -> Outcome {
        let noteId = conflict.noteId
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteId })
        guard let note = try context.fetch(descriptor).first, note.deletedAt == nil else {
            context.delete(conflict)
            try context.save()
            return .noteGone
        }

        note.front = conflict.front
        note.back = conflict.back
        note.example = conflict.example
        note.refreshContentHash()
        note.updatedAt = now
        // Not `lastSyncedHash`: the two sides genuinely disagree again, and the
        // push is what resolves it. Marking them agreed here would make the next
        // pull treat the Sheet's version as the newer one and discard this a
        // second time.
        note.pendingUpload = true

        context.delete(conflict)
        try context.save()
        return .reapplied
    }

    static func dismiss(_ conflict: SyncConflict, in context: ModelContext) throws {
        context.delete(conflict)
        try context.save()
    }
}
