import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// Card #16 acceptance (§4.4).
final class SheetPushTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let header = SheetSyncHarness.header

    private func makeContext(rows: [[String]] = []) throws -> (ModelContext, Deck, SheetStub, SheetPush) {
        let stub = SheetStub(rows: ["Verbs": [header] + rows])
        let (ctx, deck) = try SheetSyncHarness.makeContext()
        return (ctx, deck, stub, SheetPush(client: try SheetSyncHarness.makeClient(stub)))
    }

    @discardableResult
    private func addLocalNote(
        _ ctx: ModelContext, to deck: Deck, id: UUID = UUID(),
        front: String = "thorough", back: String = "ретельний",
        example: String? = "A thorough review.", tags: [String] = ["verbs"],
        reverse: Bool = false, sheetRow: Int = 0
    ) throws -> Note {
        let note = Note(id: id, deck: deck, front: front, back: back, example: example,
                        tags: tags, reverse: reverse, sheetRow: sheetRow, pendingUpload: true)
        ctx.insert(note)
        ctx.syncCards(for: note, now: now)
        try ctx.save()
        return note
    }

    private func appendedRows(_ stub: SheetStub) -> [[String]] {
        stub.appends.flatMap(\.values)
    }

    // MARK: - New notes

    func testANoteAddedInTheAppAppearsInTheDeckTabWithEveryColumn() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck, reverse: true)

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.appended, 1)
        let row = try XCTUnwrap(appendedRows(stub).first)
        XCTAssertEqual(row.count, header.count)
        XCTAssertEqual(row[header.firstIndex(of: "id")!], note.id.uuidString)
        XCTAssertEqual(row[header.firstIndex(of: "front")!], "thorough")
        XCTAssertEqual(row[header.firstIndex(of: "back")!], "ретельний")
        XCTAssertEqual(row[header.firstIndex(of: "example")!], "A thorough review.")
        XCTAssertEqual(row[header.firstIndex(of: "tags")!], "verbs")
        XCTAssertEqual(row[header.firstIndex(of: "reverse")!], "TRUE")
        XCTAssertEqual(row[header.firstIndex(of: "deleted")!], "FALSE")
    }

    func testExtraColumnsAreWrittenAtTheirOwnPositions() async throws {
        let stub = SheetStub(rows: ["Verbs": [header + ["вимова"]]])
        let (ctx, deck) = try SheetSyncHarness.makeContext()
        let push = SheetPush(client: try SheetSyncHarness.makeClient(stub))

        let note = Note(deck: deck, front: "reluctant", back: "неохочий",
                        extras: ["вимова": "/rɪˈlʌktənt/"], extraOrder: ["вимова"],
                        pendingUpload: true)
        ctx.insert(note)
        ctx.syncCards(for: note, now: now)
        try ctx.save()

        _ = try await push.run(
            discovery: try SheetSyncHarness.discovery(extraColumns: ["вимова"]), in: ctx, now: now)

        let row = try XCTUnwrap(appendedRows(stub).first)
        XCTAssertEqual(row.count, header.count + 1)
        XCTAssertEqual(row.last, "/rɪˈlʌktənt/", "D1 extras go back where they came from")
    }

    func testEveryNewNoteInADeckGoesInOneAppendCall() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        for index in 0..<5 { try addLocalNote(ctx, to: deck, front: "f\(index)") }

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.appended, 5)
        XCTAssertEqual(stub.appends.count, 1, "one call per deck per sync (§4.4)")
        XCTAssertEqual(appendedRows(stub).count, 5)
    }

    func testUpdatedAtIsWrittenAsISO8601UTC() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        try addLocalNote(ctx, to: deck)
        var withTimestamp = try SheetSyncHarness.discovery()
        withTimestamp.readable["Verbs"] = try HeaderMap(headerRow: header + ["updated_at"])
        _ = try await push.run(discovery: withTimestamp, in: ctx, now: now)

        let row = try XCTUnwrap(appendedRows(stub).first)
        XCTAssertEqual(row.last, "2027-01-15T08:00:00Z")
        XCTAssertTrue(row.last?.hasSuffix("Z") ?? false, "UTC, so the column survives a phone that travels")
    }

    // MARK: - Edited notes

    /// The acceptance line: the row has to be found by id, because the owner
    /// sorts and inserts rows in Sheets and a cached index would overwrite a
    /// different card.
    func testAnEditFindsTheRightRowAfterRowsWereReorderedInSheets() async throws {
        let target = UUID()
        let other = UUID()
        // The note was at row 2; the owner has since sorted it to row 4.
        let (ctx, deck, stub, push) = try makeContext(rows: [
            SheetSyncHarness.row(other, front: "a", back: "б"),
            SheetSyncHarness.row(UUID(), front: "c", back: "ц"),
            SheetSyncHarness.row(target, front: "old", back: "старий"),
        ])
        let note = try addLocalNote(ctx, to: deck, id: target, front: "new", back: "новий", sheetRow: 2)

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.appended, 0, "an existing row is updated, not duplicated")
        XCTAssertEqual(stub.writtenCells.keys.first, "Verbs!A4:G4", "row 4, not the cached row 2")
        XCTAssertEqual(note.sheetRow, 4, "the cache is corrected")
    }

    func testAnEditWritesUserEnteredNotRaw() async throws {
        let id = UUID()
        let (ctx, deck, stub, push) = try makeContext(rows: [
            SheetSyncHarness.row(id, front: "old", back: "старий"),
        ])
        try addLocalNote(ctx, to: deck, id: id, front: "new")
        _ = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(stub.inputOptions, ["USER_ENTERED"])
    }

    func testANoteWhoseRowIsGoneIsAppendedRatherThanLost() async throws {
        let id = UUID()
        let (ctx, deck, stub, push) = try makeContext()
        try addLocalNote(ctx, to: deck, id: id, sheetRow: 7)

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result.appended, 1)
        XCTAssertEqual(appendedRows(stub).first?.first, id.uuidString)
    }

    // MARK: - Deletion

    /// §4.4: the phone never removes a row. A mistaken tap in the app must not
    /// destroy a row in the owner's own spreadsheet.
    func testADeletedNoteMarksTheRowRatherThanRemovingIt() async throws {
        let id = UUID()
        let (ctx, deck, stub, push) = try makeContext(rows: [
            SheetSyncHarness.row(id, front: "a", back: "б"),
        ])
        let note = try addLocalNote(ctx, to: deck, id: id, front: "a", back: "б")
        note.deletedAt = now
        try ctx.save()

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.markedDeleted, 1)
        let written = try XCTUnwrap(stub.updates.first?["data"] as? [[String: Any]])
        let values = try XCTUnwrap((written.first?["values"] as? [[String]])?.first)
        XCTAssertEqual(values[header.firstIndex(of: "deleted")!], "TRUE")
        XCTAssertEqual(values[header.firstIndex(of: "front")!], "a", "the row keeps its content")
    }

    func testDeletingANoteTheSheetNeverSawWritesNothing() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck)
        note.deletedAt = now
        try ctx.save()

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result.appended, 0)
        XCTAssertEqual(result.markedDeleted, 0)
        XCTAssertTrue(stub.appends.isEmpty)
        XCTAssertFalse(note.pendingUpload, "and it stops being queued")
    }

    // MARK: - Flags

    func testPendingUploadClearsOnlyAfterTheWriteSucceeds() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck)

        _ = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertFalse(note.pendingUpload)
        XCTAssertEqual(note.lastSyncedHash, note.contentHash, "both sides now agree")
        XCTAssertEqual(note.updatedAt, now, "stamped only once the write is confirmed")
        XCTAssertEqual(stub.appends.count, 1)
    }

    /// The acceptance line: a failed push must leave the work queued so the next
    /// trigger retries, rather than silently dropping an edit.
    func testAFailedPushLeavesTheNoteQueuedForTheNextSync() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck)
        let hashBefore = note.contentHash
        let updatedAtBefore = note.updatedAt
        stub.failure = URLError(.notConnectedToInternet)

        do {
            _ = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
            XCTFail("expected the push to fail")
        } catch {
            // Expected.
        }

        XCTAssertTrue(note.pendingUpload, "still queued")
        XCTAssertEqual(note.contentHash, hashBefore, "the local edit is intact")
        XCTAssertEqual(note.updatedAt, updatedAtBefore,
                       "updatedAt marks a confirmed write, so a failed one must not set it")

        // And it goes through on the next attempt.
        stub.failure = nil
        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result.appended, 1)
        XCTAssertFalse(note.pendingUpload)
    }

    /// Without a header there is no way to know which column is which; writing
    /// blind would scatter values across the wrong columns.
    func testNotesInAnUnreadableDeckAreLeftQueuedRatherThanWrittenBlind() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck)

        let result = try await push.run(discovery: DiscoveryResult(), in: ctx, now: now)

        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(stub.appends.isEmpty)
        XCTAssertTrue(stub.updates.isEmpty)
        XCTAssertTrue(note.pendingUpload)
    }

    func testNothingPendingMeansNoRequestsAtAll() async throws {
        let (ctx, deck, stub, push) = try makeContext()
        let note = try addLocalNote(ctx, to: deck)
        note.pendingUpload = false
        try ctx.save()

        let result = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result, PushResult())
        XCTAssertTrue(stub.appends.isEmpty)
        XCTAssertTrue(stub.updates.isEmpty)
    }

    // MARK: - The invariant still holds

    func testPushingNeverTouchesSchedulingOrWritesALogRow() async throws {
        let id = UUID()
        let (ctx, deck, _, push) = try makeContext(rows: [
            SheetSyncHarness.row(id, front: "a", back: "б"),
        ])
        let note = try addLocalNote(ctx, to: deck, id: id)
        let card = try XCTUnwrap(note.cards.first)
        card.state = .review
        card.stability = 14.25
        card.reps = 6
        card.due = now.addingTimeInterval(14 * 86_400)
        try ctx.save()
        let before = card.snapshot

        _ = try await push.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(card.snapshot, before)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 0)
    }
}
