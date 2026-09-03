import Foundation

/// A character-level diff between what was typed and the answer (§6.3).
///
/// Pure, and separate from the view: "highlights exactly the differing
/// characters" is a claim about an algorithm, and the only way to hold it is to
/// be able to ask the algorithm directly.
enum AnswerDiff {

    /// A run of characters, relative to the expected answer.
    enum Kind: Equatable {
        /// Typed, and correct.
        case same
        /// Typed, but not in the answer.
        case extra
        /// In the answer, but not typed.
        case missing
    }

    struct Segment: Equatable {
        var text: String
        var kind: Kind
    }

    /// Longer than this and the quadratic table stops being free. A flashcard
    /// answer is a word or a sentence; anything at this length is a paste, and
    /// "all of it differs" is an honest thing to say about it.
    static let maximumLength = 600

    /// Comparison ignores case and treats any run of whitespace as one space.
    ///
    /// Case, because "Reluctant" is not a spelling mistake. Whitespace, because a
    /// stray trailing space is not either — and marking one wrong is how a mode
    /// meant to catch typos becomes a mode people turn off.
    ///
    /// Diacritics are *not* folded: this mode exists for spelling-sensitive
    /// material, and in Ukrainian "и" and "і" are different letters, not
    /// decorations.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    static func isCorrect(typed: String, expected: String) -> Bool {
        !normalize(expected).isEmpty && normalize(typed) == normalize(expected)
    }

    /// The diff, as runs. Adjacent characters of the same kind are merged so the
    /// view draws a handful of spans rather than one per character.
    static func compare(typed: String, expected: String) -> [Segment] {
        let typedChars = Array(normalizeForDisplay(typed))
        let expectedChars = Array(normalizeForDisplay(expected))

        if typedChars.isEmpty { return merge(expectedChars.map { Segment(text: String($0), kind: .missing) }) }
        if expectedChars.isEmpty { return merge(typedChars.map { Segment(text: String($0), kind: .extra) }) }
        guard typedChars.count <= maximumLength, expectedChars.count <= maximumLength else {
            return merge([Segment(text: String(typedChars), kind: .extra),
                          Segment(text: String(expectedChars), kind: .missing)])
        }

        return merge(walk(lcs(typedChars, expectedChars), typedChars, expectedChars))
    }

    // MARK: - Display normalisation

    /// Whitespace is collapsed for display too, so the diff cannot mark an
    /// invisible difference the reader has no way to see.
    private static func normalizeForDisplay(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - LCS

    /// Matching is case-insensitive, so `Reluctant` against `reluctant` is one
    /// `same` run rather than a wall of red. The *original* characters are what
    /// the segments carry, so the reader still sees what they typed.
    private static func equal(_ a: Character, _ b: Character) -> Bool {
        a == b || String(a).lowercased() == String(b).lowercased()
    }

    /// Classic LCS table. `lengths[i][j]` is the longest common subsequence of
    /// the first `i` typed and first `j` expected characters.
    private static func lcs(_ typed: [Character], _ expected: [Character]) -> [[Int]] {
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: expected.count + 1),
                              count: typed.count + 1)
        for i in stride(from: typed.count - 1, through: 0, by: -1) {
            for j in stride(from: expected.count - 1, through: 0, by: -1) {
                lengths[i][j] = equal(typed[i], expected[j])
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        return lengths
    }

    private static func walk(_ lengths: [[Int]], _ typed: [Character], _ expected: [Character]) -> [Segment] {
        var segments: [Segment] = []
        var i = 0
        var j = 0
        while i < typed.count, j < expected.count {
            if equal(typed[i], expected[j]) {
                segments.append(Segment(text: String(typed[i]), kind: .same))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                segments.append(Segment(text: String(typed[i]), kind: .extra))
                i += 1
            } else {
                segments.append(Segment(text: String(expected[j]), kind: .missing))
                j += 1
            }
        }
        while i < typed.count {
            segments.append(Segment(text: String(typed[i]), kind: .extra))
            i += 1
        }
        while j < expected.count {
            segments.append(Segment(text: String(expected[j]), kind: .missing))
            j += 1
        }
        return segments
    }

    private static func merge(_ segments: [Segment]) -> [Segment] {
        segments.reduce(into: [Segment]()) { result, segment in
            if var last = result.last, last.kind == segment.kind {
                last.text += segment.text
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
    }
}
