import Foundation
import SwiftData

/// The per-deck operations behind the settings screen (§6.2).
///
/// Separate from the view because two of them have to be exactly right: suspend
/// must not disturb scheduling, and reordering must leave a set of positions the
/// next sort can rely on.
enum DeckSettings {
    /// The colours a deck can be given. The Sheet's `colorHex` is free-form and
    /// is never rewritten by this list — these are the swatches offered, not a
    /// constraint on what may be stored.
    static let palette = [
        "#1F7A5C", "#3A6EA5", "#C98A1E", "#C94D3F", "#6B4FA8", "#2F6F6F", "#5F6B64",
    ]

    static let newCardsPerDayRange = 0...50

    /// Suspends or resumes every card in the deck.
    ///
    /// Scheduling is deliberately untouched: `due`, `stability`, `difficulty` and
    /// the step index all stay exactly as they were, so a deck put aside for a
    /// month and brought back resumes where it stopped rather than restarting.
    /// Suspension is a filter on the queue, not a change to the cards.
    @discardableResult
    static func setSuspended(_ suspended: Bool, deck: Deck, in context: ModelContext) throws -> Int {
        var changed = 0
        for note in deck.notes where note.deletedAt == nil {
            for card in note.cards where card.isSuspended != suspended {
                card.isSuspended = suspended
                changed += 1
            }
        }
        try context.save()
        return changed
    }

    static func isFullySuspended(_ deck: Deck) -> Bool {
        let cards = deck.notes.filter { $0.deletedAt == nil }.flatMap(\.cards)
        return !cards.isEmpty && cards.allSatisfy(\.isSuspended)
    }

    enum Move { case up, down }

    /// Moves a deck one place and renumbers everything.
    ///
    /// Renumbering the whole list rather than swapping two values keeps the
    /// positions dense and unique. Decks arriving from a new tab all start at
    /// `sortOrder` 0, so a swap-only scheme would leave ties that sort
    /// arbitrarily and make the list jump around between launches.
    @discardableResult
    static func move(_ deck: Deck, _ move: Move, among decks: [Deck], in context: ModelContext) throws -> [String] {
        var ordered = decks
            .filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }

        guard let index = ordered.firstIndex(where: { $0.sheetTitle == deck.sheetTitle })
        else { return ordered.map(\.sheetTitle) }

        let target = move == .up ? index - 1 : index + 1
        guard ordered.indices.contains(target) else { return ordered.map(\.sheetTitle) }

        ordered.swapAt(index, target)
        for (position, entry) in ordered.enumerated() { entry.sortOrder = position }
        try context.save()
        return ordered.map(\.sheetTitle)
    }
}
