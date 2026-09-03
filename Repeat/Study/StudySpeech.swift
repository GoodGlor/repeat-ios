import Foundation

/// When the study screen speaks, and what (§6.3).
///
/// Rules rather than calls, so they can be tested without audio and without a
/// running session. Every path into the speaker goes through one of these, which
/// is what makes "the deck is silent when the toggle is off" a property of the
/// code rather than of a particular view.
enum StudySpeech {
    enum Plan: Equatable {
        case silent
        case speak(String)

        var text: String? {
            if case let .speak(text) = self { return text }
            return nil
        }
    }

    /// Auto-TTS: §6.3 says "speak `front` on show", so the answer is never spoken
    /// automatically — hearing it before trying to recall it defeats the point of
    /// the card.
    static func onShow(front: String, back: String = "", autoTTS: Bool) -> Plan {
        guard autoTTS else { return .silent }
        return plan(spokenFront(front: front, back: back))
    }

    /// #88: a sentence with a gap is read with the gap **skipped**.
    ///
    /// "I decided underscore underscore underscore enable thinking mode" is noise,
    /// and it also hands over the answer's length as a letter count. Reading the
    /// gap as a pause was the alternative — a comma produces one — but a comma
    /// moves where the sentence breaks, and the card allows skipping outright.
    static func spokenFront(front: String, back: String) -> String {
        GapCard(front: front, back: back)?.spoken(isRevealed: false) ?? front
    }

    /// §6.3's gesture list: "long-press reveal = play TTS". A long press is the
    /// spoken variant of the reveal, so it reveals *and* speaks — and unlike
    /// auto-TTS it works on any deck, because the person asked for it explicitly.
    ///
    /// Which side: whatever the press is about to show them. Before the reveal
    /// that is the prompt they are trying to recall; after it, the answer they
    /// are checking.
    static func onLongPress(front: String, back: String, isRevealed: Bool) -> Plan {
        // A gap card's answer is the *filled sentence*, not the back — hearing
        // "to — decided to enable (decide + to + дієслово)" read aloud is a rule
        // being recited, not the sentence being completed.
        if let gap = GapCard(front: front, back: back) {
            return plan(gap.spoken(isRevealed: isRevealed))
        }
        return plan(isRevealed ? back : front)
    }

    /// The same rule, for the card actually on screen.
    ///
    /// The deck is read off the card rather than captured when the session
    /// started: a session can span decks (§5.2 interleaves them), and the toggle
    /// has to follow the card, not the session.
    static func onShow(card: Card?) -> Plan {
        guard let card else { return .silent }
        return onShow(front: card.note.front, back: card.note.back,
                      autoTTS: card.note.deck.autoTTS)
    }

    /// Long press, for the card on screen. No deck toggle: the press *is* the
    /// request.
    static func onLongPress(card: Card?, isRevealed: Bool) -> Plan {
        guard let card else { return .silent }
        return onLongPress(front: card.note.front, back: card.note.back, isRevealed: isRevealed)
    }

    private static func plan(_ text: String) -> Plan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .silent : .speak(trimmed)
    }
}
