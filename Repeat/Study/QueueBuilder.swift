import Foundation
import SwiftData
import Scheduling

/// Knobs for building a session queue (§5.2).
struct QueueConfig: Equatable, Sendable {
    /// Ceiling across all decks, applied after each deck's own `newCardsPerDay`.
    var globalNewCardCap: Int = 30
    /// Used until there are enough logs to measure (§5.2).
    var defaultSecondsPerCard: TimeInterval = 20
    /// Gaps longer than this are treated as a break rather than a card, so a
    /// session resumed the next morning does not report a 14-hour card.
    var maxPlausibleSecondsPerCard: TimeInterval = 120
    /// §5.2 says "the last 200 logs".
    var estimateSampleSize: Int = 200
}

/// An ordered session queue, built once when a session starts and rebuilt when the
/// day rolls over (§5.2).
struct QueuePlan: Equatable, Sendable {
    /// Card ids in the order they will be shown.
    var cardIds: [String]
    var dueReviewCount: Int
    var newCardCount: Int
    var secondsPerCard: TimeInterval
    /// The local day this plan was built for; a plan from yesterday is stale.
    var studyDay: Date
    /// #153: the tag each filtered deck was built under, by deck title. A deck
    /// studying all its cards has no entry. Home names it on the deck's row.
    var filters: [String: DeckFilter] = [:]

    var count: Int { cardIds.count }
    var isEmpty: Bool { cardIds.isEmpty }
    var estimatedSeconds: TimeInterval { Double(count) * secondsPerCard }
    var estimatedMinutes: Int { max(1, Int((estimatedSeconds / 60).rounded())) }

    func isStale(at now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(studyDay, inSameDayAs: now)
    }
}

enum QueueBuilder {

