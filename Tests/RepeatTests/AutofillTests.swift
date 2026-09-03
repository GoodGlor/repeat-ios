import XCTest
@testable import Repeat

/// #30 — the autofill path, and the promise that a bad answer costs nothing.
final class AutofillTests: XCTestCase {

    // MARK: - A transport that says exactly what it is told to

    private final class StubTransport: AutofillTransport, @unchecked Sendable {
        struct Reply {
            var status = 200
            var body: String
        }

        private let replies: [Reply]
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()

        init(_ replies: [Reply]) { self.replies = replies }

        var sentCount: Int { lock.withLock { requests.count } }

        func sentBodies() -> [String] {
            lock.withLock {
                requests.compactMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } }
            }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let index: Int = lock.withLock {
                requests.append(request)
                return requests.count - 1
            }
            let reply = replies[min(index, replies.count - 1)]
            let http = HTTPURLResponse(
                url: request.url!, statusCode: reply.status,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(reply.body.utf8), http)
        }
    }

    private func message(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"content":[{"type":"text","text":"\#(escaped)"}]}"#
    }

    private func client(_ transport: StubTransport) -> AutofillClient {
        AutofillClient(apiKey: "sk-ant-test", model: "claude-sonnet-5", transport: transport)
    }

    // MARK: - Parsing

    func testPlainJSONParses() {
        let suggestion = AutofillParser.suggestion(from: #"{"back":"неохочий","example":"He was reluctant."}"#)
        XCTAssertEqual(suggestion, AutofillSuggestion(back: "неохочий", example: "He was reluctant."))
    }

    /// Models fence JSON despite being told not to. Re-asking costs money, so
    /// the fence is stripped rather than retried.
    func testFencedJSONParses() {
        let fenced = "```json\n{\"back\":\"неохочий\",\"example\":\"He was reluctant.\"}\n```"
        XCTAssertEqual(AutofillParser.suggestion(from: fenced)?.back, "неохочий")

        let untagged = "```\n{\"back\":\"неохочий\"}\n```"
        XCTAssertEqual(AutofillParser.suggestion(from: untagged)?.back, "неохочий")
    }

    func testProseAroundTheObjectIsIgnored() {
        let chatty = "Sure! Here you go:\n{\"back\":\"неохочий\",\"example\":\"x\"}\nHope that helps."
        XCTAssertEqual(AutofillParser.suggestion(from: chatty)?.back, "неохочий")
    }

    /// An answer with no example is still useful — refusing it would waste a
    /// paid request over a field the spec marks optional.
    func testMissingExampleIsAccepted() {
        let suggestion = AutofillParser.suggestion(from: #"{"back":"неохочий"}"#)
        XCTAssertEqual(suggestion?.back, "неохочий")
        XCTAssertEqual(suggestion?.trimmedExample, "")
    }

    /// A well-formed object with nothing in it would otherwise "succeed" and
    /// then clear the form.
    func testBlankFieldsAreNotASuggestion() {
        XCTAssertNil(AutofillParser.suggestion(from: #"{"back":"  ","example":""}"#))
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        for junk in ["", "   ", "not json at all", "{", "}{", "```json\n```", "<html>502</html>", "null"] {
            XCTAssertNil(AutofillParser.suggestion(from: junk), "«\(junk)» should not parse")
        }
    }

    func testResponseTextJoinsTextBlocksAndIgnoresOthers() {
        let body = #"{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#
        XCTAssertEqual(AutofillParser.responseText(from: Data(body.utf8)), "ab")
    }

    func testEmptyContentIsNotText() {
        XCTAssertNil(AutofillParser.responseText(from: Data(#"{"content":[]}"#.utf8)))
        XCTAssertNil(AutofillParser.responseText(from: Data("nonsense".utf8)))
    }

    // MARK: - The request

    /// §8: network calls only to `googleapis.com` and `api.anthropic.com`.
    func testRequestGoesOnlyToAnthropic() throws {
        let request = try client(StubTransport([])).request(front: "reluctant", deckTitle: "Verbs")
        XCTAssertEqual(request.url?.host(), "api.anthropic.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    /// Appendix A: `Deck: {title}\nFront: {front}`, and the model from Settings.
    func testRequestBodyCarriesTheDeckAndFront() throws {
        let request = try client(StubTransport([])).request(front: "reluctant", deckTitle: "Verbs")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "claude-sonnet-5")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Deck: Verbs\nFront: reluctant")
        XCTAssertFalse((object["system"] as? String ?? "").isEmpty)
        // The retry line must not be in the first request, or the retry has no
        // room left to be a retry.
        XCTAssertFalse((messages.first?["content"] as? String ?? "").contains(AutofillClient.retrySuffix))
    }

    // MARK: - The call

    func testSuccessfulCallTakesOneRequest() async throws {
        let transport = StubTransport([.init(body: message(#"{"back":"неохочий","example":"He was reluctant."}"#))])
        let suggestion = try await client(transport).suggest(front: "reluctant", deckTitle: "Verbs")

        XCTAssertEqual(suggestion.back, "неохочий")
        XCTAssertEqual(transport.sentCount, 1)
    }

    /// Appendix A: on failure retry once with "Reply with valid JSON only."
    func testUnparsableReplyRetriesExactlyOnce() async throws {
        let transport = StubTransport([
            .init(body: message("I'd be happy to help!")),
            .init(body: message(#"{"back":"неохочий"}"#)),
        ])
        let suggestion = try await client(transport).suggest(front: "reluctant", deckTitle: "Verbs")

        XCTAssertEqual(suggestion.back, "неохочий")
        XCTAssertEqual(transport.sentCount, 2)
        XCTAssertTrue(transport.sentBodies()[1].contains("Reply with valid JSON only."),
                      "the retry is what carries the extra instruction")
    }

    /// Each attempt costs money. Two failures is where it stops — not a loop
    /// that keeps asking a model to behave.
    func testTwoUnparsableRepliesGiveUp() async {
        let transport = StubTransport([.init(body: message("nope")), .init(body: message("still nope"))])
        do {
            _ = try await client(transport).suggest(front: "reluctant", deckTitle: "Verbs")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? AutofillError, .unparsable)
        }
        XCTAssertEqual(transport.sentCount, 2, "one call, one retry, and no more")
    }

    /// A rejected key is not something different wording fixes, so it must not
    /// be paid for twice.
    func testHTTPFailureIsNotRetried() async {
        let transport = StubTransport([
            .init(status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#),
        ])
        do {
            _ = try await client(transport).suggest(front: "reluctant", deckTitle: "Verbs")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? AutofillError,
                           .http(status: 401, message: "invalid x-api-key"))
        }
        XCTAssertEqual(transport.sentCount, 1)
    }

    func testEveryFailureHasSomethingToShow() {
        let errors: [AutofillError] = [
            .missingKey, .http(status: 401, message: nil), .http(status: 429, message: nil),
            .http(status: 500, message: nil), .unparsable, .transport("offline"),
        ]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertTrue(error.message.hasPrefix("Не вдалося заповнити"),
                          "§6.4 asks for one recognisable failure sentence")
        }
    }

    // MARK: - Applying it to the form

    /// The acceptance criterion, stated directly.
    func testEmptySuggestionValuesNeverClearTypedText() {
        var draft = AddCardComposer.Draft()
        draft.front = "reluctant"
        draft.back = "неохочий"
        draft.example = "He was reluctant to answer."

        let applied = draft.applying(AutofillSuggestion(back: "   ", example: ""))
        XCTAssertEqual(applied.back, "неохочий")
        XCTAssertEqual(applied.example, "He was reluctant to answer.")
    }

    func testSuggestionFillsEmptyFields() {
        var draft = AddCardComposer.Draft()
        draft.front = "reluctant"

        let applied = draft.applying(AutofillSuggestion(back: " неохочий ", example: " He was reluctant. "))
        XCTAssertEqual(applied.back, "неохочий")
        XCTAssertEqual(applied.example, "He was reluctant.")
        XCTAssertEqual(applied.front, "reluctant", "autofill has no business touching the prompt")
    }

    // MARK: - The switch

    private func settings(enabled: Bool) -> AppSettings {
        let name = "autofill-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: suite)
        settings.autofillEnabled = enabled
        return settings
    }

    /// §6.4's acceptance: off in Settings means no button, which means no call.
    /// Checked at the client, so it holds no matter which screen asks.
    func testDisabledSettingsBuildNoClient() throws {
        try AnthropicKeyStore.save("sk-ant-test-key-abcd")
        addTeardownBlock { try? AnthropicKeyStore.delete() }

        XCTAssertNil(AutofillClient.configured(settings: settings(enabled: false)),
                     "a stored key must not resurrect a disabled feature")
        XCTAssertNotNil(AutofillClient.configured(settings: settings(enabled: true)))
    }

    func testEnabledWithoutAKeyBuildsNoClient() throws {
        try AnthropicKeyStore.delete()
        XCTAssertNil(AutofillClient.configured(settings: settings(enabled: true)))
    }
}
