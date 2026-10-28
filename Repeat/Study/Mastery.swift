import Foundation
import SwiftData
import Scheduling

/// §5.3 — what a card *is* to the person learning it: known, still learning,
/// or not started. Derived from the card's own scheduling columns on demand,
/// the way `Streak.length` and `Records` are derived from the log (spec §2.1).
///
/// Nothing here is stored. "Known" is a threshold on a number FSRS already
/// keeps, so it needs no correcting on undo, restore or rebuild — it is simply
/// re-read.
///
/// A phone rebuilt from `_log` (#41) has cards but no local `ReviewLog` rows —
/// `RebuildScheduling` writes scheduling state, not history — so the month's
/// list starts empty there and fills as new crossings happen.
enum Mastery {
    /// Days of stability at which a card counts as known. Spec §8 names this
    /// as the decision most likely to be revisited; it is one constant so that
    /// revisiting it is one line. The Stats caption that says "three weeks"
    /// (`StatsView.learnedSection`) is written against this value — change
    /// both together.
    static let knownStability: Double = 21

    /// How many of this month's words Stats lists before "і ще N".
    static let listLimit = 30

    enum Bucket: Equatable {
        case known, learning, new
    }

    /// The card's definition, in the card's order: known first, then anything
    /// that has been reviewed, then the rest. A relearning card with the
    /// stability it had before the lapse is *learning* — it was forgotten.
    static func bucket(state: SchedulingState, stability: Double, lastReview: Date?) -> Bucket {
        if state == .review && stability >= knownStability { return .known }
        if lastReview != nil { return .learning }
        return .new
    }

    /// The same test on a log's `prevState`, for finding when a card crossed.
    static func isKnown(_ snapshot: CardSchedulingSnapshot) -> Bool {
        snapshot.state == .review && snapshot.stability >= knownStability
    }

    /// One deck's three segments.
    struct Counts: Equatable {
        var known: Int
        var learning: Int
        var new: Int

        var total: Int { known + learning + new }

        static let empty = Counts(known: 0, learning: 0, new: 0)

        /// Reads `state`, `stability` and `lastReview` only — the card's own
        /// columns, never `card.note`. The caller already holds the cards
        /// (`HomeSummary.make` builds them per deck); this must not be the
        /// place a relationship walk creeps back in (handoff's SwiftData note).
        static func make(cards: [Card]) -> Counts {
            var counts = Counts.empty
            for card in cards {
                switch bucket(state: card.state, stability: card.stability, lastReview: card.lastReview) {
                case .known: counts.known += 1
                case .learning: counts.learning += 1
                case .new: counts.new += 1
                }
            }
            return counts
        }
    }

    // MARK: - Learned this month

    /// One word Stats lists: the note, its front, and the review that crossed.
    struct LearnedWord: Equatable, Identifiable {
        var noteId: UUID
        var front: String
        var learnedAt: Date
        var id: UUID { noteId }
    }

    /// When a currently-known card became known: the latest real review whose
    /// `prevState` was *not* known. Everything after it had a known `prevState`,
    /// so the card has been known without a break since — which is also why a
    /// card that lapsed and recovered is dated its second crossing (ruling 3).
    ///
    /// Undo markers (`rating == 0`) are skipped: the real review that follows
    /// one carries the truth. A row that will not decode ends the walk with
    /// `nil`: a list that cannot read the log claims nothing rather than
    /// dating the card at an older review. `nil` also when no review explains
    /// the card's state — a seeded card, or one rebuilt from a `_log` that
    /// never saw it cross.
    static func becameKnown(logs: [ReviewLog]) -> Date? {
        let real = logs.filter { $0.rating != 0 }.sorted { $0.reviewedAt > $1.reviewedAt }
        for log in real {
            guard let previous = try? log.decodedPrevState() else { return nil }
            if !isKnown(previous) { return log.reviewedAt }
        }
        return nil
    }

    /// The words that became known this calendar month, newest first.
    ///
    /// This month's crossings are found in the log first, and only the cards
    /// the log names are fetched afterward. The log is already in memory
    /// (`StatsSummary.load` fetches it once); the cards are not, and
    /// materialising every known card reviewed this month measured 91 ms of
    /// the mastery total's 166 ms on 10 000 cards — the whole of the mastery
    /// budget, and the reason the reshaped Stats budget test measured 0.37 s
    /// against its 0.300 s ceiling. Walking this month's reviews of a card
    /// from the newest down, the first `prevState` that was not known is a
    /// *candidate* crossing: older reviews need not be decoded, since a card
    /// whose reviews this month all began from known has its crossing, if
    /// any, in an earlier month. A card still learning passes the same walk
    /// trivially, so the candidates are every card studied this month that
    /// was not already known — bounded by study volume, not by the known
    /// deck — and the fetch below is what turns candidates into crossings:
    /// only the ones still known count, and a lapse since, or a note or deck
    /// soft-deleted since (§4.3), takes the word off the list. An unreadable
    /// row ends the walk with nothing claimed, as in `becameKnown`. Rows
    /// dated after the month (clock skew) are never walked, so such a row
    /// cannot hide a real crossing the way it could when the whole log was
    /// walked. A month of a few thousand candidates measured fine; if the
    /// `IN` list ever exceeded SQLite's parameter limit the fetch would fail
    /// closed and the section would read empty rather than wrong.
    ///
    /// One entry per note, dated the **first** crossing among its known
    /// cards (ruling 4). Cards are grouped by the id already on them;
    /// `card.note` is faulted only for the words that reach the sibling
    /// check below.
    ///
    /// Ruling 4's other half: a sibling card that crossed in an *earlier*
    /// month has no crossing this month, so the log walk above never sees
    /// it — but it makes the word that month's. Its whole log is walked,
    /// which is why the log is grouped by card here, once, for the few
    /// words left after the crossing search.
    ///
    /// Only *currently known* siblings anchor the date, so a word whose
    /// forward card crossed in January and lapsed in February while its
    /// reverse crossed in February is February's — consistent with rulings 3
    /// and 4, and worth knowing.
    ///
    /// - Parameter logs: every `ReviewLog` in the store, as `StatsSummary.load`
    ///   already fetches them; this month's crossings are found in one pass
    ///   over them before any card is fetched.
    static func learnedThisMonth(
        in context: ModelContext,
        logs: [ReviewLog],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LearnedWord] {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }

