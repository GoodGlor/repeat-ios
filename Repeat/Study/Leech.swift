import Foundation
import SwiftData

/// §5.4 — cards that keep being forgotten.
///
/// A leech wastes the session: it comes back every day, gets failed again, and
/// crowds out material that is actually being learned. The answer is not to
/// repeat it harder but to take it out and fix the card, which is usually badly
/// written rather than genuinely hard.
enum Leech {

    /// Being a leech is **derived**, not stored: `lapses >= threshold` and
    /// suspended.
    ///
    /// A stored flag would be a schema change, and worse, a second source of
    /// truth that could disagree with the lapse count it is supposed to
    /// summarise. The cost of deriving it is that raising the threshold in
    /// Settings un-flags cards and lowering it flags more — which is the honest
    /// behaviour anyway, since the threshold is precisely the definition.
    static func isLeech(_ card: Card, threshold: Int) -> Bool {
        card.isSuspended && card.lapses >= threshold
    }

    /// Whether this card has now crossed the line. Checked after a rating.
    static func hasCrossedThreshold(_ card: Card, threshold: Int) -> Bool {
        !card.isSuspended && card.lapses >= threshold
    }

    /// Suspends a card that just crossed the threshold.
    ///
    /// Only `isSuspended` changes. §5.4 wants the card out of the queue, not
    /// rescheduled — its stability is a real measurement of a real memory, and
    /// resetting it here would destroy the evidence that the card is a problem.
    @discardableResult
    static func markIfNeeded(_ card: Card, threshold: Int) -> Bool {
        guard hasCrossedThreshold(card, threshold: threshold) else { return false }
        card.isSuspended = true
        return true
    }

    /// Every leech in the store, worst first.
    static func all(in context: ModelContext, threshold: Int) -> [Card] {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        return notes
            .filter { $0.deletedAt == nil && $0.deck.deletedAt == nil }
            .flatMap(\.cards)
            .filter { isLeech($0, threshold: threshold) }
            .sorted { ($0.lapses, $1.id) > ($1.lapses, $0.id) }
    }

    /// §5.4's **Rewrite**: back into normal scheduling, with the memory intact.
    ///
    /// `lapses` goes to 0 because the count described the old wording, and the
    /// card has just been rewritten — carrying it over would re-flag the new card
    /// on its first slip. Stability and difficulty stay: the person's memory of
    /// the material did not reset because the prompt was reworded, and the
    /// acceptance criterion says so explicitly.
    ///
    /// Applied to every card of the note, because both directions of a reversed
    /// note were rewritten by the same edit.
    @discardableResult
    static func rewrite(_ note: Note, in context: ModelContext, now: Date = .now) throws -> Int {
        var changed = 0
        for card in note.cards where card.lapses > 0 || card.isSuspended {
            card.lapses = 0
            card.isSuspended = false
            changed += 1
        }
        // The wording is the Sheet's to own, so an edit here has to reach it by
        // the ordinary route (§4.4) rather than by a special case.
        note.updatedAt = now
        note.refreshContentHash()
        note.pendingUpload = true
        try context.save()
        return changed
    }

    /// §5.4's **Delete**: "soft-deletes the note through the normal push path".
    ///
    /// Not a local removal. The row exists in someone's spreadsheet, and the only
    /// honest way to delete it is to mark it and let the push write `deleted` —
    /// which is also what makes the deletion survive a reinstall instead of being
    /// undone by the next pull.
    static func delete(_ note: Note, in context: ModelContext, now: Date = .now) throws {
        note.deletedAt = now
        note.updatedAt = now
        note.pendingUpload = true
        try context.save()
    }
}
