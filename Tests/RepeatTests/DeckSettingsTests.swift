import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #21 — the two operations that have to be exactly right.
final class DeckSettingsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    @discardableResult
    private func makeDeck(
        _ context: ModelContext,
        title: String,
        sortOrder: Int = 0,
        newCardsPerDay: Int = 15,
        cards: Int = 3
    ) -> Deck {
        let deck = Deck(sheetTitle: title, sheetId: 0,
                        newCardsPerDay: newCardsPerDay, sortOrder: sortOrder)
        context.insert(deck)
        for index in 0..<cards {
            let note = Note(deck: deck, front: "\(title)-\(index)", back: "b")
            context.insert(note)
            context.insert(Card(note: note, direction: .forward, due: now))
        }
        return deck
    }

    private func plan(_ context: ModelContext) throws -> QueuePlan {
        var generator = SystemRandomNumberGenerator()
        return QueueBuilder.plan(
            decks: try context.fetch(FetchDescriptor<Deck>()), now: now, using: &generator)
    }

    // MARK: - Acceptance: new-cards-per-day changes the next queue build

    func testNewCardsPerDayChangesTheNextQueueBuild() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", newCardsPerDay: 15, cards: 20)
        try context.save()

        XCTAssertEqual(try plan(context).newCardCount, 15)

        deck.newCardsPerDay = 5
        try context.save()
        XCTAssertEqual(try plan(context).newCardCount, 5)

        // 0 is a real setting, not a disabled one: a deck can be kept for review
        // without introducing anything new.
        deck.newCardsPerDay = 0
        try context.save()
        XCTAssertEqual(try plan(context).newCardCount, 0)
        XCTAssertTrue(try plan(context).isEmpty)
    }

    // MARK: - Acceptance: suspend all removes cards without touching scheduling

    func testSuspendAllEmptiesTheQueueWithoutDisturbingScheduling() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 4)
        // Give the cards real scheduling state, so "untouched" means something.
        for (index, card) in deck.notes.flatMap(\.cards).enumerated() {
            card.state = .review
            card.due = now.addingTimeInterval(-Double(index) * 3600)
            card.stability = 12.5 + Double(index)
            card.difficulty = 5.25
            card.reps = 7
            card.lapses = 2
            card.learningStepIndex = 1
            card.lastReview = now.addingTimeInterval(-86_400)
        }
        try context.save()

        let before = deck.notes.flatMap(\.cards)
            .map(\.snapshot)
            .sorted { $0.due < $1.due }
        XCTAssertEqual(try plan(context).count, 4)

        let changed = try DeckSettings.setSuspended(true, deck: deck, in: context)

        XCTAssertEqual(changed, 4)
        XCTAssertTrue(try plan(context).isEmpty, "suspended cards never enter the queue")

        let after = deck.notes.flatMap(\.cards)
            .map(\.snapshot)
            .sorted { $0.due < $1.due }
        // Every scheduling field survives; only `isSuspended` moved.
        XCTAssertEqual(before.map(\.due), after.map(\.due))
        XCTAssertEqual(before.map(\.stability), after.map(\.stability))
        XCTAssertEqual(before.map(\.difficulty), after.map(\.difficulty))
        XCTAssertEqual(before.map(\.reps), after.map(\.reps))
        XCTAssertEqual(before.map(\.lapses), after.map(\.lapses))
        XCTAssertEqual(before.map(\.state), after.map(\.state))
        XCTAssertEqual(before.map(\.learningStepIndex), after.map(\.learningStepIndex))
        XCTAssertEqual(before.map(\.lastReview), after.map(\.lastReview))
    }

    func testResumingPutsTheDeckBackExactlyWhereItStopped() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 3)
        for card in deck.notes.flatMap(\.cards) {
            // `lastReview` and `reps` alongside `state`, the way
            // `testSuspendAllEmptiesTheQueueWithoutDisturbingScheduling` above
            // already does it: a reviewed card carries the evidence of its review,
            // and #84's queue reads `lastReview` as the queryable stand-in for
            // "not new".
            card.state = .review
            card.due = now.addingTimeInterval(-3600)
            card.stability = 9.5
            card.reps = 3
            card.lastReview = now.addingTimeInterval(-86_400)
        }
        try context.save()

        try DeckSettings.setSuspended(true, deck: deck, in: context)
        XCTAssertTrue(DeckSettings.isFullySuspended(deck))

        try DeckSettings.setSuspended(false, deck: deck, in: context)

        XCTAssertFalse(DeckSettings.isFullySuspended(deck))
        XCTAssertEqual(try plan(context).count, 3)
        XCTAssertTrue(deck.notes.flatMap(\.cards).allSatisfy { $0.stability == 9.5 })
    }

    func testSuspendingSkipsDeletedNotes() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Verbs", cards: 3)
        deck.notes[0].deletedAt = now
        try context.save()

        XCTAssertEqual(try DeckSettings.setSuspended(true, deck: deck, in: context), 2)
    }

    func testAnEmptyDeckIsNotReportedAsSuspended() throws {
        let context = try makeStore()
        let deck = makeDeck(context, title: "Empty", cards: 0)
        try context.save()
        XCTAssertFalse(DeckSettings.isFullySuspended(deck),
                       "an empty deck has nothing suspended; offering 'resume' would be nonsense")
    }

    // MARK: - Ordering

    func testMovingADeckRenumbersEveryPositionDensely() throws {
        let context = try makeStore()
        // All three arrive from new tabs at sortOrder 0 — the tie a swap-only
        // scheme would leave behind.
        let a = makeDeck(context, title: "A", sortOrder: 0, cards: 0)
        makeDeck(context, title: "B", sortOrder: 0, cards: 0)
        makeDeck(context, title: "C", sortOrder: 0, cards: 0)
        try context.save()

        let decks = try context.fetch(FetchDescriptor<Deck>())
        let order = try DeckSettings.move(a, .down, among: decks, in: context)

        XCTAssertEqual(order, ["B", "A", "C"])
        XCTAssertEqual(decks.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [0, 1, 2])
    }

    func testMovingPastTheEndsDoesNothing() throws {
        let context = try makeStore()
        let a = makeDeck(context, title: "A", sortOrder: 0, cards: 0)
        let b = makeDeck(context, title: "B", sortOrder: 1, cards: 0)
        try context.save()

        let decks = try context.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(try DeckSettings.move(a, .up, among: decks, in: context), ["A", "B"])
        XCTAssertEqual(try DeckSettings.move(b, .down, among: decks, in: context), ["A", "B"])
    }

    func testDeletedDecksAreNotGivenPositions() throws {
        let context = try makeStore()
        let a = makeDeck(context, title: "A", sortOrder: 0, cards: 0)
        makeDeck(context, title: "B", sortOrder: 1, cards: 0)
        let gone = makeDeck(context, title: "Gone", sortOrder: 2, cards: 0)
        gone.deletedAt = now
        try context.save()

        let order = try DeckSettings.move(a, .down, among: try context.fetch(FetchDescriptor<Deck>()),
                                          in: context)
        XCTAssertEqual(order, ["B", "A"])
    }

    // MARK: - The new attributes

    /// The migration rule `Note.lastSyncedHash` taught by breaking: a new
    /// attribute needs a default, or an existing store cannot be opened.
    func testTheNewTogglesDefaultToOffSoAnExistingStoreCanBeOpened() throws {
        let context = try makeStore()
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()

        XCTAssertFalse(deck.autoTTS)
        XCTAssertFalse(deck.typeAnswer)

        deck.autoTTS = true
        deck.typeAnswer = true
        try context.save()

        let reopened = try context.fetch(FetchDescriptor<Deck>()).first
        XCTAssertEqual(reopened?.autoTTS, true)
        XCTAssertEqual(reopened?.typeAnswer, true)
    }
}
