import XCTest
import SwiftData
@testable import Repeat

/// #23 — the App Group handover and exactly-once consumption.
final class InboxTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory!)
        }
    }

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    private func items(_ context: ModelContext) throws -> [InboxItem] {
        try context.fetch(FetchDescriptor<InboxItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
    }

    private var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
    }

    // MARK: - Acceptance: a shared item appears in the inbox on next launch

    func testADroppedCaptureBecomesAnInboxItemAndTheFileIsCleanedUp() throws {
        let (context, _) = try makeStore()
        try InboxDrop(text: "  serendipity  ", createdAt: now,
                      sourceURL: "https://en.wiktionary.org/wiki/serendipity")
            .write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome, .init(ingested: 1))
        let item = try XCTUnwrap(try items(context).first)
        XCTAssertEqual(item.text, "serendipity")
        XCTAssertEqual(item.createdAt, now)
        XCTAssertEqual(item.sourceURL, "https://en.wiktionary.org/wiki/serendipity")
        XCTAssertTrue(files.isEmpty, "the drop is consumed, not left to be re-read")
    }

    func testCapturesArriveInTheOrderTheyWereMade() throws {
        let (context, _) = try makeStore()
        // Written in the reverse of capture order, to prove the sort is real.
        try InboxDrop(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!,
                      text: "second", createdAt: now.addingTimeInterval(60)).write(to: directory)
        try InboxDrop(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                      text: "first", createdAt: now).write(to: directory)

        try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(try items(context).map(\.text), ["first", "second"])
    }

    /// A crash between the insert and the delete leaves the file behind. The next
    /// run must not create a second item from it.
    func testAReingestedDropIsRecognisedRatherThanDuplicated() throws {
        let (context, _) = try makeStore()
        let drop = InboxDrop(text: "serendipity", createdAt: now)
        try drop.write(to: directory)
        try InboxIngest.run(in: context, directory: directory)

        try drop.write(to: directory)
        let second = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(second, .init(ingested: 0, duplicates: 1))
        XCTAssertEqual(try items(context).count, 1)
        XCTAssertTrue(files.isEmpty)
    }

    func testACorruptDropIsDiscardedRatherThanRetriedForever() throws {
        let (context, _) = try makeStore()
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        try InboxDrop(text: "", createdAt: now).write(to: directory)

        let outcome = try InboxIngest.run(in: context, directory: directory)

        XCTAssertEqual(outcome, .init(ingested: 0, duplicates: 1, unreadable: 1))
        XCTAssertTrue(try items(context).isEmpty)
        XCTAssertTrue(files.isEmpty, "neither file may be re-read on every launch forever")
    }

    func testAMissingContainerIsNotAnError() throws {
        let (context, _) = try makeStore()
        let outcome = try InboxIngest.run(
            in: context, directory: directory.appendingPathComponent("nope", isDirectory: true))
        XCTAssertEqual(outcome, .init())
    }

    // MARK: - Acceptance: consuming an item removes it exactly once

    func testSavingACardFromACaptureConsumesItExactlyOnce() throws {
        let (context, deck) = try makeStore()
        try InboxDrop(text: "serendipity", createdAt: now,
                      sourceURL: "https://example.com/x").write(to: directory)
        try InboxIngest.run(in: context, directory: directory)
        let item = try XCTUnwrap(try items(context).first)

        var draft = AddCardComposer.Draft.from(item)
        XCTAssertEqual(draft.front, "serendipity")
        XCTAssertEqual(draft.sourceURL, "https://example.com/x")
        draft.back = "щаслива випадковість"

        let note = try AddCardComposer.save(draft, to: deck, in: context, now: now)

        XCTAssertEqual(note.front, "serendipity")
        XCTAssertTrue(try items(context).isEmpty, "the capture is consumed by the card it became")
        // D1: the phone never invents a column, so the source URL does not become
        // one. It was context for writing the card, not part of it.
        XCTAssertTrue(note.extras.isEmpty)
        XCTAssertNil(note.example)
    }

    /// "Save and add another" must not consume the same capture for every card
    /// that follows it.
    func testTheCaptureIsNotConsumedAgainByTheNextCard() throws {
        let (context, deck) = try makeStore()
        try InboxDrop(text: "one", createdAt: now).write(to: directory)
        try InboxDrop(text: "two", createdAt: now.addingTimeInterval(60)).write(to: directory)
        try InboxIngest.run(in: context, directory: directory)
        XCTAssertEqual(try items(context).count, 2)

        let first = try XCTUnwrap(try items(context).first { $0.text == "one" })
        var draft = AddCardComposer.Draft.from(first)
        draft.back = "один"
        try AddCardComposer.save(draft, to: deck, in: context, now: now)

        // The next card is typed straight into the cleared form.
        var next = draft.cleared()
        XCTAssertNil(next.sourceItemID, "the link belonged to the card just saved")
        next.front = "unrelated"
        next.back = "не повʼязане"
        try AddCardComposer.save(next, to: deck, in: context, now: now)

        XCTAssertEqual(try items(context).map(\.text), ["two"],
                       "only the capture that became a card was consumed")
    }

    func testConsumingAnAlreadyGoneCaptureIsNotAnError() throws {
        let (context, deck) = try makeStore()
        var draft = AddCardComposer.Draft(front: "a", back: "б")
        draft.sourceItemID = UUID()

        XCTAssertNoThrow(try AddCardComposer.save(draft, to: deck, in: context, now: now))
    }

    // MARK: - The drop format

    func testTheDropSurvivesARoundTripAcrossProcesses() throws {
        let drop = InboxDrop(text: "serendipity", createdAt: now, sourceURL: "https://example.com")
        let data = try InboxDrop.encoder().encode(drop)
        XCTAssertEqual(try InboxDrop.decoder().decode(InboxDrop.self, from: data), drop)

        // ISO 8601, not a floating-point interval: the two sides are separate
        // processes and the field has to be readable by eye when one misbehaves.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("2027-01-15T"), "unexpected encoding: \(json)")
    }

    func testTheFileNameIdentifiesTheCapture() {
        let drop = InboxDrop(text: "x")
        XCTAssertEqual(drop.fileName, "\(drop.id.uuidString).json")
    }
}
