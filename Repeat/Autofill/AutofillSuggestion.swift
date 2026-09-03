import Foundation

/// What the model is asked for, and all it is allowed to change (Appendix A).
struct AutofillSuggestion: Codable, Equatable, Sendable {
    var back: String
    /// One short sentence in the source language. Optional in practice: a model
    /// that answers with only `back` has still been useful, and refusing the
    /// whole reply over a missing example would waste the request.
    var example: String?

    var trimmedBack: String { back.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedExample: String {
        (example ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { trimmedBack.isEmpty && trimmedExample.isEmpty }
}

/// Turning a model's reply into a suggestion, defensively (§6.4).
///
/// Separate from the client because this is the part that has to survive
/// nonsense, and nonsense is easy to write a test for and hard to get from a
/// live API on demand.
enum AutofillParser {

    /// Pulls the JSON object out of whatever came back.
    ///
    /// Models wrap JSON in ```json fences despite being told not to, and add a
    /// sentence before it. Both are recoverable, and re-asking costs money.
    static func extractJSON(from text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ```json … ``` — strip the fence rather than the language tag alone, so
        // a fence with no tag is handled by the same code.
        if body.hasPrefix("```") {
            var lines = body.components(separatedBy: .newlines)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Prose before or after the object. Taking the outermost braces is
        // enough: the reply is one object, and a nested one stays inside it.
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end
        else { return nil }
        return String(body[start...end])
    }

    /// `nil` for anything that is not a usable suggestion — including a
    /// well-formed object whose fields are all blank, which would otherwise
    /// "succeed" and wipe the form.
    static func suggestion(from text: String) -> AutofillSuggestion? {
        guard let json = extractJSON(from: text), let data = json.data(using: .utf8) else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(AutofillSuggestion.self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

    /// The text blocks of a Messages API response, joined.
    ///
    /// Hand-parsed rather than modelled: the response carries fields this app has
    /// no use for, and a `Codable` struct that must be revised whenever the API
    /// gains one is a liability in a path that already has to tolerate garbage.
    static func responseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]]
        else { return nil }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }
}

extension AddCardComposer.Draft {
    /// Applies a suggestion without ever emptying a field (§6.4's acceptance:
    /// a bad response "never clears typed text").
    ///
    /// A blank value in the reply is *not* an instruction to blank the field —
    /// it is the model having nothing to say. Treating the two the same is how
    /// a half-typed card gets erased by a button press.
    func applying(_ suggestion: AutofillSuggestion) -> AddCardComposer.Draft {
        var copy = self
        if !suggestion.trimmedBack.isEmpty { copy.back = suggestion.trimmedBack }
        if !suggestion.trimmedExample.isEmpty { copy.example = suggestion.trimmedExample }
        return copy
    }
}
