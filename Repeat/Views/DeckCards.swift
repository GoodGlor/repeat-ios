import Foundation

/// What a row in a deck's card list says about where that note stands (#121).
enum DeckCards {

    /// One note's state, aggregated over its cards — a note can carry a forward
    /// and a reverse card that disagree with each other.
    enum Hint: Equatable, CaseIterable {
        case due, new, learning, known, suspended

        var label: String {
            switch self {
            case .due: Localized.string("до повторення")
            case .new: Localized.string("нова")
            case .learning: Localized.string("вивчається")
            case .known: Localized.string("відомо")
            case .suspended: Localized.string("призупинено")
            }
        }
    }

    /// Most urgent first: a note whose every card is suspended is one the queue
    /// will never show, so it says so; otherwise anything already due outranks
    /// the rest, and among the remainder the least-learned card speaks for the
    /// note — there is still something here to learn.
    ///
    /// `known` is `Mastery.bucket`'s definition rather than a second one. Two
    /// answers to "is this word known" that could drift apart is how the Stats
    /// screen and this list would end up disagreeing about the same card.
    ///
    /// Reads `state`, `due`, `stability`, `lastReview` and `isSuspended` — the
    /// card's own columns, never `card.note`. This runs per visible row, and it
    /// must not become the place a relationship walk creeps back in (gotcha 58).
    static func hint(for cards: [Card], now: Date) -> Hint {
        // A note with no cards at all should not exist, but answering `new`
        // beats crashing a list the owner opened to fix something.
        guard !cards.isEmpty else { return .new }
        let live = cards.filter { !$0.isSuspended }
        guard !live.isEmpty else { return .suspended }

        // A `new` card's `due` is its creation date, which is always in the
        // past — so "due" has to exclude it, or every new card would claim to
        // be waiting for a review it has never had.
        if live.contains(where: { $0.state != .new && $0.due <= now }) { return .due }

        let buckets = live.map {
            Mastery.bucket(state: $0.state, stability: $0.stability, lastReview: $0.lastReview)
        }
        if buckets.contains(.new) { return .new }
        if buckets.contains(.learning) { return .learning }
        return .known
    }
}
