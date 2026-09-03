import XCTest
@testable import Repeat

/// #88 — the parse, which every other part of the feature reads.
final class GapCardTests: XCTestCase {

    private let front = "I decided ___ enable thinking mode."
    private let back = "to — decided to enable (decide + to + дієслово)"

    func testTheOwnersOwnExampleParses() throws {
        let gap = try XCTUnwrap(GapCard(front: front, back: back))
        XCTAssertEqual(gap.before, "I decided ")
        XCTAssertEqual(gap.after, " enable thinking mode.")
        XCTAssertEqual(gap.answer, "to")
        XCTAssertEqual(gap.explanation, "decided to enable (decide + to + дієслово)")
        XCTAssertEqual(gap.filled, "I decided to enable thinking mode.")
    }

    /// The acceptance line that matters most: an ordinary card must be untouched.
    func testAnOrdinaryCardIsNotAGapCard() {
        XCTAssertNil(GapCard(front: "reluctant", back: "неохочий"))
        XCTAssertNil(GapCard(front: "снідати", back: "to have breakfast"))
        XCTAssertFalse(GapCard.hasGap(front: "reluctant"))
    }

    /// One underscore is a plausible typo or part of a real string; two is a
    /// decision. `snake_case` on the front of a programming card must not silently
    /// become a gap.
    func testASingleUnderscoreIsNotAGap() {
        XCTAssertNil(GapCard(front: "snake_case", back: "змішаний регістр"))
        XCTAssertNotNil(GapCard(front: "snake__case", back: "x"))
    }

    /// A phone keyboard does not make an em dash easy.
    func testTheAnswerSeparatorToleratesTheDashesPeopleActuallyType() throws {
        for separator in ["—", "–", " - "] {
            let gap = try XCTUnwrap(GapCard(front: front, back: "to \(separator) because"))
            XCTAssertEqual(gap.answer, "to", "failed for \(separator)")
            XCTAssertEqual(gap.explanation, "because")
        }
    }

    /// No dash at all: the whole back is the answer, and nothing is invented.
    func testABackWithNoSeparatorIsAllAnswer() throws {
        let gap = try XCTUnwrap(GapCard(front: front, back: "to"))
        XCTAssertEqual(gap.answer, "to")
        XCTAssertNil(gap.explanation)
    }

    /// A hyphenated answer must not be split at its own hyphen — which is why the
    /// spaced form " - " is what is accepted rather than "-".
    func testAHyphenatedAnswerIsNotSplitAtItsOwnHyphen() throws {
        let gap = try XCTUnwrap(GapCard(front: front, back: "well-known"))
        XCTAssertEqual(gap.answer, "well-known")
        XCTAssertNil(gap.explanation)
    }

    /// Gaps of different widths are all gaps: the owner types however many
    /// underscores look right, and the width must not change the meaning.
    func testAnyRunOfTwoOrMoreUnderscoresIsTheGap() throws {
        for marker in ["__", "___", "__________"] {
            let gap = try XCTUnwrap(GapCard(front: "a \(marker) b", back: "x"))
            XCTAssertEqual(gap.before, "a ")
            XCTAssertEqual(gap.after, " b")
        }
    }

    /// Only the first gap is treated as one, and the rest stays literal — visibly
    /// unhandled rather than quietly half-handled.
    func testASecondGapIsLeftAsLiteralText() throws {
        let gap = try XCTUnwrap(GapCard(front: "a ___ b ___ c", back: "x"))
        XCTAssertEqual(gap.before, "a ")
        XCTAssertEqual(gap.after, " b ___ c")
    }

    // MARK: - Typed answers

    /// #88's second acceptance line, and the bug it names: typing `to` was marked
    /// wrong because §6.3's typed mode compared it against the whole back.
    func testTypingTheFragmentIsAcceptedAndTheWholeBackIsNot() throws {
        let gap = try XCTUnwrap(GapCard(front: front, back: back))

        XCTAssertTrue(AnswerDiff.isCorrect(typed: "to", expected: gap.answer))
        // `AnswerDiff` already forgives case and stray whitespace, which is why it
        // is reused rather than a second comparison being written.
        XCTAssertTrue(AnswerDiff.isCorrect(typed: "  To ", expected: gap.answer))
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "for", expected: gap.answer))

        // The behaviour this replaces, stated so the regression is unmissable:
        // against the whole back, the right answer was wrong.
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "to", expected: back),
                       "this is what the old comparison did — the test exists to "
                       + "stop it coming back")
    }

    /// An ordinary card still compares against its back, unchanged.
    func testAnOrdinaryCardStillComparesAgainstItsWholeBack() {
        XCTAssertNil(GapCard(front: "reluctant", back: "неохочий"))
        XCTAssertTrue(AnswerDiff.isCorrect(typed: "неохочий", expected: "неохочий"))
    }

    // MARK: - Speech

    func testSpeechSkipsTheGapAndFillsItOnceRevealed() throws {
        let gap = try XCTUnwrap(GapCard(front: front, back: back))
        XCTAssertEqual(gap.spoken(isRevealed: false), "I decided enable thinking mode.")
        XCTAssertEqual(gap.spoken(isRevealed: true), "I decided to enable thinking mode.")
    }

    /// A gap at the very start or end must not leave a doubled or leading space
    /// for the synthesiser to stumble over.
    func testSpeechTidiesWhitespaceAroundTheGap() throws {
        let leading = try XCTUnwrap(GapCard(front: "___ is the answer.", back: "This"))
        XCTAssertEqual(leading.spoken(isRevealed: false), "is the answer.")
        XCTAssertEqual(leading.spoken(isRevealed: true), "This is the answer.")
    }
}
