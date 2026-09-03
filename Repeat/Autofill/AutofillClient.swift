import Foundation

/// The only thing in this app that talks to Anthropic (§6.4, §8).
///
/// One file, one host. §8 limits network access to `googleapis.com` and
/// `api.anthropic.com`; the Google half is held by the GoogleSheets package and
/// this is the other half, so both claims have exactly one place to check.
protocol AutofillTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct AutofillURLSessionTransport: AutofillTransport {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AutofillError.transport("Відповідь без HTTP-статусу")
        }
        return (data, http)
    }
}

enum AutofillError: Error, Equatable {
    case missingKey
    case http(status: Int, message: String?)
    /// The reply came back but was not a suggestion — after the one retry
    /// Appendix A allows.
    case unparsable
    case transport(String)

    /// §6.4: "failure shows 'Couldn't autofill' and keeps the fields editable".
    /// One sentence, because the form is not the place for an API tutorial — the
    /// distinctions matter only where the owner can act on them.
    var message: String {
        switch self {
        case .missingKey:
            Localized.string("Не вдалося заповнити: немає ключа Anthropic. Додай його в Налаштуваннях.")
        case .http(401, _), .http(403, _):
            Localized.string("Не вдалося заповнити: ключ Anthropic відхилено.")
        case .http(429, _):
            Localized.string("Не вдалося заповнити: забагато запитів. Спробуй за хвилину.")
        case let .http(status, _):
            Localized.string("Не вдалося заповнити (HTTP \(status)).")
        case .unparsable:
            Localized.string("Не вдалося заповнити: відповідь не вдалося розібрати.")
        case .transport:
            Localized.string("Не вдалося заповнити: немає звʼязку.")
        }
    }
}

/// Appendix A's request, and the one retry it prescribes.
struct AutofillClient: Sendable {
    static let host = "api.anthropic.com"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicVersion = "2023-06-01"
    static let maxTokens = 400

    /// Appendix A, verbatim in intent: JSON only, Ukrainian answer, one short
    /// example sentence in the source language.
    static let systemPrompt = """
        You fill in flashcards. Reply with JSON only: {"back": string, "example": string}. \
        `back` is a concise answer in Ukrainian; `example` is one short sentence in the \
        source language using the term. No markdown.
        """
    /// Appended on the retry, and only then.
    static let retrySuffix = "Reply with valid JSON only."

    #if DEBUG
    /// Stands in for the network when a debug launch argument asks for it, so
    /// the form can be exercised without a key and without spending anything.
    /// Compiled out of release builds entirely.
    nonisolated(unsafe) static var debugTransport: (any AutofillTransport)?
    #endif

    let apiKey: String
    let model: String
    let transport: any AutofillTransport

    init(apiKey: String, model: String, transport: any AutofillTransport = AutofillURLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    /// Builds the client from stored settings, or `nil` when autofill is off or
    /// unconfigured.
    ///
    /// Returning `nil` rather than throwing is deliberate: the caller uses it to
    /// decide whether the button exists at all, and a button that appears and
    /// then always fails is worse than no button.
    static func configured(
        settings: AppSettings,
        transport: any AutofillTransport = AutofillURLSessionTransport()
    ) -> AutofillClient? {
        guard settings.autofillEnabled else { return nil }
        guard let key = (try? AnthropicKeyStore.load())?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return AutofillClient(apiKey: key, model: settings.autofillModel, transport: transport)
    }

    static func userMessage(front: String, deckTitle: String, retrying: Bool = false) -> String {
        let base = "Deck: \(deckTitle)\nFront: \(front)"
        return retrying ? "\(base)\n\n\(retrySuffix)" : base
    }

    func request(front: String, deckTitle: String, retrying: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": Self.systemPrompt,
            "messages": [["role": "user",
                          "content": Self.userMessage(front: front, deckTitle: deckTitle,
                                                      retrying: retrying)]],
        ])
        return request
    }

    /// One call, then at most one retry — never more. Each attempt costs money,
    /// and a loop that keeps asking a model to behave is how a stuck request
    /// becomes a bill.
    func suggest(front: String, deckTitle: String) async throws -> AutofillSuggestion {
        do {
            return try await attempt(front: front, deckTitle: deckTitle, retrying: false)
        } catch AutofillError.unparsable {
            return try await attempt(front: front, deckTitle: deckTitle, retrying: true)
        }
    }

    private func attempt(front: String, deckTitle: String, retrying: Bool) async throws -> AutofillSuggestion {
        let response: (Data, HTTPURLResponse)
        do {
            response = try await transport.send(try request(front: front, deckTitle: deckTitle,
                                                            retrying: retrying))
        } catch let error as AutofillError {
            throw error
        } catch {
            throw AutofillError.transport(error.localizedDescription)
        }

        let (data, http) = response
        guard (200..<300).contains(http.statusCode) else {
            // An HTTP failure is not something a retry with different wording
            // fixes, so it is thrown past `suggest`'s catch.
            throw AutofillError.http(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        guard let text = AutofillParser.responseText(from: data),
              let suggestion = AutofillParser.suggestion(from: text)
        else { throw AutofillError.unparsable }
        return suggestion
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}
