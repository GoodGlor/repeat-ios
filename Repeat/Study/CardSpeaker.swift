import Foundation
import AVFoundation
import NaturalLanguage

/// Speaking a card out loud (§6.3).
///
/// A protocol because the study screen must be testable without audio: an
/// `AVSpeechSynthesizer` in a unit test either says nothing useful or blocks on
/// a device that has no output.
@MainActor
protocol CardSpeaker: AnyObject {
    func speak(_ text: String)
    /// Stops immediately, mid-word. Used when the card changes and when the deck
    /// stops asking to be spoken — "toggling auto-TTS off silences the deck
    /// immediately" is not satisfied by waiting for the sentence to finish.
    func stop()
}

/// `AVSpeechSynthesizer`, entirely offline (§6.3's acceptance: "works with no
/// network").
@MainActor
final class SystemSpeaker: CardSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionConfigured = false

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configureSessionIfNeeded()
        // A second tap replaces the first rather than queueing behind it.
        stop()

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice = SpeechVoice.voice(for: trimmed) { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// `.ambient` is the whole of §6.3's "respects the silent switch and does not
    /// interrupt other audio unnecessarily":
    ///
    /// - `.ambient` is silenced by the ring/silent switch. `.playback` — the
    ///   category most TTS code reaches for — deliberately ignores it, which
    ///   would make a silenced phone talk on the bus.
    /// - `.ambient` mixes rather than interrupts, so a podcast keeps playing.
    ///
    /// Configured once and never deactivated: deactivating a session is itself an
    /// interruption for whatever else is playing.
    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

/// Picking a voice that can actually pronounce the text.
///
/// A vocabulary card is bilingual by construction — an English prompt and a
/// Ukrainian answer — so a single fixed voice reads one side of every card as
/// gibberish. The language is detected from the text rather than stored on the
/// deck: decks are worksheets, and the spec never gives them a language.
enum SpeechVoice {
    /// Below this, the recogniser is guessing. Short strings are exactly the case
    /// — "run" is a word in several languages — and guessing wrong is worse than
    /// falling back to the device's own voice.
    static let minimumConfidence = 0.55

    static func languageCode(for text: String, fallback: String? = nil) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
              confidence >= minimumConfidence
        else { return fallback }
        return language.rawValue
    }

    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard let code = languageCode(for: text) else { return nil }
        // `AVSpeechSynthesisVoice(language:)` accepts a bare code and resolves it
        // to a region ("en" → "en-US"). It returns nil for a language the device
        // has no voice for, and nil means "the system default", which is the
        // right fallback rather than an error.
        return AVSpeechSynthesisVoice(language: code)
    }
}
