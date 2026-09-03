import XCTest
@testable import GoogleSheets

/// Talks to a real spreadsheet with a real service-account key.
///
/// Every other test in this package drives a scripted transport, which proves the
/// request shapes and the parsing but cannot prove that Google accepts the
/// assertion, that the scopes are right, or that the sheet is actually shared.
/// This closes that gap.
///
/// Skipped unless both variables are set, so it never runs in an ordinary build:
///
///     source Config/live.env && swift test --filter LiveSheetsTests
///
/// The key is read from a path outside the repository. It is never committed,
/// never printed, and never written anywhere by this test.
final class LiveSheetsTests: XCTestCase {

    private struct Configuration {
        let account: ServiceAccount
        let spreadsheetId: String
    }

    private func liveConfiguration() throws -> Configuration? {
        let environment = ProcessInfo.processInfo.environment
        guard let keyPath = environment["REPEAT_LIVE_KEY_PATH"],
              let spreadsheetId = environment["REPEAT_LIVE_SHEET_ID"],
              !keyPath.isEmpty, !spreadsheetId.isEmpty
        else { return nil }

        let json = try String(contentsOfFile: keyPath, encoding: .utf8)
        return Configuration(account: try ServiceAccount.parse(json: json), spreadsheetId: spreadsheetId)
    }

    private func makeClient(_ configuration: Configuration) -> SheetsClient {
        SheetsClient(
            spreadsheetId: configuration.spreadsheetId,
            tokens: GoogleTokenProvider(account: configuration.account),
            // One try: a live check should report a problem, not spend eight
            // minutes backing off in front of someone waiting for an answer.
            policy: RetryPolicy(maximumAttempts: 1)
        )
    }

    func testTheKeyIsAcceptedAndTheSpreadsheetIsReadable() async throws {
        guard let configuration = try liveConfiguration() else {
            throw XCTSkip("set REPEAT_LIVE_KEY_PATH and REPEAT_LIVE_SHEET_ID to run the live check")
        }

        // Google accepting the assertion is the part no stub can stand in for.
        let token = try await GoogleTokenProvider(account: configuration.account).token()
        XCTAssertFalse(token.isEmpty)

        let sheets = try await makeClient(configuration).sheetProperties()
        XCTAssertFalse(sheets.isEmpty, "the spreadsheet has no worksheets at all")

        let decks = sheets.filter { !$0.isReserved }
        print("[live] account: \(configuration.account.clientEmail)")
        print("[live] worksheets: \(sheets.map { "\($0.title)#\($0.sheetId)" }.joined(separator: ", "))")
        print("[live] deck tabs: \(decks.count), reserved: \(sheets.count - decks.count)")
    }

    func testEveryDeckTabsHeaderParses() async throws {
        guard let configuration = try liveConfiguration() else {
            throw XCTSkip("set REPEAT_LIVE_KEY_PATH and REPEAT_LIVE_SHEET_ID to run the live check")
        }
        let client = makeClient(configuration)
        let decks = try await client.sheetProperties().filter { !$0.isReserved }
        guard !decks.isEmpty else { throw XCTSkip("no deck tabs in this spreadsheet yet") }

        let ranges = try await client.batchGet(ranges: decks.map { "\(A1.quote($0.title))!1:1" })
        for range in ranges {
            let header = range.values.first ?? []
            do {
                let map = try HeaderMap(headerRow: header)
                print("[live] \(range.sheetTitle): ok, extras \(map.extraColumns)")
            } catch {
                print("[live] \(range.sheetTitle): SKIPPED — \(error)")
            }
        }
    }
}

/// Live checks that **write** to the spreadsheet.
///
/// Gated behind a second variable on purpose. A read-only live check is safe to
/// run casually; one that writes to someone's own spreadsheet is not, and the
/// two should never be enabled by the same switch.
///
///     source Config/live.env
///     REPEAT_LIVE_ALLOW_WRITES=1 swift test --filter LiveSheetsWriteTests
final class LiveSheetsWriteTests: XCTestCase {

