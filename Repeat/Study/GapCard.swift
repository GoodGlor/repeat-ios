import Foundation

/// A card whose front is a sentence with a gap in it (#88).
///
/// ```
/// front:  I decided ___ enable thinking mode.
/// back:   to — decided to enable (decide + to + дієслово)
/// ```
///
/// ## Why this is inferred rather than declared
///
/// Both of the card's open decisions were settled the same way: by what the owner
/// already types. The gap is `___` in `front`, and the expected fragment is the
/// part of `back` before the em dash — which is the shape of the example the card
/// was filed with. That means **no new Sheet column** (D1: the phone never invents
/// one), **no new model attribute** (handoff gotcha 4: a mandatory attribute fails
/// the whole store on migration), and no syntax to learn. The spreadsheet stays
/// readable by hand, which the card asks for explicitly, and the whole feature is
/// reversible: delete the underscores and the card is an ordinary one again.
///
/// The rejected alternative was Anki's `{{c1::to}}`. It carries the answer inline
/// and would make the typed target unambiguous without the em-dash convention, but
/// it is a syntax to learn and it makes the Sheet worse to read — which is the one
/// thing the card said to prefer over everything else.
struct GapCard: Equatable {
    /// The sentence before the gap, e.g. `"I decided "`.
    var before: String
    /// The sentence after the gap, e.g. `" enable thinking mode."`.
    var after: String
    /// What belongs in the gap — `"to"`. This, not the whole `back`, is what a
    /// typed answer is compared against.
    var answer: String
    /// Everything after the em dash: `"decided to enable (decide + to + дієслово)"`.
    /// `nil` when the back is only the answer.
    var explanation: String?

    /// Two or more underscores. One is too easy to type by accident inside an
    /// ordinary word; two is already deliberate.
    ///
    /// Only the **first** run is treated as the gap. Multi-gap cards are a
    /// different feature with a different answer format, and quietly half-handling
    /// them would be worse than not handling them: a second `___` stays literal
    /// text, which at least looks like what it is.
    static let marker = "__"

    static func hasGap(front: String) -> Bool {
        front.range(of: "\(marker)+", options: .regularExpression) != nil
    }

    /// `nil` when the front carries no gap, which is how every existing card keeps
    /// its current behaviour untouched.
    init?(front: String, back: String) {
        guard let range = front.range(of: "_+", options: .regularExpression),
              front.distance(from: range.lowerBound, to: range.upperBound) >= 2
        else { return nil }

        before = String(front[front.startIndex..<range.lowerBound])
        after = String(front[range.upperBound...])

        // The em dash is the owner's own separator. The en dash and a spaced
        // hyphen are accepted too, because a phone keyboard does not make an em
        // dash easy and a card that silently compares against the whole back
        // would mark the right answer wrong.
        let separators = ["—", "–", " - "]
        if let split = separators.compactMap({ back.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            answer = String(back[back.startIndex..<split.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(back[split.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            explanation = rest.isEmpty ? nil : rest
        } else {
            answer = back.trimmingCharacters(in: .whitespacesAndNewlines)
            explanation = nil
        }
    }

    /// The sentence with the gap filled in.
    var filled: String { before + answer + after }

    /// What text-to-speech should say.
    ///
    /// Before the reveal the gap is **skipped** rather than spoken: "I decided
    /// underscore underscore underscore enable" is noise, and it is also the
    /// answer's shape given away as a letter count. Reading it as a pause was the
    /// alternative — a comma produces one — but a comma changes where the sentence
    /// breaks, and the card allows skipping outright.
    func spoken(isRevealed: Bool) -> String {
        let text = isRevealed ? filled : before + " " + after
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
