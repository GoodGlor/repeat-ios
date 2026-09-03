import Foundation
import SwiftData
import GoogleSheets
import XCTest
@testable import Repeat

/// Scripted Sheets backend shared by the pull suites.
///
/// Drives a real `SheetsClient`, so the request building, retry and parsing paths
/// are exercised rather than mocked away — the bugs in this layer live in exactly
/// those places.
final class SheetStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var rows: [String: [[String]]]
    private(set) var updates: [[String: Any]] = []
    private(set) var appends: [(range: String, values: [[String]])] = []
    /// When set, every Sheets call fails with it — the "Sheet unreachable" case.
    /// A thrown error is a *transport* failure by definition, so this models
    /// airplane mode. For a refusal from Google, use `failureStatus`.
    var failure: Error?
    /// When set, every Sheets call answers with this HTTP status — 403 for a
    /// spreadsheet that is not shared, 404 for a bad id.
    var failureStatus: Int?
    /// Structural `addSheet` requests, by title (#17 creates `_log`).
    private(set) var addedSheets: [String] = []
    /// When set, appends past this count fail — a push interrupted mid-backlog.
    var failAppendsAfter: Int?
    /// Reserved tabs the spreadsheet already has, beyond the deck tabs in `rows`.
    var reservedTabs: [String] = []
    /// How many discovery passes ran — one per sync run (#18).
    private(set) var propertyRequests = 0
    /// Holds every request until opened, so a test can provoke a second trigger
    /// while the first run is genuinely in flight.
    var gate: AsyncGate?

    init(rows: [String: [[String]]] = [:]) { self.rows = rows }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.host != "oauth2.googleapis.com", let gate { await gate.wait() }
        func reply(_ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object),
             HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.host == "oauth2.googleapis.com" {
            return try reply(["access_token": "t", "expires_in": 3600.0])
        }

        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        if let failureStatus {
            return (Data("{}".utf8),
                    HTTPURLResponse(url: url, statusCode: failureStatus,
                                    httpVersion: nil, headerFields: nil)!)
        }

        // `GET /v4/spreadsheets/{id}` with no verb: the discovery pass.
        if request.httpMethod == "GET", !url.path.contains("/values") {
            propertyRequests += 1
            let titles = rows.keys.sorted() + reservedTabs
            return try reply(["sheets": titles.enumerated().map { index, title in
                ["properties": ["sheetId": index, "title": title, "index": index]]
            }])
        }
        if url.path.hasSuffix("values:batchUpdate") {
            updates.append((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                            as? [String: Any]) ?? [:])
            return try reply([:])
        }
        if url.path.hasSuffix(":batchUpdate"), !url.path.contains("/values") {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [String: Any]
            for request in (body?["requests"] as? [[String: Any]]) ?? [] {
                guard let add = request["addSheet"] as? [String: Any],
                      let properties = add["properties"] as? [String: Any],
                      let title = properties["title"] as? String else { continue }
                addedSheets.append(title)
            }
            return try reply([:])
        }
        if url.path.contains(":append") {
            if let limit = failAppendsAfter, appends.count >= limit {
                // 400, not 500: a retriable status would send the client into
                // §4.6's minute-scale backoff and hang the test.
                return (Data("{}".utf8),
                        HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [String: Any]
            appends.append((
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path,
                (body?["values"] as? [[String]]) ?? []
            ))
            return try reply([:])
        }
        if url.path.hasSuffix("values:batchGet") {
            let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == "ranges" }.compactMap(\.value) ?? []
            return try reply(["valueRanges": requested.map { range in
                let title = range.split(separator: "!").first.map {
                    $0.hasPrefix("'") ? String($0.dropFirst().dropLast()) : String($0)
                } ?? ""
                return ["range": range, "values": rows[title] ?? []]
            }])
        }
        return try reply([:])
    }

    var writtenCells: [String: String] {
        var out: [String: String] = [:]
        for update in updates {
            for entry in (update["data"] as? [[String: Any]]) ?? [] {
                guard let range = entry["range"] as? String,
                      let values = entry["values"] as? [[String]],
                      let value = values.first?.first else { continue }
                out[range] = value
            }
        }
        return out
    }

    var inputOptions: [String] { updates.compactMap { $0["valueInputOption"] as? String } }

    /// Every whole row written by `values:batchUpdate`. `writtenCells` keeps only
    /// each range's first cell, which is the id column — no use for asserting on
    /// content.
    var writtenRows: [[String]] {
        updates.flatMap { update in
            ((update["data"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["values"] as? [[String]]) ?? [] }
        }
    }
}

/// Lets a test hold every Sheets call open until it says otherwise.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        lock.lock()
        if isOpen { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

enum SheetSyncHarness {
    static let header = ["id", "front", "back", "example", "tags", "reverse", "deleted"]

    static func makePull(_ stub: SheetStub) throws -> SheetPull {
        SheetPull(client: try makeClient(stub))
    }

    static func makeClient(_ stub: SheetStub) throws -> SheetsClient {
        let object: [String: Any] = [
            "type": "service_account", "project_id": "p",
            "private_key": try RepeatTestKeys.makePEM(),
            "client_email": "a@b.iam.gserviceaccount.com",
        ]
        let account = try ServiceAccount.parse(
            json: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        return SheetsClient(
            spreadsheetId: "s",
            tokens: GoogleTokenProvider(account: account, transport: stub),
            transport: stub
        )
    }

    static func makeContext(deck title: String = "Verbs") throws -> (ModelContext, Deck) {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: title, sheetId: 0)
        ctx.insert(deck)
        try ctx.save()
        return (ctx, deck)
    }

    static func discovery(_ titles: [String] = ["Verbs"], extraColumns: [String] = []) throws -> DiscoveryResult {
        var result = DiscoveryResult()
        for title in titles {
            result.readable[title] = try HeaderMap(headerRow: header + extraColumns)
        }
        return result
    }

    static func row(_ id: UUID, front: String, back: String, reverse: Bool = false, deleted: Bool = false) -> [String] {
        [id.uuidString, front, back, "", "", reverse ? "TRUE" : "", deleted ? "TRUE" : ""]
    }
}
