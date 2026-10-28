#if DEBUG
import Foundation
import GoogleSheets
import Security
import SwiftData

/// A spreadsheet that lives in memory, so a sync can **land** in the simulator.
///
/// `-offlineOnLaunch` (#86) made the failing path observable; this makes the
/// succeeding one observable, which the pull-to-refresh crash of 2026-09-04 needed:
/// it only reproduced when a sync finished and Home rebuilt its plan on top of a
/// rebuild still in flight. Answers exactly the calls `SheetDiscovery`, `SheetPull`,
/// `SheetPush` and `LogPush` make, the way `SheetStub` does in the unit tests —
/// with one difference: appended rows are **kept**, as a real Sheet keeps them,
/// so the notes the launch sync pushes are still there for the next pull to find.
///
/// The sheet starts out holding **what the seed says it holds**: `SampleData`
/// stamps a `sheetRow` on every note, so to the pull a tab with only a header
/// reads as "the owner deleted all ten rows" and Home goes to zero — correctly.
/// From the second discovery onward there is one more row the app has never seen.
/// The launch sync finds the tab as seeded; the pull the test makes afterwards
/// finds the new row — the owner editing the spreadsheet between opening the app
/// and pulling down.
final class CannedSheetTransport: HTTPTransport, @unchecked Sendable {
    static let header = ["id", "front", "back", "example", "tags", "reverse", "deleted"]

    private let lock = NSLock()
    private var rows: [String: [[String]]]
    private var discoveries = 0

    init(deckRows: [[String]]) {
        rows = [SampleData.deckTitle: [Self.header] + deckRows, "_log": []]
    }

    /// The seeded deck as rows, in the push's own layout.
    @MainActor
    static func rows(mirroring context: ModelContext) -> [[String]] {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        return notes
            .filter { $0.deletedAt == nil && $0.deck.sheetTitle == SampleData.deckTitle }
            .sorted { $0.sheetRow < $1.sheetRow }
            .map { note in
                [note.id.uuidString, note.front, note.back, note.example ?? "",
                 note.tags.joined(separator: ","), note.reverse ? "TRUE" : "FALSE", "FALSE"]
            }
    }
    private static let lateRow = [
        "C0FFEE00-0000-4000-8000-000000000011", "arrive", "прибувати", "", "", "", "",
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object),
             HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.host == "oauth2.googleapis.com" {
            return try reply(["access_token": "canned", "expires_in": 3600.0])
        }

        lock.lock(); defer { lock.unlock() }

        // `GET /v4/spreadsheets/{id}`: the discovery pass, once per sync run.
        if request.httpMethod == "GET", !url.path.contains("/values") {
            discoveries += 1
            if discoveries == 2 { rows[SampleData.deckTitle]?.append(Self.lateRow) }
            let titles = [SampleData.deckTitle, "_log"]
            return try reply(["sheets": titles.enumerated().map { index, title in
                ["properties": ["sheetId": index, "title": title, "index": index]]
            }])
        }
        if url.path.contains(":append") {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [String: Any]
            let range = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
            let title = Self.tabTitle(inRange: range.components(separatedBy: "/values/").last ?? "")
            rows[title, default: []].append(contentsOf: (body?["values"] as? [[String]]) ?? [])
            return try reply([:])
        }
        if url.path.hasSuffix("values:batchGet") {
            let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == "ranges" }.compactMap(\.value) ?? []
            return try reply(["valueRanges": requested.map { range in
                ["range": range, "values": rows[Self.tabTitle(inRange: range)] ?? []]
            }])
        }
        // `values:batchUpdate` (cell edits) and `:batchUpdate` (adding a tab): the
        // sheet already has every tab, and nothing the seed pushes is an edit.
        return try reply([:])
    }

    // MARK: - A key that signs nothing anyone will check

    private static let lock = NSLock()
    private static var account: ServiceAccount?

    /// A service account generated on first use, for any run with a debug
    /// transport. Mirrors `RepeatTestKeys.makePEM` in the tests: generated rather
    /// than committed, because a real-looking private key in the repository is a
    /// secret-shaped object with no upside.
    static func throwawayAccount() throws -> ServiceAccount {
        lock.lock(); defer { lock.unlock() }
        if let account { return account }
        let made = ServiceAccount(
            clientEmail: "canned@repeat-debug.iam.gserviceaccount.com",
            tokenURI: URL(string: "https://oauth2.googleapis.com/token")!,
            projectId: "repeat-debug",
            privateKeyPEM: try makePEM()
        )
        account = made
        return made
    }

    private static func makePEM(bits: Int = 2048) throws -> String {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else { throw NSError(domain: "CannedSheetTransport", code: 1) }

        // PKCS#1 → PKCS#8, which is what a downloaded key file contains.
        let oid = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
                        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        var body = Data([0x02, 0x01, 0x00])
        body.append(oid)
        body.append(der(tag: 0x04, value: pkcs1))
        let base64 = der(tag: 0x30, value: body)
            .base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }

    private static func der(tag: UInt8, value: Data) -> Data {
        var out = Data([tag])
        if value.count < 0x80 {
            out.append(UInt8(value.count))
        } else {
            var length = value.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(value)
        return out
    }

    /// `'Title'!A1:G` → `Title`.
    private static func tabTitle(inRange range: String) -> String {
        let name = range.split(separator: "!").first.map(String.init) ?? range
        let unquoted = name.hasPrefix("'") ? String(name.dropFirst().dropLast()) : name
        return unquoted.replacingOccurrences(of: "''", with: "'")
    }
}
#endif