    /// Builds the queue for a session (§5.2).
    ///
    /// Order is: due reviews by `due` ascending, randomised within the same day, then
    /// new cards in sheet row order. Suspended cards never appear, and neither do
    /// cards due later today — those come back through `StudyQueue` when their
    /// timer expires.
    ///
    /// Each deck is narrowed to its own tag (#144, #153). With `filters` `nil`,
    /// the default, that is the tag chosen in the deck's settings — so Home's
    /// count, the all-decks session, a one-deck session, the widget and the
    /// reminders all mean the same cards. A caller that passes `filters` gets
    /// exactly those, with `tagIndexes` answering which notes a tag keeps.
    ///
    /// A filter only ever removes cards: the per-deck allowance and the global
    /// cap are counted exactly as for the whole deck, so a tag is not a second
    /// deck with a second day's worth of new cards.
    static func plan(
        decks: [Deck],
        filters: [String: DeckFilter]? = nil,
        tagIndexes: [String: DeckFilter.TagIndex] = [:],
        sqlNoteLimit: Int = QueueBuilder.sqlNoteLimit,
        now: Date = .now,
        config: QueueConfig = QueueConfig(),
        recentLogs: [ReviewLog] = [],
        logsToday: [ReviewLog] = [],
        calendar: Calendar = .current,
        using generator: inout some RandomNumberGenerator
    ) -> QueuePlan {
        let live = decks.filter { $0.deletedAt == nil }
        let titles = live.map(\.sheetTitle)
        let secondsPerCard = secondsPerCard(from: recentLogs, config: config)
        let studyDay = calendar.startOfDay(for: now)

        // Cards are selected by *query*, not by walking the object graph (#84).
        //
        // The old version was `for deck { for note { for card` — which materialises
        // every `Note` and every `Card` in the store to read four scalars off each.
        // Measured on 10k cards it took **3.0 s** against §8's 300 ms budget, and
        // the profile said exactly where it went: fetching the cards costs 0.17 s,
        // and reading `card.note.deck` across the results costs **1.03 s** on its
        // own. Relationship traversal is the entire bill; the arithmetic is free.
        //
        // So nothing below touches `card.note` per card. The filtering that used to
        // be `where` clauses is now a `#Predicate` — including the two hops to
        // `note.deletedAt` and `note.deck.sheetTitle`, which SwiftData turns into a
        // join and which measured free (0.086 s for the same 10k).
        guard let context = live.first?.modelContext, !titles.isEmpty else {
            // A deck that belongs to no store has no cards to select. Returning
            // empty is the honest answer, and it keeps `secondsPerCard` and
            // `studyDay` meaningful for a caller that only reads those.
            return QueuePlan(cardIds: [], dueReviewCount: 0, newCardCount: 0,
                             secondsPerCard: secondsPerCard, studyDay: studyDay)
        }

        // Due reviews — anything already learned and now owed, including learning
        // and relearning cards whose intra-day timer has already expired.
        //
        // `lastReview != nil` rather than `state != .new`, because `SchedulingState`
        // cannot appear in a `#Predicate` at all — the enum lives in another module
        // and is not one of the schema's value types, so equality is rejected as
        // flatly as inequality. The two are exactly equivalent: a card is `.new`
        // until its first rating, and that rating is what sets `lastReview`. They
        // are written from one snapshot by `rate`, by undo and by a restore, so it
        // is an invariant rather than a coincidence — and `StatsTests` asserts it
        // directly instead of leaving this comment to be believed.
        let dueDescriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
            !card.isSuspended
                && card.due <= now
                && card.lastReview != nil
                && card.note.deletedAt == nil
                && titles.contains(card.note.deck.sheetTitle)
        })
        // #153: each deck's filter, and the notes it keeps. A deck on `.all` has
        // no entry, and with no entries this whole path is the one it always was.
        var applied: [String: DeckFilter] = [:]
        var allowed: [String: Set<UUID>] = [:]
        for title in titles {
            let filter: DeckFilter
            let index: DeckFilter.TagIndex?
            if let filters {
                filter = filters[title] ?? .all
                index = filter == .all ? nil
                    : tagIndexes[title] ?? TagIndexCache.shared.index(forDeckTitled: title, in: context)
            } else {
                (filter, index) = DeckFilter.applied(toDeckTitled: title, in: context)
            }
            guard filter != .all, let notes = index?.noteIds(matching: filter) else { continue }
            applied[title] = filter
            allowed[title] = notes
        }
        let dueCards = allowed.isEmpty
            ? (try? context.fetch(dueDescriptor)) ?? []
            : filteredDueCards(titles: titles, allowed: allowed, now: now,
                               sqlNoteLimit: sqlNoteLimit, in: context)
        let dueOrdered = orderDueCards(dueCards, calendar: calendar, using: &generator)

        // New cards — per-deck allowance first, then the global ceiling, always in
        // sheet row order so the owner's ordering in Sheets decides what is learned
        // first.
        let introduced = introducedToday(logsToday: logsToday, in: context,
                                         now: now, calendar: calendar)
        var newCards: [Card] = []
        for deck in live.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let allowance = max(0, deck.newCardsPerDay - (introduced[deck.sheetTitle] ?? 0))
            guard allowance > 0 else { continue }
            newCards.append(contentsOf: nextNewCards(in: context,
                                                     deckTitle: deck.sheetTitle,
                                                     allowance: allowance,
                                                     allowedNotes: allowed[deck.sheetTitle],
                                                     sqlNoteLimit: sqlNoteLimit))
        }
        // The ceiling is the day's, so what the day has already introduced —
        // in every deck, not only these — comes off it first. Home rebuilds the
        // plan several times a day; a cap counted from zero on each build let
        // the second build hand out another thirty from the decks not yet touched.
        let spent = introduced.values.reduce(0, +)
        newCards = Array(newCards.prefix(max(0, config.globalNewCardCap - spent)))

        return QueuePlan(
            cardIds: dueOrdered.map(\.id) + newCards.map(\.id),
            dueReviewCount: dueOrdered.count,
            newCardCount: newCards.count,
            secondsPerCard: secondsPerCard,
            studyDay: studyDay,
            filters: applied
        )
    }

    /// One deck's next new cards, in sheet row order (§5.2).
    ///
    /// Ordered **entirely in SQL**, so the store returns a short window rather than
    /// every unseen card in the deck. The second sort key is `Card.id`, which is not
    /// an arbitrary choice: the id is `"<note uuid>#fwd"`, a fixed-width uuid
    /// followed by the direction, so ordering by it *is* ordering by
    /// `(note.id, direction)` — the exact tie-break §5.2 specifies, expressed in one
    /// indexed string column.
    ///
    /// An earlier attempt sorted on `sheetRow` alone and re-sorted a wider window in
    /// memory, assuming ties are rare and shallow. A test with sixty notes sharing
    /// one row index disproved it on the first run: SQLite returns an arbitrary
    /// subset for the limit, and the ten that should have come first were not all in
    /// it. Sorting completely in SQL removed the assumption instead of widening it.
    ///
    /// ## Why `state` is checked again in memory
    ///
    /// `lastReview == nil` is the SQL stand-in for `.new` (see `plan`). It is exact
    /// for any card the app can produce — but if it ever were not, the consequence
    /// *here* is the worst one in the app: a card halfway through its learning steps
    /// would be handed back as if it had never been seen, resetting real scheduling
    /// state. So the predicate is treated as a cheap **filter** and `state` as the
    /// **authority**. The window is wider than the allowance to leave room for rows
    /// the filter over-includes, so the cost of the belt-and-braces is one short
    /// fetch, and the worst case becomes "slightly fewer new cards today" rather
    /// than "a learning card silently reset".
    ///
    /// ## With a tag (#144)
    ///
    /// The tag cannot go into the predicate, so a window of the deck's next new
    /// cards might hold none of the tag's. The window is therefore **paged**: each
    /// page is filtered by note id, and the next is fetched, four times wider,
    /// until the allowance is met or the deck runs out. Row order is kept because
    /// every page comes from the same SQL sort. Without a tag it is one page, as
    /// before.
    private static func nextNewCards(
        in context: ModelContext,
        deckTitle: String,
        allowance: Int,
        allowedNotes: Set<UUID>? = nil,
        sqlNoteLimit: Int = QueueBuilder.sqlNoteLimit
    ) -> [Card] {
        if let allowedNotes, allowedNotes.count <= sqlNoteLimit {
            let sqlNotes = Array(allowedNotes)
            // Exact in SQL, so one window in row order is the answer.
            var descriptor = FetchDescriptor<Card>(
                predicate: #Predicate<Card> { card in
                    !card.isSuspended
                        && card.lastReview == nil
                        && card.note.deletedAt == nil
                        && card.note.deck.sheetTitle == deckTitle
                        && sqlNotes.contains(card.note.id)
                },
                sortBy: [SortDescriptor(\Card.note.sheetRow), SortDescriptor(\Card.id)]
            )
            descriptor.fetchLimit = allowance * 2 + 16
            let window = (try? context.fetch(descriptor)) ?? []
            return Array(window.lazy.filter { $0.state == .new }.prefix(allowance))
        }
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                !card.isSuspended
                    && card.lastReview == nil
                    && card.note.deletedAt == nil
                    && card.note.deck.sheetTitle == deckTitle
            },
            sortBy: [SortDescriptor(\Card.note.sheetRow), SortDescriptor(\Card.id)]
        )
        descriptor.fetchLimit = allowance * 2 + 16
        guard let allowedNotes else {
            let window = (try? context.fetch(descriptor)) ?? []
            return Array(window.lazy.filter { $0.state == .new }.prefix(allowance))
        }
        guard !allowedNotes.isEmpty else { return [] }

        var picked: [Card] = []
        var offset = 0
        while picked.count < allowance {
            descriptor.fetchOffset = offset
            let page = (try? context.fetch(descriptor)) ?? []
            picked += page.lazy.filter { card in
                card.state == .new
                    && (Card.noteId(inCardId: card.id).map(allowedNotes.contains) ?? false)
            }
            guard page.count == descriptor.fetchLimit else { break }
            offset += page.count
            descriptor.fetchLimit = page.count * 4
        }
        return Array(picked.prefix(allowance))
    }

    /// Due cards when some decks are filtered: the unfiltered decks in one fetch,
    /// as always, and each filtered deck on its own — its tag's notes in the SQL
    /// when there are few enough (`sqlNoteLimit`), else the deck's due cards
    /// filtered here by note id, never by reading `card.note`.
    private static func filteredDueCards(
        titles: [String], allowed: [String: Set<UUID>], now: Date,
        sqlNoteLimit: Int, in context: ModelContext
    ) -> [Card] {
        let open = titles.filter { allowed[$0] == nil }
        var cards: [Card] = []
        if !open.isEmpty {
            cards += (try? context.fetch(FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
                !card.isSuspended
                    && card.due <= now
                    && card.lastReview != nil
                    && card.note.deletedAt == nil
                    && open.contains(card.note.deck.sheetTitle)
            }))) ?? []
        }
        for (title, notes) in allowed {
            if notes.count <= sqlNoteLimit {
                let ids = Array(notes)
                cards += (try? context.fetch(FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
                    !card.isSuspended
                        && card.due <= now
                        && card.lastReview != nil
                        && card.note.deletedAt == nil
                        && card.note.deck.sheetTitle == title
                        && ids.contains(card.note.id)
                }))) ?? []
            } else {
                let deckDue = (try? context.fetch(FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
                    !card.isSuspended
                        && card.due <= now
                        && card.lastReview != nil
                        && card.note.deletedAt == nil
                        && card.note.deck.sheetTitle == title
                }))) ?? []
                cards += deckDue.filter { Card.noteId(inCardId: $0.id).map(notes.contains) ?? false }
            }
        }
        // Several fetches, so no single store order: sorted, so the same cards
        // and the same seed make the same queue whichever route found them. By
        // ids read **once**: a comparator reading `card.id` reads a model
        // property twice per comparison, 140k reads on 5k cards — measured at
        // 0.1 s, a third of §8's budget, for an ordering.
        return cards.map { ($0.id, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Up to this many notes, a tag's note ids go into the SQL itself
    /// (`IN (…)`), so the store returns only that tag's cards.
    ///
    /// The first version of #144 always fetched the whole deck and filtered in
    /// memory. On 10k cards that measured 0.24 s alone and 0.32–0.34 s inside the
    /// full suite — over §8's 0.3 s in two runs of three, because a rare tag still
    /// paid for every due card and paged through thousands of new ones. Past this
    /// size a tag holds enough of the deck that the whole-deck fetch is no worse,
    /// and the list stays far below SQLite's limit on bound values.
    static let sqlNoteLimit = 2_000

    /// `due` ascending, shuffled within a calendar day.
    ///
    /// Two cards owed from the same day carry no meaningful order between them —
    /// the timestamps only reflect when they happened to be rated — so showing them
    /// in a fixed order every session would drill the same sequence. Ordering
    /// *between* days is preserved, so the longest-overdue material still comes
    /// first.
    private static func orderDueCards(
        _ cards: [Card],
        calendar: Calendar,
        using generator: inout some RandomNumberGenerator
    ) -> [Card] {
        let byDay = Dictionary(grouping: cards) { calendar.startOfDay(for: $0.due) }
        return byDay.keys.sorted().flatMap { day in
            byDay[day, default: []].shuffled(using: &generator)
        }
    }

    /// New cards already introduced today, per deck, so a second session on the
    /// same day does not hand out a fresh full allowance.
    ///
    /// This has to come from the log: a card that is no longer `.new` looks
    /// identical whether it was introduced this morning or last month. A log row
    /// with `stateBefore == .new` is the only record of the transition.
    private static func introducedToday(
        logsToday: [ReviewLog],
        in context: ModelContext,
        now: Date,
        calendar: Calendar
    ) -> [String: Int] {
        // A card counts once even if both its directions were introduced, because
        // the allowance is about new *material*, not new sides of it. A `Set` of
        // ids gives that for free, and it is also what makes the fetch below small.
        let ids = Set(
            logsToday
                .filter { $0.stateBefore == .new && $0.rating != 0
                    && calendar.isDate($0.reviewedAt, inSameDayAs: now) }
                .map(\.cardId)
        )
        guard !ids.isEmpty else { return [:] }

        // #84: this used to build a card-id → deck map by walking every deck, note
        // and card in the store — thousands of faults to answer a question about
        // the handful of cards introduced *today*. Fetching those by id and reading
        // the deck off each is bounded by the daily new-card cap instead.
        let identifiers = Array(ids)
        let descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { identifiers.contains($0.id) })
        let cards = (try? context.fetch(descriptor)) ?? []

        var counts: [String: Int] = [:]
        for card in cards {
            counts[card.note.deck.sheetTitle, default: 0] += 1
        }
        return counts
    }

    /// Average seconds per card, measured from the gaps between consecutive reviews
    /// in the most recent logs (§5.2). `ReviewLog` records when a review happened,
    /// not how long it took, so the gap is the only available signal; gaps longer
    /// than `maxPlausibleSecondsPerCard` are breaks between sessions, not cards.
    static func secondsPerCard(from logs: [ReviewLog], config: QueueConfig = QueueConfig()) -> TimeInterval {
        let times = logs
            .filter { $0.rating != 0 }               // undo markers are not reviews (§5.5)
            .map(\.reviewedAt)
            .sorted()
            .suffix(config.estimateSampleSize)

        guard times.count >= 2 else { return config.defaultSecondsPerCard }

        let gaps = zip(times, times.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 && $0 <= config.maxPlausibleSecondsPerCard }

        guard !gaps.isEmpty else { return config.defaultSecondsPerCard }
        return gaps.reduce(0, +) / Double(gaps.count)
    }
}
