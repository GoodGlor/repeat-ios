import XCTest
import SwiftData
import UniformTypeIdentifiers
@testable import Repeat

/// #28 — the App Group handover from the extension's side.
final class ShareExtensionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    private func makeStore(deck title: String = "Verbs") throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: title, sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    // MARK: - Acceptance: a Safari selection produces an item with its source

    func testASelectionWithItsPageProducesAnInboxItemCarryingTheSource() throws {
        let (context, _) = try makeStore()
        try InboxDrop(
            text: "serendipity", createdAt: now,
            sourceURL: "https://en.wiktionary.org/wiki/serendipity"
        ).write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome.ingested, 1)
        let item = try XCTUnwrap(try context.fetch(FetchDescriptor<InboxItem>()).first)
        XCTAssertEqual(item.text, "serendipity")
        XCTAssertEqual(item.sourceURL, "https://en.wiktionary.org/wiki/serendipity")
    }

    /// Regression: the scaffold extension wrote `{text, createdAt}` with **no
    /// `id`**, which `InboxDrop` cannot decode — every capture would have been
    /// silently discarded as unreadable.
    func testTheScaffoldsIdLessPayloadWouldNotHaveDecoded() throws {
        let (context, _) = try makeStore()
        let legacy = ["text": "serendipity", "createdAt": "2027-01-15T08:00:00Z"]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome.unreadable, 1)
        XCTAssertEqual(outcome.ingested, 0)
    }

    // MARK: - Save as card

    /// The extension cannot write to SwiftData, so it describes the card and the
    /// app creates it — reaching the Sheet by the ordinary push path.
    func testACardShapedDropBecomesARealCardQueuedForPush() throws {
        let (context, _) = try makeStore()
        try InboxDrop(
            text: "serendipity", createdAt: now,
            sourceURL: "https://example.com", deckTitle: "Verbs", back: "щаслива випадковість"
        ).write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome.cardsCreated, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxItem>()).isEmpty,
                      "a finished card is not also a note to self")

        let note = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(note.front, "serendipity")
        XCTAssertEqual(note.back, "щаслива випадковість")
        XCTAssertTrue(note.pendingUpload)
        XCTAssertEqual(note.cards.count, 1)
    }

    /// A deck renamed or deleted between the share and the launch. The words are
    /// still worth having, so the drop is demoted rather than discarded.
    func testACardForAMissingDeckIsKeptAsAnInboxItem() throws {
        let (context, _) = try makeStore(deck: "Nouns")
        try InboxDrop(text: "serendipity", createdAt: now,
                      deckTitle: "Verbs", back: "щаслива випадковість").write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome.cardsCreated, 0)
        XCTAssertEqual(outcome.cardsDemoted, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxItem>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    func testADropWithABlankAnswerIsNotACard() throws {
        let (context, _) = try makeStore()
        try InboxDrop(text: "serendipity", createdAt: now,
                      deckTitle: "Verbs", back: "   ").write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome.cardsCreated, 0)
        XCTAssertEqual(outcome.cardsDemoted, 0, "whitespace is not a half-finished card")
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxItem>()).count, 1)
    }

    // MARK: - Compatibility

    /// A drop written by a build that predates the card fields still decodes.
    func testAnOlderDropWithoutTheCardFieldsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","text":"serendipity","createdAt":"2027-01-15T08:00:00Z"}
        """
        let drop = try InboxDrop.decoder().decode(InboxDrop.self, from: Data(json.utf8))

        XCTAssertNil(drop.deckTitle)
        XCTAssertNil(drop.back)
        XCTAssertFalse(drop.isCard)
    }

    func testTheCardFieldsSurviveARoundTrip() throws {
        let drop = InboxDrop(text: "a", createdAt: now, sourceURL: "https://example.com",
                             deckTitle: "Verbs", back: "б")
        let data = try InboxDrop.encoder().encode(drop)
        XCTAssertEqual(try InboxDrop.decoder().decode(InboxDrop.self, from: data), drop)
        XCTAssertTrue(drop.isCard)
    }

    // MARK: - The deck list the picker reads

    func testThePublishedDeckListSkipsDecksThatCannotBeWrittenTo() throws {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        context.insert(Deck(sheetTitle: "Verbs", sheetId: 0, sortOrder: 0))
        let broken = Deck(sheetTitle: "Broken", sheetId: 1, sortOrder: 1)
        broken.malformedReason = "немає колонки back"
        context.insert(broken)
        let gone = Deck(sheetTitle: "Gone", sheetId: 2, sortOrder: 2)
        gone.deletedAt = now
        context.insert(gone)
        try context.save()

        DueCountPublisher.publishDecks(from: context)

        try XCTSkipIf(SharedDecks.fileURL == nil, "App Group entitlement unavailable")
        let published = try XCTUnwrap(SharedDecks.read())
        XCTAssertEqual(published.decks.map(\.title), ["Verbs"],
                       "a deck whose columns cannot be read is not a place to put a card")
    }

    func testTheDeckListSurvivesARoundTrip() throws {
        let url = directory.appendingPathComponent("decks.json")
        let decks = SharedDecks(
            decks: [.init(title: "Verbs", colorHex: "#1F7A5C")], updatedAt: now)
        try decks.write(to: url)
        XCTAssertEqual(SharedDecks.read(from: url), decks)
    }

    func testAMissingDeckListReadsAsNothingRatherThanFailing() {
        XCTAssertNil(SharedDecks.read(from: directory.appendingPathComponent("absent.json")))
    }

    // MARK: - Reading what Safari hands over

    /// A Safari selection arrives as **two** attachments: the words and the page.
    /// The scaffold read only the first, which meant one or the other was always
    /// lost — and §7.3's acceptance needs both.
    func testASafariSelectionYieldsBothTheTextAndItsSource() async throws {
        let text = NSItemProvider(item: "serendipity" as NSString,
                                  typeIdentifier: UTType.plainText.identifier)
        let page = NSItemProvider(item: URL(string: "https://en.wiktionary.org/wiki/serendipity")! as NSURL,
                                  typeIdentifier: UTType.url.identifier)

        let capture = await SharedCapture.read(from: [text, page])

        XCTAssertEqual(capture.text, "serendipity")
        XCTAssertEqual(capture.sourceURL, "https://en.wiktionary.org/wiki/serendipity")
    }

    /// Attachment order is not guaranteed.
    func testTheOrderOfTheAttachmentsDoesNotMatter() async throws {
        let text = NSItemProvider(item: "serendipity" as NSString,
                                  typeIdentifier: UTType.plainText.identifier)
        let page = NSItemProvider(item: URL(string: "https://example.com/x")! as NSURL,
                                  typeIdentifier: UTType.url.identifier)

        let capture = await SharedCapture.read(from: [page, text])

        XCTAssertEqual(capture.text, "serendipity")
        XCTAssertEqual(capture.sourceURL, "https://example.com/x")
    }

    /// Sharing a bare link: the URL is the only thing there is to remember, so it
    /// becomes the text as well as the source.
    func testABareLinkBecomesItsOwnText() async throws {
        let page = NSItemProvider(item: URL(string: "https://example.com/word")! as NSURL,
                                  typeIdentifier: UTType.url.identifier)

        let capture = await SharedCapture.read(from: [page])

        XCTAssertEqual(capture.text, "https://example.com/word")
        XCTAssertEqual(capture.sourceURL, "https://example.com/word")
    }

    func testPlainTextWithNoPageHasNoSource() async throws {
        let text = NSItemProvider(item: "щаслива випадковість" as NSString,
                                  typeIdentifier: UTType.plainText.identifier)

        let capture = await SharedCapture.read(from: [text])

        XCTAssertEqual(capture.text, "щаслива випадковість")
        XCTAssertNil(capture.sourceURL)
    }

    /// A shared document is not a web page, and nobody's "source".
    func testAFileURLIsNotTreatedAsASource() async throws {
        let file = NSItemProvider(item: URL(fileURLWithPath: "/tmp/notes.txt") as NSURL,
                                  typeIdentifier: UTType.url.identifier)
        let text = NSItemProvider(item: "note" as NSString,
                                  typeIdentifier: UTType.plainText.identifier)

        let capture = await SharedCapture.read(from: [file, text])

        XCTAssertEqual(capture.text, "note")
        XCTAssertNil(capture.sourceURL)
    }

    func testNothingSharedIsNotACrash() async throws {
        let capture = await SharedCapture.read(from: [])
        XCTAssertEqual(capture, SharedCapture())
    }
}
