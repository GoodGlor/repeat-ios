import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// #22 — the form's logic, and the promise that what it saves reaches the Sheet.
final class AddCardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "add-card-\(UUID().uuidString)")!
        addTeardownBlock { suite.removePersistentDomain(forName: suite.description) }
        return suite
    }

    // MARK: - The draft

    func testWhitespaceOnlyFieldsAreEmptyFields() {
        var draft = AddCardComposer.Draft(front: "  \n ", back: "неохочий")
        XCTAssertFalse(draft.isSavable)

        draft.front = " reluctant "
        XCTAssertTrue(draft.isSavable)
        XCTAssertEqual(draft.trimmedFront, "reluctant")

        draft.back = "\t"
        XCTAssertFalse(draft.isSavable, "a back of whitespace is not an answer")
    }

    /// §6.4's "Save and add another" is for entering a run of cards of the same
    /// kind, so the two settings that describe the *kind* survive the clear.
    func testClearingKeepsTheReverseToggle() {
        let draft = AddCardComposer.Draft(front: "a", back: "б", example: "e", reverse: true)
        let next = draft.cleared()

        XCTAssertEqual(next.front, "")
        XCTAssertEqual(next.back, "")
        XCTAssertEqual(next.example, "")
        XCTAssertTrue(next.reverse)
    }

    // MARK: - Saving

    func testASavedCardIsQueuedForPushAndNeverAgreedWithTheSheet() throws {
        let (context, deck) = try makeStore()
        let note = try AddCardComposer.save(
            .init(front: " reluctant ", back: " неохочий ", example: "  "),
            to: deck, in: context, now: now)

        XCTAssertEqual(note.front, "reluctant")
        XCTAssertEqual(note.back, "неохочий")
        XCTAssertNil(note.example, "an empty example is no example, not an empty string")
        XCTAssertTrue(note.pendingUpload)
        XCTAssertEqual(note.sheetRow, 0, "row 0 means the Sheet has never seen it")
        XCTAssertNil(note.lastSyncedHash,
                     "the two sides have never agreed — the Sheet has never seen this note")
        XCTAssertEqual(note.contentHash.isEmpty, false)
        XCTAssertEqual(note.cards.count, 1)
        XCTAssertEqual(note.cards.first?.direction, .forward)
    }

    func testAReverseCardYieldsBothDirections() throws {
        let (context, deck) = try makeStore()
        let note = try AddCardComposer.save(
            .init(front: "call off", back: "скасувати", reverse: true),
            to: deck, in: context, now: now)

        XCTAssertEqual(Set(note.cards.map(\.direction)), [.forward, .reverse])
    }

    // MARK: - The remembered deck

    func testTheLastUsedDeckIsPreselected() throws {
        let (context, verbs) = try makeStore()
        let nouns = Deck(sheetTitle: "Nouns", sheetId: 1, sortOrder: 1)
        context.insert(nouns)
        try context.save()
        let store = defaults()
        let decks = try context.fetch(FetchDescriptor<Deck>())

        // Nothing remembered yet: the first deck in display order.
        XCTAssertEqual(AddCardComposer.LastDeck.resolve(among: decks, defaults: store)?.sheetTitle,
                       verbs.sheetTitle)

        AddCardComposer.LastDeck.remember(nouns, defaults: store)
        XCTAssertEqual(AddCardComposer.LastDeck.resolve(among: decks, defaults: store)?.sheetTitle,
                       "Nouns")
    }

    func testARememberedDeckThatHasGoneFallsBackRatherThanResurrecting() throws {
        let (context, _) = try makeStore()
        let store = defaults()
        let gone = Deck(sheetTitle: "Deleted", sheetId: 9, sortOrder: 5)
        context.insert(gone)
        try context.save()

        AddCardComposer.LastDeck.remember(gone, defaults: store)
        gone.deletedAt = now
        try context.save()

        let resolved = AddCardComposer.LastDeck.resolve(
            among: try context.fetch(FetchDescriptor<Deck>()), defaults: store)
        XCTAssertEqual(resolved?.sheetTitle, "Verbs")
    }

    func testAMalformedDeckIsNotOfferedAsATarget() throws {
        let (context, verbs) = try makeStore()
        verbs.malformedReason = "немає колонки back"
        try context.save()

        XCTAssertNil(
            AddCardComposer.LastDeck.resolve(among: try context.fetch(FetchDescriptor<Deck>()),
                                             defaults: defaults()),
            "writing into a deck whose columns cannot be read would scatter values"
        )
    }

    // MARK: - Acceptance: a card added offline reaches the Sheet after reconnect

    func testACardAddedOfflineAppearsInTheSheetAfterReconnect() async throws {
        let stub = SheetStub(rows: ["Verbs": [SheetSyncHarness.header]])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()

        let client = try SheetSyncHarness.makeClient(stub)
        let when = now
        let actor = SyncActor(container: container, makeClient: { client }, now: { when })

        // Typed on a train.
        stub.failure = SheetsError.transport("offline")
        try AddCardComposer.save(
            .init(front: "reluctant", back: "неохочий", example: "He was reluctant."),
            to: deck, in: context, now: when)
        let offline = await actor.sync(.contentEdited)
        guard case .failed = offline.verdict else {
            return XCTFail("expected the push to fail while offline")
        }
        XCTAssertTrue(stub.appends.isEmpty)

        // Back on wifi.
        stub.failure = nil
        let drained = await actor.sync(.reconnected)

        XCTAssertEqual(drained.push.appended, 1)
        let appended = try XCTUnwrap(stub.appends.first?.values.first)
        XCTAssertTrue(appended.contains("reluctant"), "row was \(appended)")
        XCTAssertTrue(appended.contains("неохочий"))
        XCTAssertTrue(appended.contains("He was reluctant."))

        let saved = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertTrue(saved.allSatisfy { !$0.pendingUpload }, "the queue drained")
    }

    /// The trigger a saved card fires is the debounced push-only one — a card
    /// edit must not drag down the whole sheet (§4.2 trigger 3).
    func testSavingUsesTheDebouncedPushOnlyTrigger() {
        XCTAssertEqual(SyncTrigger.contentEdited.debounceInterval, 3)
        XCTAssertEqual(SyncTrigger.contentEdited.work, .notesOnly)
    }
}
