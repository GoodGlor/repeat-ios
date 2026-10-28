import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #144 — studying a deck whole or by one tag.
final class DeckFilterTests: XCTestCase {

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    @discardableResult
    private func addNote(
        _ ctx: ModelContext, to deck: Deck, row: Int, tags: [String] = [],
        due: Bool = false, suspended: Bool = false
    ) -> Card {
        let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", tags: tags, sheetRow: row)
        ctx.insert(note)
        let card = ctx.syncCards(for: note, now: now)[0]
        card.isSuspended = suspended
        if due {
            card.state = .review
            card.reps = 3
            card.stability = 10
            card.due = now.addingTimeInterval(-3600)
            card.lastReview = now.addingTimeInterval(-86_400 * 5)
        }
        return card
    }

    private func plan(
        _ decks: [Deck], filter: DeckFilter = .all, logsToday: [ReviewLog] = [],
        config: QueueConfig = QueueConfig(), seed: UInt64 = 7
    ) -> QueuePlan {
        var rng = SeededGenerator(seed: seed)
        // Explicit filters, so a test never reads what the app left in defaults.
        return QueueBuilder.plan(decks: decks,
                                 filters: Dictionary(uniqueKeysWithValues: decks.map { ($0.sheetTitle, filter) }),
                                 now: now, config: config,
                                 logsToday: logsToday, calendar: calendar, using: &rng)
    }

    private func introduced(_ ids: [String]) throws -> [ReviewLog] {
        try ids.map {
            try ReviewLog(cardId: $0, direction: .forward, rating: 3, reviewedAt: now,
                          elapsedDays: 0, scheduledDays: 0, stateBefore: .new,
                          prevState: CardSchedulingSnapshot())
        }
    }

    // MARK: - The picker's choices

    func testNoTagsMeansNoControl() {
        XCTAssertEqual(DeckFilter.options(tags: [[], [], [" "]]), [])
    }

    func testChoicesAreEverythingThenTagsByNameThenNoTag() {
        let options = DeckFilter.options(tags: [["verbs", "b1"], ["adjectives"], [], ["verbs"]])
        XCTAssertEqual(options, [.all, .tag("adjectives"), .tag("b1"), .tag("verbs"), .untagged])
    }

    func testNoTagIsOfferedOnlyWhenSomeNoteHasNone() {
        XCTAssertEqual(DeckFilter.options(tags: [["a"], ["b"]]), [.all, .tag("a"), .tag("b")])
    }

    // MARK: - Remembered per deck

    func testTheChoiceIsRememberedPerDeckAndFallsBackWhenTheTagIsGone() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeckFilterTests"))
        defaults.removePersistentDomain(forName: "DeckFilterTests")
        let options: [DeckFilter] = [.all, .tag("verbs"), .untagged]

        XCTAssertEqual(DeckFilter.remembered(forDeckTitled: "A", options: options, defaults: defaults), .all,
                       "a deck never filtered studies everything")
        DeckFilter.remember(.tag("verbs"), forDeckTitled: "A", defaults: defaults)
        DeckFilter.remember(.untagged, forDeckTitled: "B", defaults: defaults)
        XCTAssertEqual(DeckFilter.remembered(forDeckTitled: "A", options: options, defaults: defaults), .tag("verbs"))
        XCTAssertEqual(DeckFilter.remembered(forDeckTitled: "B", options: options, defaults: defaults), .untagged)