        // 1. This month's real reviews, per card. The log is already in
        //    memory; the cards are not, and materialising every known card
        //    reviewed this month measured 90 ms on 10k cards — the whole of
        //    the mastery budget. So the month is read off the log first, and
        //    only the cards it names are fetched.
        var thisMonth: [String: [ReviewLog]] = [:]
        for log in logs where log.rating != 0 && month.contains(log.reviewedAt) {
            thisMonth[log.cardId, default: []].append(log)
        }

        // 2. Walking a card's reviews this month from the newest down, the
        //    first `prevState` that was not known is a candidate crossing.
        //    Older reviews need not be decoded: if every review this month
        //    began from a known card, the crossing — if there ever was one —
        //    belongs to an earlier month. A learning card passes this walk
        //    too; step 3 is what makes a candidate a crossing. An unreadable
        //    row ends the walk with nothing claimed, as in `becameKnown`.
        var candidateCrossings: [String: Date] = [:]
        for (cardId, reviews) in thisMonth {
            for log in reviews.sorted(by: { $0.reviewedAt > $1.reviewedAt }) {
                guard let previous = try? log.decodedPrevState() else { break }
                if !isKnown(previous) {
                    candidateCrossings[cardId] = log.reviewedAt
                    break
                }
            }
        }
        guard !candidateCrossings.isEmpty else { return [] }

        // 3. Only those cards are fetched, and only the ones still known
        //    count; a lapse since the crossing takes the word off the list.
        //    A note or deck soft-deleted since (§4.3) takes it off too.
        let ids = Array(candidateCrossings.keys)
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
            ids.contains(card.id)
                && card.note.deletedAt == nil
                && card.note.deck.deletedAt == nil
        })
        let known = ((try? context.fetch(descriptor)) ?? []).filter {
            bucket(state: $0.state, stability: $0.stability, lastReview: $0.lastReview) == .known
        }
        guard !known.isEmpty else { return [] }

        // 4. One entry per note, dated the first crossing among its known
        //    cards (ruling 4). Grouped by the id already on the card;
        //    `card.note` is faulted only for the words that reach step 5.
        var firstCrossing: [UUID: (card: Card, at: Date)] = [:]
        for card in known {
            guard let noteId = Card.noteId(inCardId: card.id), let at = candidateCrossings[card.id] else { continue }
            if let earlier = firstCrossing[noteId], earlier.at <= at { continue }
            firstCrossing[noteId] = (card, at)
        }

        // 5. Ruling 4's other half: a sibling card that crossed in an earlier
        //    month has no crossing this month, so step 2 never saw it — but it
        //    makes the word that month's.
        //
        //    The siblings are **fetched, not walked**. Reaching them through
        //    `entry.card.note.cards` faults a relationship per card, and on the
        //    10k fixture that measured **24.3 ms** for 200 cards — the single
        //    largest piece of this function (#136). `Card.id` is
        //    `"<noteId>#<direction>"`, so every sibling's id can simply be
        //    constructed, and both the siblings and the notes come back in one
        //    fetch each. #84 and #116 were the same lesson; this is its third
        //    outing.
        let noteIds = Array(firstCrossing.keys)
        var siblingIds: Set<String> = []
        for (noteId, entry) in firstCrossing {
            for direction in Direction.allCases {
                let id = Card.id(noteId: noteId, direction: direction)
                if id != entry.card.id { siblingIds.insert(id) }
            }
        }

        let siblingList = Array(siblingIds)
        let siblings = (try? context.fetch(FetchDescriptor<Card>(
            predicate: #Predicate<Card> { siblingList.contains($0.id) }))) ?? []
        let knownSiblings = siblings.filter {
            bucket(state: $0.state, stability: $0.stability, lastReview: $0.lastReview) == .known
        }
        var siblingsByNote: [UUID: [Card]] = [:]
        for card in knownSiblings {
            guard let noteId = Card.noteId(inCardId: card.id) else { continue }
            siblingsByNote[noteId, default: []].append(card)
        }

        let notes = (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { noteIds.contains($0.id) }))) ?? []
        let frontById = Dictionary(notes.map { ($0.id, $0.front) }, uniquingKeysWith: { first, _ in first })

        // Only the sibling cards' logs are grouped, not all of them.
        let wanted = Set(knownSiblings.map(\.id))
        var logsByCard: [String: [ReviewLog]] = [:]
        for log in logs where wanted.contains(log.cardId) {
            logsByCard[log.cardId, default: []].append(log)
        }

        return firstCrossing
            .compactMap { noteId, entry -> LearnedWord? in
                guard let front = frontById[noteId] else { return nil }
                let siblingCrossing = (siblingsByNote[noteId] ?? [])
                    .compactMap { becameKnown(logs: logsByCard[$0.id] ?? []) }
                    .min()
                let learnedAt = min(entry.at, siblingCrossing ?? entry.at)
                guard month.contains(learnedAt) else { return nil }
                return LearnedWord(noteId: noteId, front: front, learnedAt: learnedAt)
            }
            .sorted {
                if $0.learnedAt != $1.learnedAt { return $0.learnedAt > $1.learnedAt }
                return $0.front < $1.front
            }
    }
}
