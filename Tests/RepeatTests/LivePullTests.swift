import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// The whole read path against a real spreadsheet: token exchange, discovery,
/// header parsing, pull, and the resulting SwiftData objects.
///
/// Everything else in this suite drives a scripted transport. That proves the
/// logic but not that Google accepts what we send — and it did not, until a live
/// run rejected an append range the stub had happily accepted.
///
/// Skipped unless the environment supplies a key and a sheet id. `xcodebuild`
/// forwards variables prefixed `TEST_RUNNER_`:
///
///     scripts/live-check.sh --with-app
final class LivePullTests: XCTestCase {

    private func liveClient() throws -> SheetsClient? {
        let environment = ProcessInfo.processInfo.environment
        guard let spreadsheetId = environment["REPEAT_LIVE_SHEET_ID"], !spreadsheetId.isEmpty
        else { return nil }

        // The key arrives as *contents*, not a path: this runs inside the
        // simulator's sandbox, which cannot read the host's Downloads folder.
        let json: String
        if let inline = environment["REPEAT_LIVE_KEY_JSON"], !inline.isEmpty {
            json = inline
        } else if let keyPath = environment["REPEAT_LIVE_KEY_PATH"], !keyPath.isEmpty,
                  let contents = try? String(contentsOfFile: keyPath, encoding: .utf8) {
            json = contents
        } else {
            return nil
        }
        let account = try ServiceAccount.parse(json: json)
        return SheetsClient(
            spreadsheetId: spreadsheetId,
            tokens: GoogleTokenProvider(account: account),
            policy: RetryPolicy(maximumAttempts: 1)
        )
    }

    func testARealSpreadsheetPullsIntoDecksNotesAndCards() async throws {
        guard let client = try liveClient() else {
            throw XCTSkip("set REPEAT_LIVE_KEY_JSON and REPEAT_LIVE_SHEET_ID to run the live pull")
        }
        let ctx = ModelContext(try ModelStore.container(inMemory: true))

        let discovery = try await SheetDiscovery(client: client).run(in: ctx)
        XCTAssertFalse(discovery.readable.isEmpty, "no readable deck: \(discovery.malformed)")

        let result = try await SheetPull(client: client).run(discovery: discovery, in: ctx)

        let decks = try ctx.fetch(FetchDescriptor<Deck>())
        let notes = try ctx.fetch(FetchDescriptor<Note>())
        let cards = try ctx.fetch(FetchDescriptor<Card>())
        print("[live] decks \(decks.count), notes \(notes.count), cards \(cards.count), \(result)")
        print("[live] fronts: \(notes.map(\.front).sorted())")

        XCTAssertFalse(notes.isEmpty, "the spreadsheet has no card rows")
        XCTAssertFalse(cards.isEmpty)
        // A reverse row yields two cards, so cards ≥ notes always.
        XCTAssertGreaterThanOrEqual(cards.count, notes.count)
        for note in notes {
            XCTAssertFalse(note.front.isEmpty)
            XCTAssertFalse(note.back.isEmpty)
            XCTAssertNil(note.deletedAt)
        }

        // A second pull must be a no-op: nothing changed on either side.
        let again = try await SheetPull(client: client).run(discovery: discovery, in: ctx)
        XCTAssertEqual(again.created, 0)
        XCTAssertEqual(again.contentUpdated, 0)
        XCTAssertEqual(again.idsWrittenBack, 0, "ids written on the first pull stay written")
    }

    /// The queue is what the study screen consumes, so this is the real proof the
    /// chain ends somewhere useful.
    func testCardsFromTheRealSheetBuildAStudyQueue() async throws {
        guard let client = try liveClient() else {
            throw XCTSkip("set REPEAT_LIVE_KEY_JSON and REPEAT_LIVE_SHEET_ID to run the live pull")
        }
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let discovery = try await SheetDiscovery(client: client).run(in: ctx)
        _ = try await SheetPull(client: client).run(discovery: discovery, in: ctx)

        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(
            decks: try ctx.fetch(FetchDescriptor<Deck>()), using: &generator)

        print("[live] queue: \(plan.count) cards, ~\(plan.estimatedMinutes) min")
        XCTAssertFalse(plan.isEmpty, "cards arrived but none are studiable")
        XCTAssertEqual(plan.dueReviewCount, 0, "everything is new on a first sync")
    }
}