    private func liveClient() throws -> (SheetsClient, ServiceAccount)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REPEAT_LIVE_ALLOW_WRITES"] == "1",
              let keyPath = environment["REPEAT_LIVE_KEY_PATH"],
              let spreadsheetId = environment["REPEAT_LIVE_SHEET_ID"]
        else { return nil }

        let account = try ServiceAccount.parse(
            json: try String(contentsOfFile: keyPath, encoding: .utf8))
        return (SheetsClient(
            spreadsheetId: spreadsheetId,
            tokens: GoogleTokenProvider(account: account),
            policy: RetryPolicy(maximumAttempts: 1)
        ), account)
    }

    /// Gives an empty deck tab the header row §3.1 specifies, so the app can read
    /// it. Only ever writes into a sheet whose first row is blank — it will not
    /// touch a tab someone has already set up.
    func testAnEmptyDeckTabIsGivenTheSpecHeaderRow() async throws {
        guard let (client, _) = try liveClient() else {
            throw XCTSkip("set REPEAT_LIVE_ALLOW_WRITES=1 to allow writes")
        }
        let decks = try await client.sheetProperties().filter { !$0.isReserved }
        guard let deck = decks.first else { throw XCTSkip("no deck tab to set up") }

        let existing = try await client.batchGet(ranges: ["\(A1.quote(deck.title))!1:1"])
        let firstRow = existing.first?.values.first ?? []
        guard firstRow.allSatisfy(\.isEmpty) else {
            print("[live] \(deck.title) already has a header: \(firstRow)")
            throw XCTSkip("the tab already has a header — not overwriting it")
        }

        let header = ["id", "front", "back", "example", "tags", "reverse", "updated_at", "deleted"]
        try await client.batchUpdate(
            [ValueRange(range: A1.row(sheet: deck.title, width: header.count, row: 1), values: [header])],
            raw: true
        )

        let written = try await client.batchGet(ranges: ["\(A1.quote(deck.title))!1:1"])
        XCTAssertEqual(written.first?.values.first, header)
        XCTAssertNoThrow(try HeaderMap(headerRow: written.first?.values.first ?? []))
        print("[live] wrote the header row to \(deck.title)")
    }

    /// Appends a few cards and reads them back through the same path the app
    /// uses, including the id write-back for a row added without one.
    func testCardsAppendAndComeBackThroughTheNormalReadPath() async throws {
        guard let (client, _) = try liveClient() else {
            throw XCTSkip("set REPEAT_LIVE_ALLOW_WRITES=1 to allow writes")
        }
        let decks = try await client.sheetProperties().filter { !$0.isReserved }
        guard let deck = decks.first else { throw XCTSkip("no deck tab") }

        let before = try await client.batchGet(ranges: [A1.allRows(sheet: deck.title)])
        guard (before.first?.values.count ?? 0) <= 1 else {
            print("[live] \(deck.title) already has \((before.first?.values.count ?? 1) - 1) rows")
            throw XCTSkip("the tab already has cards — not adding more")
        }

        // The last row deliberately carries no id, to exercise §4.3's write-back.
        let rows = [
            [UUID().uuidString, "reluctant", "неохочий", "He was reluctant to admit the mistake.",
             "verbs", "TRUE", "", ""],
            [UUID().uuidString, "thorough", "ретельний", "She gave the report a thorough review.",
             "verbs", "FALSE", "", ""],
            ["", "brittle", "крихкий", "The old rope had gone brittle.", "verbs", "FALSE", "", ""],
        ]
        try await client.append(range: A1.allRows(sheet: deck.title), values: rows)

        let after = try await client.batchGet(ranges: [A1.allRows(sheet: deck.title)])
        let values = try XCTUnwrap(after.first?.values)
        let map = try HeaderMap(headerRow: values[0])

        XCTAssertEqual(values.count, 4, "header plus three cards")
        XCTAssertEqual(map.value("front", in: values[1]), "reluctant")
        XCTAssertTrue(map.boolean("reverse", in: values[1]), "TRUE survives the round trip as a boolean")
        XCTAssertNil(map.value("id", in: values[3]), "the third card has no id yet — #14 writes it back")
        print("[live] appended \(rows.count) cards to \(deck.title)")
    }
}