        // A sync removed the tag.
        XCTAssertEqual(DeckFilter.remembered(forDeckTitled: "A", options: [.all, .untagged], defaults: defaults), .all)
        // Or every tag.
        XCTAssertEqual(DeckFilter.remembered(forDeckTitled: "B", options: [], defaults: defaults), .all)
    }

    func testATagNamedLikeAKeywordSurvivesTheRoundTrip() {
        for filter: DeckFilter in [.all, .untagged, .tag("all"), .tag("untagged"), .tag("tag:x"), .tag("")] {
            XCTAssertEqual(DeckFilter(storageValue: filter.storageValue), filter)
        }
    }

    // MARK: - The queue

    func testEverythingIsExactlyTheOldWholeDeckSession() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        for row in 0..<12 { addNote(ctx, to: deck, row: row, tags: row % 2 == 0 ? ["even"] : [], due: row < 6) }
        try ctx.save()

        var rng = SeededGenerator(seed: 7)
        let old = QueueBuilder.plan(decks: [deck], filters: [:], now: now, calendar: calendar, using: &rng)
        XCTAssertEqual(plan([deck], filter: .all), old, "same card ids for the same seed")
        XCTAssertEqual(old.count, 12)
    }

    func testATagSessionHoldsOnlyThatTagsCards() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        var tagged: Set<String> = []
        for row in 0..<10 {
            let card = addNote(ctx, to: deck, row: row, tags: row % 3 == 0 ? ["verbs", "b1"] : ["nouns"], due: row < 5)
            if row % 3 == 0 { tagged.insert(card.id) }
        }
        // Never in any session: suspended, and soft-deleted.
        addNote(ctx, to: deck, row: 20, tags: ["verbs"], due: true, suspended: true)
        let gone = addNote(ctx, to: deck, row: 21, tags: ["verbs"])
        gone.note.deletedAt = now
        try ctx.save()

        let result = plan([deck], filter: .tag("verbs"))
        XCTAssertEqual(Set(result.cardIds), tagged)
        XCTAssertEqual(result.dueReviewCount, 2, "rows 0 and 3 are due")
        XCTAssertEqual(result.newCardCount, 2, "rows 6 and 9 are new")
        XCTAssertEqual(result.count, result.dueReviewCount + result.newCardCount,
                       "the counts are the session")
    }

    /// `options` lists tags trimmed, so matching must trim too, or a tag typed
    /// with a space on the phone would be offered and then match nothing.
    func testATagMatchesWhateverSpacesItWasTypedWith() {
        XCTAssertTrue(DeckFilter.tag("verbs").matches([" verbs "]))
        XCTAssertEqual(DeckFilter.options(tags: [[" verbs "]]), [.all, .tag("verbs")])
    }

    func testNoTagHoldsOnlyTheUntaggedCards() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        addNote(ctx, to: deck, row: 0, tags: ["a"])
        let bare = addNote(ctx, to: deck, row: 1)
        try ctx.save()
        XCTAssertEqual(plan([deck], filter: .untagged).cardIds, [bare.id])
    }

    /// The tag's cards sit far below a window of untagged ones; paging must
    /// reach them, and in row order.
    func testATagsNewCardsAreFoundBelowAWindowOfOthersInRowOrder() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1, newCardsPerDay: 3); ctx.insert(deck)
        for row in 0..<200 { addNote(ctx, to: deck, row: row) }
        let deep = [500, 400, 300, 600].map { addNote(ctx, to: deck, row: $0, tags: ["rare"]) }
        try ctx.save()

        XCTAssertEqual(plan([deck], filter: .tag("rare")).cardIds, [deep[2], deep[1], deep[0]].map(\.id))
    }

    func testATagMatchingNothingIsAnEmptySession() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        addNote(ctx, to: deck, row: 0, tags: ["a"], due: true)
        try ctx.save()
        XCTAssertTrue(plan([deck], filter: .tag("gone")).isEmpty)
    }

    /// A tag narrows the session, it is not a second deck: what the tag session
    /// introduced comes off the deck's day and the global ceiling alike.
    func testTheAllowanceAndTheCapHoldAcrossATagSessionThenTheWholeDeck() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1, newCardsPerDay: 5); ctx.insert(deck)
        for row in 0..<20 { addNote(ctx, to: deck, row: row, tags: row % 2 == 0 ? ["even"] : []) }
        try ctx.save()

        let tagSession = plan([deck], filter: .tag("even"))
        XCTAssertEqual(tagSession.newCardCount, 5)
        let afterTag = try introduced(tagSession.cardIds)
        XCTAssertEqual(plan([deck], filter: .all, logsToday: afterTag).newCardCount, 0,
                       "the deck's five were spent by the tag session")

        // And with the deck's allowance above the ceiling, the ceiling holds.
        deck.newCardsPerDay = 50
        var config = QueueConfig(); config.globalNewCardCap = 8
        let whole = plan([deck], filter: .all, logsToday: afterTag, config: config)
        XCTAssertEqual(whole.newCardCount, 3, "eight a day, five already introduced")
    }

    // MARK: - The index read off the main queue

    func testTheIndexHoldsTheDecksLiveNotesOnly() async throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        let other = Deck(sheetTitle: "Other", sheetId: 2); ctx.insert(other)
        addNote(ctx, to: deck, row: 0, tags: ["kept"])
        addNote(ctx, to: deck, row: 1)
        addNote(ctx, to: deck, row: 2, tags: ["deleted"]).note.deletedAt = now
        addNote(ctx, to: other, row: 0, tags: ["elsewhere"])
        try ctx.save()

        let index = await DeckFilter.TagIndex.load(deckTitled: "Words", from: ctx.container)
        XCTAssertEqual(index.tagsByNote.count, 2)
        XCTAssertEqual(index.options, [.all, .tag("kept"), .untagged])
    }

    /// The index is a shortcut, not a second definition: the plan it gives is
    /// the plan the fallback fetch gives, card for card.
    func testAPlanFromTheIndexIsThePlanWithoutIt() async throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1, newCardsPerDay: 4); ctx.insert(deck)
        for row in 0..<30 {
            addNote(ctx, to: deck, row: row, tags: row % 4 == 0 ? [] : row % 2 == 0 ? ["even"] : ["odd"],
                    due: row % 3 == 0)
        }
        try ctx.save()
        let index = await DeckFilter.TagIndex.load(deckTitled: "Words", from: ctx.container)

        for filter in index.options + [.tag("gone")] {
            var withIndex = SeededGenerator(seed: 3), without = SeededGenerator(seed: 3)
            XCTAssertEqual(
                QueueBuilder.plan(decks: [deck], filters: ["Words": filter], tagIndexes: ["Words": index], now: now,
                                  calendar: calendar, using: &withIndex),
                QueueBuilder.plan(decks: [deck], filters: ["Words": filter], now: now,
                                  calendar: calendar, using: &without),
                "\(filter)")
        }
    }

    /// A tag's notes go into the SQL up to `sqlNoteLimit`, and past it the
    /// whole deck is fetched and filtered in memory. Two routes, one answer:
    /// forcing the in-memory route (limit 0) gives the same plan, card for card.
    func testTheSQLRouteAndTheInMemoryRouteGiveTheSamePlan() async throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: "Words", sheetId: 1, newCardsPerDay: 4); ctx.insert(deck)
        for row in 0..<120 {
            addNote(ctx, to: deck, row: row, tags: row % 5 == 0 ? [] : row % 2 == 0 ? ["even"] : ["odd"],
                    due: row % 3 == 0, suspended: row == 9)
        }
        try ctx.save()
        let index = await DeckFilter.TagIndex.load(deckTitled: "Words", from: ctx.container)

        for filter in index.options + [.tag("gone")] {
            var sql = SeededGenerator(seed: 5), memory = SeededGenerator(seed: 5)
            XCTAssertEqual(
                QueueBuilder.plan(decks: [deck], filters: ["Words": filter], tagIndexes: ["Words": index], now: now,
                                  calendar: calendar, using: &sql),
                QueueBuilder.plan(decks: [deck], filters: ["Words": filter], tagIndexes: ["Words": index], sqlNoteLimit: 0,
                                  now: now, calendar: calendar, using: &memory),
                "\(filter)")
        }
    }

    /// The read runs on a context of its own; the main one is never touched
    /// off its queue (the 2026-09-04 crash).
    @MainActor
    func testReadingTheIndexNeverTouchesTheMainContextOffItsQueue() async throws {
        let container = try ModelStore.container(inMemory: true)
        let ctx = container.mainContext
        let deck = Deck(sheetTitle: "Words", sheetId: 1); ctx.insert(deck)
        for row in 0..<50 { addNote(ctx, to: deck, row: row, tags: ["t\(row % 3)"]) }
        try ctx.save()
        let start = Date()

        let index = await DeckFilter.TagIndex.load(deckTitled: "Words", from: container)
        var rng = SeededGenerator(seed: 1)
        _ = QueueBuilder.plan(decks: [deck], filters: ["Words": .tag("t1")], tagIndexes: ["Words": index], now: now,
                              calendar: calendar, using: &rng)

        XCTAssertEqual(index.tagsByNote.count, 50)
        XCTAssertEqual(try OffQueue.uses(since: start), [])
    }

    // MARK: - #153: the deck's own setting scopes every plan

    /// Unique titles, so these tests' settings in the standard defaults can
    /// never meet another test's decks; removed again in `tearDown`.
    private var settingTitles: [String] = []
    private func settingTitle(_ name: String) -> String {
        let title = "\(name)-\(UUID().uuidString)"
        settingTitles.append(title)
        return title
    }

    override func tearDown() {
        for title in settingTitles { UserDefaults.standard.removeObject(forKey: "deckFilter." + title) }
        TagIndexCache.shared.invalidate()
        super.tearDown()
    }

    private func defaultPlan(_ decks: [Deck]) -> QueuePlan {
        var rng = SeededGenerator(seed: 7)
        return QueueBuilder.plan(decks: decks, now: now, calendar: calendar, using: &rng)
    }

    /// The owner's example: two decks of ten due; tag one down to five and the
    /// plan everything reads — Home's number, the all-decks session — is 15.
    func testADecksSettingScopesThePlanOfAllDecksAndOfThatDeck() throws {
        let ctx = try makeContext()
        let a = Deck(sheetTitle: settingTitle("A"), sheetId: 1); ctx.insert(a)
        let b = Deck(sheetTitle: settingTitle("B"), sheetId: 2, sortOrder: 1); ctx.insert(b)
        var grammar: Set<String> = []
        for row in 0..<10 {
            addNote(ctx, to: a, row: row, due: true)
            let card = addNote(ctx, to: b, row: row, tags: row < 5 ? ["grammar"] : ["other"], due: true)
            if row < 5 { grammar.insert(card.id) }
        }
        try ctx.save()
        XCTAssertEqual(defaultPlan([a, b]).count, 20, "nothing chosen: every card")

        DeckFilter.remember(.tag("grammar"), forDeckTitled: b.sheetTitle)
        let both = defaultPlan([a, b])
        XCTAssertEqual(both.count, 15)
        XCTAssertEqual(both.filters, [b.sheetTitle: .tag("grammar")], "Home names the tag from here")
        XCTAssertEqual(Set(defaultPlan([b]).cardIds), grammar, "the deck on its own: its five")
        XCTAssertEqual(defaultPlan([a]).count, 10, "the other deck is untouched")
    }

    func testASettingWhoseTagIsGoneStudiesTheWholeDeck() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: settingTitle("A"), sheetId: 1); ctx.insert(deck)
        for row in 0..<4 { addNote(ctx, to: deck, row: row, tags: ["kept"], due: true) }
        try ctx.save()
        DeckFilter.remember(.tag("removed-in-a-sync"), forDeckTitled: deck.sheetTitle)

        let plan = defaultPlan([deck])
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(plan.filters, [:])
    }

    /// Tags change only in a pull, which invalidates; a note added or deleted
    /// changes the count, which every lookup checks.
    func testTheTagCacheIsRebuiltWhenAPullOrTheNoteCountSaysSo() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: settingTitle("A"), sheetId: 1); ctx.insert(deck)
        let first = addNote(ctx, to: deck, row: 0, tags: ["old"])
        try ctx.save()
        let cache = TagIndexCache()
        XCTAssertEqual(cache.index(forDeckTitled: deck.sheetTitle, in: ctx).options, [.all, .tag("old")])

        addNote(ctx, to: deck, row: 1)
        try ctx.save()
        XCTAssertEqual(cache.index(forDeckTitled: deck.sheetTitle, in: ctx).options,
                       [.all, .tag("old"), .untagged], "a new note changes the count")

        first.note.tags = ["new"]
        try ctx.save()
        XCTAssertEqual(cache.index(forDeckTitled: deck.sheetTitle, in: ctx).options,
                       [.all, .tag("old"), .untagged], "kept until a pull says tags changed")
        cache.invalidate()
        XCTAssertEqual(cache.index(forDeckTitled: deck.sheetTitle, in: ctx).options,
                       [.all, .tag("new"), .untagged])
    }

    func testHomesDeckRowNamesTheTag() throws {
        let ctx = try makeContext()
        let deck = Deck(sheetTitle: settingTitle("A"), sheetId: 1); ctx.insert(deck)
        let other = Deck(sheetTitle: settingTitle("B"), sheetId: 2, sortOrder: 1); ctx.insert(other)
        for row in 0..<3 {
            addNote(ctx, to: deck, row: row, tags: ["grammar"], due: true)
            addNote(ctx, to: other, row: row, due: true)
        }
        addNote(ctx, to: deck, row: 9, tags: ["other"], due: true)
        try ctx.save()
        DeckFilter.remember(.tag("grammar"), forDeckTitled: deck.sheetTitle)

        let summary = HomeSummary.make(decks: [deck, other], plan: defaultPlan([deck, other]),
                                       logsToday: [], cachedTarget: nil, now: now)
        XCTAssertEqual(summary.dueCount, 6)
        XCTAssertEqual(summary.decks.map(\.due), [3, 3])
        XCTAssertEqual(summary.decks.map(\.filterLabel), ["grammar", nil])
    }
}
