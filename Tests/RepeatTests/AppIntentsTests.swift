import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #29 — the three intents, tested where the logic lives.
///
/// `AppIntent.perform()` cannot be driven from a unit test, so the framework
/// types stay a shell and everything that touches the store lives in
/// `IntentActions`, which can.
final class AppIntentsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    private func defaults() -> UserDefaults {
        let name = "intents-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    @discardableResult
    private func insertDeck(_ title: String, in context: ModelContext, sortOrder: Int = 0) throws -> Deck {
        let deck = Deck(sheetTitle: title, sheetId: sortOrder, sortOrder: sortOrder)
        context.insert(deck)
        try context.save()
        return deck
    }

    // MARK: - Add card

    /// The acceptance criterion: the note has to be one the push will pick up.
    func testAddCardCreatesANoteQueuedForTheNextPush() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context)

        let outcome = try IntentActions.addCard(
            front: "reluctant", back: "неохочий", deckTitle: "Verbs",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .saved(front: "reluctant", deck: "Verbs"))

        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.pendingUpload, "a card the Sheet has never seen must be queued")
        XCTAssertEqual(note.sheetRow, 0, "row 0 is what 'not in the Sheet yet' means")
        XCTAssertNil(note.lastSyncedHash, "there is no common ancestor for a locally added note")
        XCTAssertEqual(note.cards.count, 1, "one direction, since reverse was not asked for")
    }

    /// A named deck is matched case- and accent-insensitively: someone dictating
    /// "verbs" to Siri should not miss a deck called "Verbs".
    func testDeckIsMatchedLoosely() throws {
        let context = try makeStore()
        try insertDeck("Дієслова", in: context)

        let outcome = try IntentActions.addCard(
            front: "run", back: "бігти", deckTitle: "дієслова",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .saved(front: "run", deck: "Дієслова"))
    }

    /// Filing into the wrong deck silently is worse than refusing.
    func testUnknownDeckIsRefusedRatherThanGuessed() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context)

        let outcome = try IntentActions.addCard(
            front: "run", back: "бігти", deckTitle: "Nouns",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .unknownDeck("Nouns"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    /// With no deck named, the intent lands where the Add form would.
    func testNoDeckNamedUsesTheLastUsedDeck() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context, sortOrder: 0)
        let nouns = try insertDeck("Nouns", in: context, sortOrder: 1)

        let suite = defaults()
        AddCardComposer.LastDeck.remember(nouns, defaults: suite)

        let outcome = try IntentActions.addCard(
            front: "table", back: "стіл", deckTitle: nil,
            in: context, defaults: suite, now: now
        )
        XCTAssertEqual(outcome, .saved(front: "table", deck: "Nouns"))
    }

    /// Deleted and malformed decks are not somewhere to file a card.
    func testDeletedAndMalformedDecksAreNotCandidates() throws {
        let context = try makeStore()
        let gone = try insertDeck("Gone", in: context, sortOrder: 0)
        gone.deletedAt = now
        let broken = try insertDeck("Broken", in: context, sortOrder: 1)
        broken.malformedReason = "no back column"
        try context.save()

        let outcome = try IntentActions.addCard(
            front: "x", back: "y", deckTitle: nil, in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .noDecks)

        let named = try IntentActions.addCard(
            front: "x", back: "y", deckTitle: "Gone", in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(named, .noDecks, "a deleted deck is not a deck to be told about")
    }

    /// §7.4 names the intent `AddCard(front:deck:)`. Without an answer there is
    /// no card, so the text becomes a capture instead of an empty note.
    func testFrontOnlyBecomesACaptureNotAnEmptyCard() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context)

        let outcome = try IntentActions.addCard(
            front: "reluctant", back: nil, deckTitle: "Verbs",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .captured(front: "reluctant"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty,
                      "an answerless note would be pushed to the Sheet as a blank column")

        let inbox = try context.fetch(FetchDescriptor<InboxItem>())
        XCTAssertEqual(inbox.map(\.text), ["reluctant"])
    }

    /// Whitespace is not an answer, and Shortcuts hands over whatever it has.
    func testWhitespaceOnlyBackIsTreatedAsMissing() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context)

        let outcome = try IntentActions.addCard(
            front: " reluctant ", back: "  \n", deckTitle: "Verbs",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .captured(front: "reluctant"))
    }

    func testEmptyFrontAddsNothing() throws {
        let context = try makeStore()
        try insertDeck("Verbs", in: context)

        let outcome = try IntentActions.addCard(
            front: "   ", back: "неохочий", deckTitle: "Verbs",
            in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .emptyFront)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxItem>()).isEmpty)
    }

    /// A fresh install has nothing to file into, and should say so rather than
    /// inventing a deck.
    func testNoDecksAtAll() throws {
        let context = try makeStore()
        let outcome = try IntentActions.addCard(
            front: "x", back: "y", deckTitle: nil, in: context, defaults: defaults(), now: now
        )
        XCTAssertEqual(outcome, .noDecks)
    }

    // MARK: - Pending route

    /// §7.4: `StartReviewIntent` runs before the UI exists.
    func testPendingRouteRoundTrips() {
        let suite = defaults()
        XCTAssertNil(PendingRoute.consume(defaults: suite))

        PendingRoute.request(.study, defaults: suite)
        XCTAssertEqual(PendingRoute.consume(defaults: suite), .study)
    }

    /// #109: the notification's link is the third destination, parsed the way
    /// the other two are — host, not path.
    func testTheStatsLinkRoutesToStats() {
        XCTAssertEqual(DeepLink.destination(for: URL(string: DeepLink.stats)!), .stats)
        XCTAssertEqual(DeepLink.destination(for: URL(string: "repeat://STATS")!), .stats)
        XCTAssertEqual(DeepLink.destination(for: URL(string: "repeat:///stats")!), .stats)
    }

    func testPendingRouteCarriesStats() {
        let suite = defaults()
        PendingRoute.request(.stats, defaults: suite)
        XCTAssertEqual(PendingRoute.consume(defaults: suite), .stats)
        XCTAssertNil(PendingRoute.consume(defaults: suite))
    }

    /// Reading it twice would send the person back into a session they already
    /// left — the app looking like it is ignoring them.
    func testPendingRouteIsConsumedOnce() {
        let suite = defaults()
        PendingRoute.request(.add, defaults: suite)

        XCTAssertEqual(PendingRoute.consume(defaults: suite), .add)
        XCTAssertNil(PendingRoute.consume(defaults: suite))
    }

    /// A stored value from some other build should not crash the routing.
    func testUnknownStoredRouteIsIgnored() {
        let suite = defaults()
        suite.set("teleport", forKey: PendingRoute.key)
        XCTAssertNil(PendingRoute.consume(defaults: suite))
    }

    // MARK: - Due count

    /// The locked decision from #26: one definition of "due". The intent quotes
    /// the published file rather than counting for itself.
    func testDueCountQuotesTheFreshPublishedFileWithoutRecomputing() throws {
        let context = try makeStore()
        // A deck with a due card, so recomputing would give a *different*
        // number. The test only passes if the file wins.
        let deck = try insertDeck("Verbs", in: context)
        var draft = AddCardComposer.Draft()
        draft.front = "reluctant"
        draft.back = "неохочий"
        try AddCardComposer.save(draft, to: deck, in: context, now: now)

        let url = dueCountURL()
        try DueCount(due: 7, day: Calendar.current.startOfDay(for: now), generatedAt: now)
            .write(to: url)

        XCTAssertEqual(IntentActions.dueCount(in: context, now: now, url: url), 7)
    }

    /// A count from yesterday is not a small error — it is the wrong number.
    /// Republishing keeps the single definition rather than adding a second one.
    func testStaleFileIsRepublishedRatherThanQuoted() throws {
        let context = try makeStore()
        let deck = try insertDeck("Verbs", in: context)
        var draft = AddCardComposer.Draft()
        draft.front = "reluctant"
        draft.back = "неохочий"
        try AddCardComposer.save(draft, to: deck, in: context, now: now)

        let url = dueCountURL()
        let yesterday = now.addingTimeInterval(-86_400)
        try DueCount(due: 999, day: Calendar.current.startOfDay(for: yesterday), generatedAt: yesterday)
            .write(to: url)

        let count = try XCTUnwrap(IntentActions.dueCount(in: context, now: now, url: url))
        XCTAssertEqual(count, 1, "one new card is due; 999 was yesterday's number")

        let rewritten = try XCTUnwrap(DueCount.read(from: url))
        XCTAssertTrue(rewritten.isFresh(on: now), "the stale file should have been replaced")
    }

    /// No App Group container means the write silently did nothing. Guessing a
    /// number then — especially zero — would tell someone their day is clear.
    func testUnwritableDestinationReportsUnknownRatherThanZero() throws {
        let context = try makeStore()
        let unwritable = URL(fileURLWithPath: "/dev/null/nope/due.json")
        XCTAssertNil(IntentActions.dueCount(in: context, now: now, url: unwritable))
    }

    private func dueCountURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("due-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
