import Foundation
@testable import GoogleSheets

/// Scripted transport. Records what was sent so tests can assert the request
/// shape, which is the only way to check an OAuth assertion without a live
/// Google account.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _responses: [Response]
    private var _error: Error?

    var requests: [URLRequest] { lock.withLock { _requests } }
    var requestCount: Int { lock.withLock { _requests.count } }

    init(responses: [Response] = [], error: Error? = nil) {
        self._responses = responses
        self._error = error
    }

    /// A single scripted token, then nothing — so a second exchange is an error
    /// rather than silently succeeding.
    static func oneToken(_ token: String = "ya29.test-token", expiresIn: Double = 3600) -> StubTransport {
        StubTransport(responses: [.json(["access_token": token, "expires_in": expiresIn])])
    }

    /// Keeps answering with the same token so cache tests can distinguish "reused"
    /// from "there was only one answer available".
    static func alwaysReturningToken(_ token: String = "ya29.test-token", expiresIn: Double = 3600) -> StubTransport {
        let stub = StubTransport(responses: [])
        stub.repeating = .json(["access_token": token, "expires_in": expiresIn])
        return stub
    }

    var repeating: Response?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        if let error = lock.withLock({ _error }) { throw error }

        let response: Response? = lock.withLock {
            if !_responses.isEmpty { return _responses.removeFirst() }
            return repeating
        }
        guard let response else {
            throw GoogleAuthError.transport("stub ran out of scripted responses")
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (response.body, http)
    }

    /// The form-encoded body a token request carries.
    func formFields(of request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        return text.split(separator: "&").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }
}
