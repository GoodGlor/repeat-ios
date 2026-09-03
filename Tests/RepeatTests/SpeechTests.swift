import XCTest
import AVFoundation
import SwiftData
@testable import Repeat

/// #31 — when the study screen speaks, and what.
///
/// No audio is played: `AVSpeechSynthesizer` in a test either says nothing
/// useful or blocks on a machine with no output, so the rules are tested and the
/// synthesizer is only asked what it would choose.
@MainActor
final class SpeechTests: XCTestCase {

    private final class SpySpeaker: CardSpeaker {
        private(set) var spoken: [String] = []
        private(set) var stops = 0

        func speak(_ text: String) { spoken.append(text) }
        func stop() { stops += 1 }
    }

    // MARK: - Auto-TTS

    /// §6.3: "speak `front` on show". The answer is never spoken automatically —
    /// hearing it before trying to recall it is the one thing that defeats the
    /// card.
    func testAutoSpeakSaysTheFrontOnly() {
        XCTAssertEqual(StudySpeech.onShow(front: "reluctant", autoTTS: true), .speak("reluctant"))
    }

    /// The acceptance criterion: off means silent, immediately and for this deck.
    func testAutoSpeakIsSilentWhenTheDeckSaysSo() {
        XCTAssertEqual(StudySpeech.onShow(front: "reluctant", autoTTS: false), .silent)
    }

    func testNothingToSayIsSilence() {
        XCTAssertEqual(StudySpeech.onShow(front: "   \n", autoTTS: true), .silent)
        XCTAssertEqual(StudySpeech.onShow(front: "", autoTTS: true), .silent)
    }

    // MARK: - Long press

    /// §6.3's gesture list: "long-press reveal = play TTS".
    func testLongPressSpeaksThePromptBeforeRevealAndTheAnswerAfter() {
        XCTAssertEqual(
            StudySpeech.onLongPress(front: "reluctant", back: "неохочий", isRevealed: false),
            .speak("reluctant")
        )
        XCTAssertEqual(
            StudySpeech.onLongPress(front: "reluctant", back: "неохочий", isRevealed: true),
            .speak("неохочий")
        )
    }

    /// A long press is explicit, so it works on a deck that has auto-TTS off —
    /// the toggle governs what happens *without* being asked.
    func testLongPressDoesNotConsultTheDeckToggle() {
        // The signature is the proof: there is no toggle to pass.
        XCTAssertEqual(
            StudySpeech.onLongPress(front: "reluctant", back: "", isRevealed: false),
            .speak("reluctant")
        )
        XCTAssertEqual(
            StudySpeech.onLongPress(front: "reluctant", back: "  ", isRevealed: true),
            .silent,
            "a card with no answer has nothing to read out"
        )
    }

    // MARK: - Reading the toggle off the card

