import Foundation

/// Typed access to the four Sheets v4 calls §4 needs (§4.3, §4.4).
///
/// One place owns retries, so no call site reimplements them, and one place
/// builds URLs, so §8's "network calls only to googleapis.com" is checkable
/// rather than assumed.
public struct SheetsClient: Sendable {
    public static let host = "sheets.googleapis.com"

    private let spreadsheetId: String
    private let tokens: GoogleTokenProvider
    private let transport: HTTPTransport
    private let policy: RetryPolicy
    private let sleeper: Sleeper

    public init(
        spreadsheetId: String,
        tokens: GoogleTokenProvider,
        transport: HTTPTransport = URLSessionTransport(),
        policy: RetryPolicy = RetryPolicy(),
        sleeper: Sleeper = TaskSleeper()
    ) {
        self.spreadsheetId = spreadsheetId
        self.tokens = tokens
        self.transport = transport
        self.policy = policy
        self.sleeper = sleeper
    }

    // MARK: - Reads

    /// The worksheets in the spreadsheet (§4.3 step 1). `fields` keeps the
    /// response to what is needed — a spreadsheet's full metadata is large.
    public func sheetProperties() async throws -> [SheetProperties] {
        let data = try await send(
            method: "GET",
            path: "/v4/spreadsheets/\(spreadsheetId)",
            query: [URLQueryItem(name: "fields", value: "sheets.properties")]
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sheets = object["sheets"] as? [[String: Any]]
        else { throw SheetsError.malformedResponse("очікувався масив sheets") }

        return try sheets.map { entry in
            guard let properties = entry["properties"] as? [String: Any],
                  let sheetId = properties["sheetId"] as? Int,
                  let title = properties["title"] as? String
            else { throw SheetsError.malformedResponse("аркуш без properties") }
            return SheetProperties(
                sheetId: sheetId, title: title, index: properties["index"] as? Int ?? 0
            )
        }
    }

    /// Every deck tab in one request (§4.3 step 2).
    public func batchGet(ranges: [String]) async throws -> [ValueRange] {
        guard !ranges.isEmpty else { return [] }
        let data = try await send(
            method: "GET",
            path: "/v4/spreadsheets/\(spreadsheetId)/values:batchGet",
            query: ranges.map { URLQueryItem(name: "ranges", value: $0) }
                + [URLQueryItem(name: "majorDimension", value: "ROWS")]
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valueRanges = object["valueRanges"] as? [[String: Any]]
        else { throw SheetsError.malformedResponse("очікувався valueRanges") }

        return valueRanges.map { entry in
            ValueRange(
                range: entry["range"] as? String ?? "",
                values: normalise(entry["values"] as? [[Any]] ?? [])
            )
        }
    }

    // MARK: - Writes

    /// Updates whole rows in place (§4.4). `RAW` for the id write-back (§4.3
    /// step 5); `USER_ENTERED` for content the owner would have typed.
    public func batchUpdate(_ updates: [ValueRange], raw: Bool) async throws {
        guard !updates.isEmpty else { return }
        let body: [String: Any] = [
            "valueInputOption": raw ? "RAW" : "USER_ENTERED",
            "data": updates.map { ["range": $0.range, "majorDimension": "ROWS", "values": $0.values] },
        ]
        _ = try await send(
            method: "POST",
            path: "/v4/spreadsheets/\(spreadsheetId)/values:batchUpdate",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    /// Appends rows to a tab (§4.4): new notes, and `_log` rows.
    public func append(range: String, values: [[String]]) async throws {
        guard !values.isEmpty else { return }
        _ = try await send(
            method: "POST",
            path: "/v4/spreadsheets/\(spreadsheetId)/values/\(A1.pathEscaped(range)):append",
            query: [
                URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
                URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
            ],
            body: try JSONSerialization.data(withJSONObject: ["values": values])
        )
    }

    /// Creates a worksheet (§3.1). Only ever used for `_log`, which the phone
    /// owns outright — a spreadsheet the owner built by hand has no reason to
    /// contain it until the first session is pushed.
    ///
    /// This is the *structural* `spreadsheets.batchUpdate`, a different endpoint
    /// from `values:batchUpdate` above: one edits the document, the other edits
    /// cells.
    public func addSheet(title: String) async throws {
        let body: [String: Any] = [
            "requests": [["addSheet": ["properties": ["title": title]]]]
        ]
        _ = try await send(
            method: "POST",
            path: "/v4/spreadsheets/\(spreadsheetId):batchUpdate",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    /// Reaches the spreadsheet and reports precisely why if it cannot — the part
    /// of #10's "test connection" that needs the network.
    public func checkAccess() async throws -> [SheetProperties] {
        try await sheetProperties()
    }

    // MARK: - Transport

    private func send(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        var attempt = 0
        var refreshedToken = false

        while true {
            attempt += 1
            // Cancellation is checked before sleeping and before sending, so a
            // sync cancelled mid-backoff stops rather than waking to fire.
            try Task.checkCancellation()
            let delay = policy.delay(beforeAttempt: attempt)
            if delay > 0 { try await sleeper.sleep(for: delay) }
            try Task.checkCancellation()

            let request = try await makeRequest(method: method, path: path, query: query, body: body)

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GoogleAuthError {
                throw SheetsError.auth(error)
            } catch {
                throw SheetsError.transport(error.localizedDescription)
            }

            if (200..<300).contains(response.statusCode) { return data }

            // A 401 mid-session means the cached token died — a revoked key, or a
            // clock jump. Worth exactly one silent retry; a second means the
            // credential itself is bad and the owner has to act (§4.6).
            if response.statusCode == 401, !refreshedToken {
                refreshedToken = true
                await tokens.invalidate()
                attempt -= 1
                continue
            }

            if RetryPolicy.isRetriable(status: response.statusCode), attempt < policy.maximumAttempts {
                continue
            }
            throw Self.error(status: response.statusCode, data: data, attempts: attempt)
        }
    }

    private func makeRequest(
        method: String, path: String, query: [URLQueryItem], body: Data?
    ) async throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        // Already percent-encoded: `path` carries an A1 range whose `:` must stay
        // escaped so it cannot be confused with the `:append` verb. Assigning to
        // `path` instead would re-encode the `%` and produce `%253A`.
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw SheetsError.malformedResponse("не вдалося побудувати URL для \(path)")
        }

        let token: String
        do {
            token = try await tokens.token()
        } catch let error as GoogleAuthError {
            throw SheetsError.auth(error)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Google returns a JSON error body with the useful part in `error.message`.
    static func error(status: Int, data: Data, attempts: Int) -> SheetsError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? "HTTP \(status)"

        switch status {
        case 404: return .spreadsheetNotFound
        case 403: return .notShared
        case 401: return .auth(.rejected(reason: message))
        case 429: return .rateLimited(afterAttempts: attempts)
        default: return .server(status: status, message: message)
        }
    }

    /// Google returns numbers and booleans unquoted and omits trailing empty
    /// cells, so rows arrive ragged and mixed-typed. Everything becomes a string
    /// here, once, rather than at each of the dozens of call sites in §4.3.
    private func normalise(_ rows: [[Any]]) -> [[String]] {
        rows.map { row in
            row.map { cell in
                switch cell {
                case let text as String: text
                case let number as NSNumber:
                    // NSNumber boxes booleans; 1 must not become "1" when the cell
                    // holds TRUE, because `reverse` and `deleted` are booleans.
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                        ? (number.boolValue ? "TRUE" : "FALSE")
                        : number.stringValue
                default: String(describing: cell)
                }
            }
        }
    }
}
