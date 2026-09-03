import XCTest
import SwiftData
@testable import Repeat

/// #32 — the diff, and the promise that the mode stays inside its deck.
final class AnswerDiffTests: XCTestCase {

    private func kinds(_ segments: [AnswerDiff.Segment]) -> [AnswerDiff.Kind] {
        segments.map(\.kind)
    }

    private func text(_ segments: [AnswerDiff.Segment], _ kind: AnswerDiff.Kind) -> String {
        segments.filter { $0.kind == kind }.map(\.text).joined()
    }

    // MARK: - Exactly the differing characters

    func testAnExactAnswerIsOneUnbrokenRun() {
        let diff = AnswerDiff.compare(typed: "неохочий", expected: "неохочий")
        XCTAssertEqual(diff, [.init(text: "неохочий", kind: .same)])
    }

    /// The acceptance criterion: *exactly* the differing characters, not the
    /// whole word.
    func testASingleWrongLetterMarksOnlyThatLetter() {
        let diff = AnswerDiff.compare(typed: "неохочей", expected: "неохочий")

        XCTAssertEqual(text(diff, .same), "неохоч" + "й")
        XCTAssertEqual(text(diff, .extra), "е")
        XCTAssertEqual(text(diff, .missing), "и")
    }

    func testAMissingLetterIsMarkedMissingAndNothingElse() {
        let diff = AnswerDiff.compare(typed: "неохочй", expected: "неохочий")
        XCTAssertEqual(text(diff, .extra), "")
        XCTAssertEqual(text(diff, .missing), "и")
        XCTAssertEqual(text(diff, .same), "неохочй")
    }

    func testAnExtraLetterIsMarkedExtraAndNothingElse() {
        let diff = AnswerDiff.compare(typed: "неохоччий", expected: "неохочий")
        XCTAssertEqual(text(diff, .missing), "")
        XCTAssertEqual(text(diff, .extra), "ч")
    }

    /// Runs are merged so the view draws spans, not one view per character.
    func testAdjacentCharactersOfOneKindMerge() {
        let diff = AnswerDiff.compare(typed: "abcxyz", expected: "abc")
        XCTAssertEqual(diff, [.init(text: "abc", kind: .same), .init(text: "xyz", kind: .extra)])
    }

    func testCompletelyDifferentAnswersStillProduceBothSides() {
        let diff = AnswerDiff.compare(typed: "xxx", expected: "yyy")
        XCTAssertEqual(text(diff, .extra), "xxx")
        XCTAssertEqual(text(diff, .missing), "yyy")
        XCTAssertEqual(text(diff, .same), "")
    }

    func testEmptyTypedAnswerIsAllMissing() {
        let diff = AnswerDiff.compare(typed: "", expected: "неохочий")
        XCTAssertEqual(diff, [.init(text: "неохочий", kind: .missing)])
    }

    func testEmptyExpectedAnswerIsAllExtra() {
        let diff = AnswerDiff.compare(typed: "щось", expected: "")
        XCTAssertEqual(diff, [.init(text: "щось", kind: .extra)])
    }

    func testBothEmptyIsNoDiffAtAll() {
        XCTAssertTrue(AnswerDiff.compare(typed: "", expected: "").isEmpty)
    }

    /// A paste is not a flashcard answer, and a quadratic table over one is not
    /// worth building. Saying "all of it differs" is honest.
    func testOverlongInputFallsBackWithoutHanging() {
        let long = String(repeating: "а", count: AnswerDiff.maximumLength + 1)
        let diff = AnswerDiff.compare(typed: long, expected: "неохочий")
        XCTAssertEqual(kinds(diff), [.extra, .missing])
    }

    // MARK: - What counts as right

    /// "Reluctant" is not a spelling mistake.
    func testCaseIsIgnoredForCorrectnessAndForTheDiff() {
        XCTAssertTrue(AnswerDiff.isCorrect(typed: "Неохочий", expected: "неохочий"))
        XCTAssertEqual(AnswerDiff.compare(typed: "Неохочий", expected: "неохочий"),
                       [.init(text: "Неохочий", kind: .same)],
                       "the reader still sees what they typed")
    }

    /// A stray space is not a spelling mistake either — and marking one wrong is
    /// how a mode meant to catch typos becomes a mode people turn off.
    func testSurroundingAndRepeatedWhitespaceIsIgnored() {
        XCTAssertTrue(AnswerDiff.isCorrect(typed: "  неохочий  ", expected: "неохочий"))
        XCTAssertTrue(AnswerDiff.isCorrect(typed: "дуже   неохочий", expected: "дуже неохочий"))
        XCTAssertEqual(AnswerDiff.compare(typed: " неохочий ", expected: "неохочий"),
                       [.init(text: "неохочий", kind: .same)])
    }

    /// This mode exists for spelling-sensitive material. In Ukrainian «и» and
    /// «і» are different letters, not decorations.
    func testDiacriticsAndLookalikeLettersAreNotFolded() {
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "неохочій", expected: "неохочий"))
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "resume", expected: "résumé"))
    }

    func testAnEmptyExpectedAnswerIsNeverCorrect() {
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "", expected: ""),
                       "an answerless card must not grade itself right")
        XCTAssertFalse(AnswerDiff.isCorrect(typed: "  ", expected: "   "))
    }

    // MARK: - Per deck, not per session

    /// The acceptance criterion: the mode must not leak into other decks in the
    /// same session. §5.2 interleaves decks, so this is a real path, not a
    /// hypothetical one.
    func testModeIsReadFromEachCardsOwnDeck() throws {
        let context = ModelContext(try ModelStore.container(inMemory: true))

        let typing = Deck(sheetTitle: "Spelling", sheetId: 0, typeAnswer: true)
        let tapping = Deck(sheetTitle: "Verbs", sheetId: 1, typeAnswer: false)
        context.insert(typing)
        context.insert(tapping)

        let typedNote = Note(deck: typing, front: "accommodate", back: "розмістити", sheetRow: 1)
        let tappedNote = Note(deck: tapping, front: "reluctant", back: "неохочий", sheetRow: 1)
        context.insert(typedNote)
        context.insert(tappedNote)
        let typedCard = try XCTUnwrap(context.syncCards(for: typedNote).first)
        let tappedCard = try XCTUnwrap(context.syncCards(for: tappedNote).first)
        try context.save()

        XCTAssertTrue(typedCard.note.deck.typeAnswer)
        XCTAssertFalse(tappedCard.note.deck.typeAnswer,
                       "a session holding both must not carry the mode across")

        // And flipping one deck leaves the other alone.
        tappedCard.note.deck.typeAnswer = true
        XCTAssertTrue(typedCard.note.deck.typeAnswer)
        typing.typeAnswer = false
        XCTAssertTrue(tappedCard.note.deck.typeAnswer)
    }
}