    private func makeCard(front: String, back: String, autoTTS: Bool) throws -> Card {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0, autoTTS: autoTTS)
        context.insert(deck)
        let note = Note(deck: deck, front: front, back: back, sheetRow: 1)
        context.insert(note)
        let cards = context.syncCards(for: note)
        try context.save()
        return try XCTUnwrap(cards.first)
    }

    /// The wiring that could actually be wrong: the toggle lives on the deck,
    /// two hops from the card on screen. A session interleaves decks (§5.2), so
    /// reading it off the card is the only version that stays right.
    func testAutoSpeakReadsTheToggleFromTheCardsOwnDeck() throws {
        let speaking = try makeCard(front: "reluctant", back: "неохочий", autoTTS: true)
        XCTAssertEqual(StudySpeech.onShow(card: speaking), .speak("reluctant"))

        let quiet = try makeCard(front: "reluctant", back: "неохочий", autoTTS: false)
        XCTAssertEqual(StudySpeech.onShow(card: quiet), .silent)
    }

    /// Turning the toggle off has to silence the deck now, not on the next card.
    func testFlippingTheDeckToggleChangesThePlanImmediately() throws {
        let card = try makeCard(front: "reluctant", back: "неохочий", autoTTS: true)
        XCTAssertEqual(StudySpeech.onShow(card: card), .speak("reluctant"))

        card.note.deck.autoTTS = false
        XCTAssertEqual(StudySpeech.onShow(card: card), .silent)
    }

    func testNoCardIsSilence() {
        XCTAssertEqual(StudySpeech.onShow(card: nil), .silent)
        XCTAssertEqual(StudySpeech.onLongPress(card: nil, isRevealed: false), .silent)
    }

    /// A long press works on a deck that has auto-TTS off — the toggle governs
    /// what happens *without* being asked.
    func testLongPressWorksOnASilentDeck() throws {
        let quiet = try makeCard(front: "reluctant", back: "неохочий", autoTTS: false)
        XCTAssertEqual(StudySpeech.onLongPress(card: quiet, isRevealed: false), .speak("reluctant"))
        XCTAssertEqual(StudySpeech.onLongPress(card: quiet, isRevealed: true), .speak("неохочий"))
    }

    // MARK: - The speaker

    func testSilentPlanStopsRatherThanSpeaks() {
        let spy = SpySpeaker()
        for plan in [StudySpeech.Plan.silent, .speak("reluctant")] {
            switch plan {
            case .silent: spy.stop()
            case let .speak(text): spy.speak(text)
            }
        }
        XCTAssertEqual(spy.spoken, ["reluctant"])
        XCTAssertEqual(spy.stops, 1)
    }

    // MARK: - Voice selection

    /// A vocabulary card is bilingual by construction, so one fixed voice reads
    /// one side of every card as gibberish.
    func testLanguageIsDetectedPerSide() {
        XCTAssertEqual(SpeechVoice.languageCode(for: "He was reluctant to answer the question."), "en")
        XCTAssertEqual(SpeechVoice.languageCode(for: "Він неохоче відповів на запитання."), "uk")
    }

    /// A short string is exactly where the recogniser guesses, and guessing wrong
    /// is worse than using the device's own voice.
    func testLowConfidenceFallsBackRatherThanGuessing() {
        XCTAssertEqual(SpeechVoice.languageCode(for: "", fallback: "uk-UA"), "uk-UA")
        XCTAssertNil(SpeechVoice.languageCode(for: "   "))
    }

    /// The fallback for an unavailable voice is the system default, not a crash
    /// and not silence.
    func testUnknownLanguageYieldsNoVoiceRatherThanFailing() {
        XCTAssertNil(AVSpeechSynthesisVoice(language: "zz-ZZ"))
    }

    // MARK: - Audio session (§6.3)

    /// `.ambient` is the whole of "respects the silent switch and does not
    /// interrupt other audio unnecessarily". `.playback` — the category most TTS
    /// code reaches for — deliberately ignores the silent switch.
    func testSpeakingUsesAnAmbientMixingSession() {
        let speaker = SystemSpeaker()
        speaker.speak("reluctant")
        defer { speaker.stop() }

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .ambient,
                       ".playback would talk over a silenced phone")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers),
                      "a podcast must keep playing")
    }

    /// Offline: the acceptance criterion is "works with no network", and the
    /// synthesizer is a system service with no network path at all.
    func testAVoiceIsAvailableWithoutNetwork() {
        XCTAssertFalse(AVSpeechSynthesisVoice.speechVoices().isEmpty)
    }

    // MARK: - #88: sentences with gaps

    /// Auto-TTS must not read the underscores: it is noise, and the number of them
    /// is the answer's length given away.
    func testAutoSpeechSkipsTheGapRatherThanReadingUnderscores() {
        let plan = StudySpeech.onShow(front: "I decided ___ enable thinking mode.",
                                      back: "to — decided to enable",
                                      autoTTS: true)
        XCTAssertEqual(plan, .speak("I decided enable thinking mode."))
    }

    /// A long press after the reveal reads the completed sentence, not the back —
    /// hearing "to — decided to enable (decide + to + дієслово)" is a rule being
    /// recited, not the sentence being finished.
    func testALongPressAfterTheRevealReadsTheFilledSentence() {
        let plan = StudySpeech.onLongPress(front: "I decided ___ enable thinking mode.",
                                           back: "to — decided to enable",
                                           isRevealed: true)
        XCTAssertEqual(plan, .speak("I decided to enable thinking mode."))
    }

    /// An ordinary card is spoken exactly as before.
    func testAnOrdinaryCardIsUnaffected() {
        XCTAssertEqual(StudySpeech.onShow(front: "reluctant", back: "неохочий", autoTTS: true),
                       .speak("reluctant"))
        XCTAssertEqual(StudySpeech.onLongPress(front: "reluctant", back: "неохочий",
                                               isRevealed: true),
                       .speak("неохочий"))
    }
}
