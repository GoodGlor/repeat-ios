import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #3 acceptance. The local store holds the only copy of scheduling state
/// (§8), so these assert the storage contract rather than any feature behaviour.
final class ModelTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    private func makeDeck(_ ctx: ModelContext, title: String = "Verbs") -> Deck {
        let deck = Deck(sheetTitle: title, sheetId: 1)
        ctx.insert(deck)
        return deck
    }

    // MARK: - Round-trip

    /// In-memory stores cannot prove persistence, so this one writes a real file.
    func testDeckNotesAndCardsSurviveSaveAndReload() throws {
        let url = URL.temporaryDirectory.appending(path: "roundtrip-\(UUID().uuidString).store")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let config = ModelConfiguration(schema: ModelStore.schema, url: url)

        let noteId = UUID()
        do {
            let container = try ModelContainer(for: ModelStore.schema, configurations: config)
            let ctx = ModelContext(container)
            let deck = makeDeck(ctx)
            let note = Note(
                id: noteId, deck: deck, front: "reluctant", back: "неохочий",
                example: "He was reluctant.", tags: ["verbs"], reverse: true,
                extras: ["pronunciation": "/rɪˈlʌktənt/"], extraOrder: ["pronunciation"]
            )
            ctx.insert(note)
            ctx.syncCards(for: note)
            try ctx.save()
        }

        let container = try ModelContainer(for: ModelStore.schema, configurations: config)
        let ctx = ModelContext(container)
        let decks = try ctx.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.count, 1)
        let reloaded = try XCTUnwrap(decks.first?.notes.first)
        XCTAssertEqual(reloaded.id, noteId)
        XCTAssertEqual(reloaded.front, "reluctant")
        XCTAssertEqual(reloaded.tags, ["verbs"])
        XCTAssertEqual(reloaded.extras["pronunciation"], "/rɪˈlʌktənt/")
        XCTAssertEqual(reloaded.extraOrder, ["pronunciation"])
        XCTAssertEqual(Set(reloaded.cards.map(\.direction)), [.forward, .reverse])
    }

    // MARK: - #112: the first migration this app has ever performed

    /// The claim that matters is **not** "a V2 store opens" — a fresh store
    /// always opens. It is that a store written by the shipped V1 schema, with
    /// real rows in it, opens under V2 and still has them.
    ///
    /// The phone holds the only copy of scheduling state (§8). A migration that
    /// failed here would not lose a feature; it would lose the app's data.
    func testAVersionOneStoreMigratesToVersionTwoWithoutLosingAnything() throws {
        let url = URL.temporaryDirectory.appending(path: "migrate-\(UUID().uuidString).store")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let noteId = UUID()
        // Written by V1: it does not know `StreakFreeze` exists.
        do {
            let v1 = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(
                for: v1, configurations: ModelConfiguration(schema: v1, url: url)
            )
            let ctx = ModelContext(container)
            let deck = makeDeck(ctx)
            let note = Note(id: noteId, deck: deck, front: "reluctant", back: "неохочий")
            ctx.insert(note)
            ctx.syncCards(for: note)
            let card = try XCTUnwrap(note.cards.first)
            card.state = .review
            card.stability = 12.5
            card.reps = 4
            try ctx.save()
        }

        // Opened by the app as it ships now — V2, through the migration plan.
        let container = try ModelContainer(
            for: ModelStore.schema,
            migrationPlan: RepeatMigrationPlan.self,
            configurations: ModelConfiguration(schema: ModelStore.schema, url: url)
        )
        let ctx = ModelContext(container)

        let notes = try ctx.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 1, "the migration dropped the store's notes")
        XCTAssertEqual(notes.first?.id, noteId)
        let card = try XCTUnwrap(notes.first?.cards.first)
        XCTAssertEqual(card.state, .review, "scheduling did not survive the migration")
        XCTAssertEqual(card.stability, 12.5)
        XCTAssertEqual(card.reps, 4)

        // And the entity the migration was for is usable afterwards.
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<StreakFreeze>()).isEmpty,
                      "a store that never had freezes must arrive with none")
        let day = Calendar.current.startOfDay(for: .now)
        ctx.insert(StreakFreeze(day: day, spentAt: .now))
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StreakFreeze>()).count, 1)
    }

    // MARK: - Cascade deletes

    func testDeletingNoteCascadesToItsCards() throws {
        let ctx = try makeContext()
        let note = Note(deck: makeDeck(ctx), front: "a", back: "б", reverse: true)
        ctx.insert(note)
        ctx.syncCards(for: note)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 2)

        ctx.delete(note)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 0)
    }

    func testDeletingDeckCascadesToItsNotesAndTheirCards() throws {
        let ctx = try makeContext()
        let deck = makeDeck(ctx)
        for i in 0..<3 {
            let note = Note(deck: deck, front: "front \(i)", back: "back \(i)", reverse: i == 0)
            ctx.insert(note)
            ctx.syncCards(for: note)
        }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).count, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 4)

        ctx.delete(deck)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 0)
    }

    // MARK: - Content hash

    func testEveryHashedFieldChangesTheHashAndSchedulingDoesNot() throws {
        let ctx = try makeContext()
        let note = Note(
            deck: makeDeck(ctx), front: "a", back: "б", example: "ex",
            tags: ["t"], reverse: false, extras: ["x": "1"], extraOrder: ["x"]
        )
        ctx.insert(note)
        ctx.syncCards(for: note)
        let baseline = note.contentHash

        let mutations: [(String, () -> Void)] = [
            ("front", { note.front = "changed" }),
            ("back", { note.back = "змінено" }),
            ("example", { note.example = "other" }),
            ("tags", { note.tags = ["t", "u"] }),
            ("reverse", { note.reverse = true }),
            ("extra value", { note.extras["x"] = "2" }),
            ("extra key", { note.extras = ["y": "1"]; note.extraOrder = ["y"] }),
        ]
        for (name, mutate) in mutations {
            let before = note.contentHash
            mutate()
            note.refreshContentHash()
            XCTAssertNotEqual(note.contentHash, before, "\(name) must change the content hash")
        }

        // Scheduling is not content: touching it must leave the hash alone (§4.3).
        let card = try XCTUnwrap(note.cards.first)
        let hashBeforeScheduling = note.contentHash
        card.due = .now.addingTimeInterval(86_400 * 12)
        card.stability = 42
        card.reps = 7
        note.refreshContentHash()
        XCTAssertEqual(note.contentHash, hashBeforeScheduling)

        XCTAssertNotEqual(note.contentHash, baseline)
    }

    func testHashIsOrderSensitiveForExtrasAndFieldBoundariesAreUnambiguous() {
        let a = ContentHash.of(front: "a", back: "b", example: nil, tags: [], reverse: false,
                               extras: ["x": "1", "y": "2"], extraOrder: ["x", "y"])
        let b = ContentHash.of(front: "a", back: "b", example: nil, tags: [], reverse: false,
                               extras: ["x": "1", "y": "2"], extraOrder: ["y", "x"])
        XCTAssertNotEqual(a, b, "extras are displayed in header order, so order is content (D1)")

        // Field values must not be able to impersonate a different split.
        let split1 = ContentHash.of(front: "a", back: "b", example: nil, tags: [], reverse: false,
                                    extras: [:], extraOrder: [])
        let split2 = ContentHash.of(front: "a\u{1F}b", back: "", example: nil, tags: [], reverse: false,
                                    extras: [:], extraOrder: [])
        XCTAssertNotEqual(split1, split2)
    }

    func testHashIsStableAcrossRuns() {
        // Pinned so an accidental change to the hashing scheme fails loudly instead
        // of silently marking every note in the Sheet as edited.
        let hash = ContentHash.of(front: "reluctant", back: "неохочий", example: nil,
                                  tags: ["verbs"], reverse: true, extras: [:], extraOrder: [])
        XCTAssertEqual(hash, ContentHash.of(front: "reluctant", back: "неохочий", example: nil,
                                            tags: ["verbs"], reverse: true, extras: [:], extraOrder: []))
        XCTAssertEqual(hash.count, 64)
    }

    // MARK: - Cards per note (D2)

    func testReverseFlipAddsAndRemovesTheReverseCard() throws {
        let ctx = try makeContext()
        let note = Note(deck: makeDeck(ctx), front: "a", back: "б", reverse: false)
        ctx.insert(note)
        ctx.syncCards(for: note)
        try ctx.save()
        XCTAssertEqual(note.cards.map(\.direction), [.forward])

        note.reverse = true
        ctx.syncCards(for: note)
        try ctx.save()
        XCTAssertEqual(Set(note.cards.map(\.direction)), [.forward, .reverse])

        // Flipping back removes the reverse card and leaves the forward card's
        // scheduling untouched — content edits never cost scheduling (§4.3).
        let forward = try XCTUnwrap(note.cards.first { $0.direction == .forward })
        forward.reps = 5
        note.reverse = false
        ctx.syncCards(for: note)
        try ctx.save()
        XCTAssertEqual(note.cards.map(\.direction), [.forward])
        XCTAssertEqual(note.cards.first?.reps, 5)
    }

    func testCardIdIsDerivedFromNoteAndDirection() throws {
        let ctx = try makeContext()
        let id = UUID()
        let note = Note(id: id, deck: makeDeck(ctx), front: "a", back: "б", reverse: true)
        ctx.insert(note)
        ctx.syncCards(for: note)
        XCTAssertEqual(Card.id(noteId: id, direction: .forward), "\(id.uuidString)#fwd")
        XCTAssertEqual(Set(note.cards.map(\.id)),
                       [Card.id(noteId: id, direction: .forward), Card.id(noteId: id, direction: .reverse)])
    }

    // MARK: - Snapshots and logs

    func testSnapshotRoundTripsExactly() throws {
        let ctx = try makeContext()
        let note = Note(deck: makeDeck(ctx), front: "a", back: "б")
        ctx.insert(note)
        let card = try XCTUnwrap(ctx.syncCards(for: note).first)

        card.state = .review
        card.due = Date(timeIntervalSince1970: 1_800_000_000)
        card.stability = 12.3456789
        card.difficulty = 5.4321
        card.elapsedDays = 3
        card.scheduledDays = 12
        card.reps = 9
        card.lapses = 2
        card.lastReview = Date(timeIntervalSince1970: 1_799_000_000)
        card.isSuspended = true

        let snapshot = card.snapshot
        card.state = .new
        card.due = .now
        card.stability = 0
        card.reps = 0
        card.isSuspended = false

        card.restore(from: snapshot)
        XCTAssertEqual(card.snapshot, snapshot)
    }

    func testReviewLogCarriesADecodablePreviousState() throws {
        let ctx = try makeContext()
        let note = Note(deck: makeDeck(ctx), front: "a", back: "б")
        ctx.insert(note)
        let card = try XCTUnwrap(ctx.syncCards(for: note).first)
        card.stability = 7.5

        let log = try ReviewLog(
            cardId: card.id, direction: card.direction, rating: 3,
            elapsedDays: 1, scheduledDays: 4, stateBefore: card.state, prevState: card.snapshot
        )
        ctx.insert(log)
        try ctx.save()

        let stored = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ReviewLog>()).first)
        XCTAssertEqual(try stored.decodedPrevState().stability, 7.5)
        XCTAssertFalse(stored.uploaded)
    }

    // MARK: - Display

    func testDisplayExtrasSkipEmptiesAndKeepHeaderOrder() throws {
        let ctx = try makeContext()
        let note = Note(
            deck: makeDeck(ctx), front: "a", back: "б",
            extras: ["pronunciation": "/x/", "synonyms": "", "note": "n"],
            extraOrder: ["synonyms", "pronunciation", "note"]
        )
        ctx.insert(note)
        XCTAssertEqual(note.displayExtras.map(\.key), ["pronunciation", "note"])
        XCTAssertEqual(note.displayExtras.map(\.value), ["/x/", "n"])
    }

    func testSoftDeleteUsesATimestampNotPersistentModelIsDeleted() throws {
        let ctx = try makeContext()
        let note = Note(deck: makeDeck(ctx), front: "a", back: "б")
        ctx.insert(note)
        XCTAssertNil(note.deletedAt)
        note.deletedAt = .now
        try ctx.save()
        // Still a live row — soft delete must not remove it from the store.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).count, 1)
    }

    // MARK: - #106: the note behind a card id, without faulting the note

    func testTheNoteIdCanBeReadBackOffACardId() {
        let noteId = UUID()
        XCTAssertEqual(Card.noteId(inCardId: Card.id(noteId: noteId, direction: .forward)), noteId)
        XCTAssertEqual(Card.noteId(inCardId: Card.id(noteId: noteId, direction: .reverse)), noteId)
        XCTAssertNil(Card.noteId(inCardId: "history-3-1"), "a synthetic log id names no note")
        XCTAssertNil(Card.noteId(inCardId: ""))
    }
}

/// Regression: SwiftData's default `groupContainer: .automatic` relocates the
/// store into the App Group as soon as the entitlement exists, then fails to open
/// it because `Library/Application Support` does not exist there. The app's very
/// first launch would hit the `fatalError` in `RepeatApp.init`.
final class StoreLocationTests: XCTestCase {
    func testStoreDirectoryExistsBeforeTheContainerIsOpened() throws {
        let url = try ModelStore.storeURL()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path,
                                           isDirectory: &isDirectory),
            "the store's directory must be created before SwiftData tries to write there"
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(url.lastPathComponent, ModelStore.storeFileName)
    }

    func testAnOnDiskContainerOpensAndSaves() throws {
        let container = try ModelStore.container()
        let ctx = ModelContext(container)
        let deck = Deck(sheetTitle: "Store probe \(UUID().uuidString)", sheetId: 99)
        ctx.insert(deck)
        XCTAssertNoThrow(try ctx.save())
        ctx.delete(deck)
        try ctx.save()
    }
}
