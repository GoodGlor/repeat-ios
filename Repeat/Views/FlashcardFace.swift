import SwiftUI

/// The card itself (§6.3): front, and once revealed the answer, the example and
/// any extra Sheet columns in header order (D1).
///
/// Purely presentational, and shared with onboarding (§6.1 asks for "a real card
/// component" on the first screen). Keeping it one view is what stops the
/// onboarding illustration from drifting into a lie about what studying looks
/// like. Gestures, animation and accessibility belong to the caller, because the
/// study screen grades on a swipe and onboarding must not.
///
/// #89 reworked the surface. The complaint was accurate: one word floating in a
/// full-height white rectangle, with the deck it came from stated nowhere. Three
/// things changed — the card now carries a **deck strip** so its identity is on
/// it, the revealed answer sits in its own tinted panel instead of trailing off
/// below a hairline, and the whole thing is **elevated** so it reads as an object
/// rather than as a lighter region of the page.
struct FlashcardFace: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let front: String
    var back: String = ""
    var example: String?
    var extras: [(key: String, value: String)] = []
    /// #149: shown above the question, on both sides of the reveal — it is part
    /// of what is being asked.
    var picture: UIImage?
    var isRevealed: Bool
    /// Shown before the reveal. `nil` for a card that is not tappable.
    ///
    /// `LocalizedStringKey`, not `String` (#93): as a `String` this default was
    /// drawn verbatim, so the hint on every single card read Ukrainian in an
    /// English build — the most-seen untranslated string in the app, and invisible
    /// to the catalogue because extraction never saw it.
    var prompt: LocalizedStringKey? = "Торкнись, щоб перевірити"
    /// The deck this card came from. Optional because onboarding shows a card
    /// that belongs to no deck yet, and inventing one there would be a lie.
    var deckTitle: String?
    var deckColor: Color?
    /// A floor for the height of the card's content area — everything below the
    /// deck strip.
    ///
    /// Belongs to the card, not to the caller. The surface is drawn *inside* this
    /// view, so a `.frame(minHeight:)` applied from outside stretches the layout
    /// slot while the white rectangle stays content-sized: it pads empty space
    /// around an already-drawn card and looks like nothing happened. Which is
    /// exactly what it did look like, for one build.
    var minHeight: CGFloat?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous)
    }

    private var tint: Color { deckColor ?? Palette.accent }

    /// `nil` for an ordinary card, which is what keeps every existing card looking
    /// exactly as it does now (#88's fourth acceptance line).
    private var gap: GapCard? { GapCard(front: front, back: back) }

    var body: some View {
        VStack(spacing: 0) {
            if let deckTitle {
                deckStrip(deckTitle)
            }

            // The slack from `minHeight` is absorbed *here*, below the strip,
            // rather than by the outer stack — which would centre the strip along
            // with everything else and float the deck name into the middle of the
            // card.
            VStack(spacing: 0) {
                if let picture {
                    pictureView(picture)
                        .padding(.bottom, 20)
                }
                if let gap {
                    gapSentence(gap)
                } else {
                    Text(front)
                        .scaledFont(30, weight: .bold, relativeTo: .largeTitle)
                        .kerning(-0.6)
                        .foregroundStyle(Palette.onSurface)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isRevealed {
                    answerPanel
                        .padding(.top, 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if let prompt {
                    revealHint(prompt)
                        .padding(.top, 22)
                }
            }
            // A floor with a centre alignment, and deliberately **no `Spacer`**.
            //
            // Both of the obvious ways to centre this made the card full-height
            // again, because both are greedy and greed propagates all the way out
            // to the screen: `maxHeight: .infinity` says so outright, and a pair
            // of `Spacer`s says the same thing more quietly — a `Spacer` expands
            // to whatever height it is offered, and the parent offers everything.
            // Twice the card went straight back to being the rectangle #89 exists
            // to fix. `alignment: .center` centres without asking for space.
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
        }
        // #89: the card hugs its content.
        //
        // It used to be `maxHeight: .infinity`, which is what produced the
        // complaint the card was filed over — one word centred in a full-height
        // white rectangle, most of it carrying nothing. A card that is the size of
        // what is on it also *means* something: a one-word prompt looks small and
        // a sentence looks long, before either is read. The caller centres it in
        // whatever space is left.
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceRaised, in: shape)
        .clipShape(shape)
        // The border is what stops a white card on a near-white page from losing
        // its edge entirely at the top, where the shadow is weakest.
        .overlay(shape.strokeBorder(Palette.separator.opacity(0.7), lineWidth: 1))
        .compositingGroup()
        .elevated(.high)
    }

    // MARK: - Picture

    /// Fitted, never cropped: a picture can carry the detail the question is
    /// about, and cropping could cut it off. The height is capped so the word
    /// stays on screen with it; at the accessibility sizes the card scrolls
    /// (`StudyView`), so nothing is clipped.
    ///
    /// Decorative to VoiceOver on its own — the study screen says "з картинкою"
    /// on the card instead, because the file carries no description to read.
    ///
    /// Rounded on the picture itself, not on its frame: a wide picture is
    /// shorter than the frame, and rounding the frame left its corners square.
    /// Smaller at the accessibility sizes, where the text needs the room — at
    /// 240 the revealed answer went below the fold at AX5.
    private func pictureView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: dynamicTypeSize.isAccessibilitySize ? 140 : 240)
            .accessibilityHidden(true)
    }

    // MARK: - Deck identity

    /// A tinted bar in the deck's own colour. This is the one place the deck
    /// colour does real work: during a session §5.2 interleaves decks, so the
    /// card in front of you can change deck between one tap and the next and
    /// nothing used to say so.
    private func deckStrip(_ title: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .scaledFont(12, weight: .semibold, relativeTo: .caption)
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Palette.onSurfaceMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(tint.opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 1)
        }
        // The title is already in the caller's combined accessibility label.
        .accessibilityHidden(true)
    }

    // MARK: - A sentence with a gap (#88)

    /// The sentence, at sentence size, with the gap drawn as a gap.
    ///
    /// Two things had to change from the single-word treatment. **Size**: 30pt bold
    /// is right for "reluctant" and wrong for a sentence, which at that size wraps
    /// to four lines and reads like a headline rather than something to complete.
    /// **The gap itself**: `___` is literal text that the eye reads as punctuation.
    /// An underlined blank is a place where something is missing.
    ///
    /// Built by concatenating `Text`, not by stacking views, so the sentence wraps
    /// as one paragraph — a gap in the middle of a line stays in the middle of that
    /// line, which an `HStack` of fragments cannot do.
    private func gapSentence(_ gap: GapCard) -> some View {
        (Text(gap.before) + blank(gap) + Text(gap.after))
            .scaledFont(22, weight: .semibold, relativeTo: .title3)
            .foregroundStyle(Palette.onSurface)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Before the reveal, a blank of fixed width; after it, the answer in place.
    ///
    /// The blank is **underscores in the accent colour**, not whitespace. Figure
    /// spaces (U+2007) with an underline were the first attempt — fixed width,
    /// uncollapsible, and elegant — and they disappeared entirely for a sentence
    /// that *starts* with the gap: leading whitespace is trimmed at a line start,
    /// so the underline had nothing to sit under and the card read "is the tallest
    /// mountain in the world." with no slot at all. Any whitespace-based blank has
    /// that failure; a visible glyph cannot.
    ///
    /// So the gap keeps the shape the owner typed, and the *styling* does the work
    /// the card asked for: in the accent colour it reads as a slot to fill rather
    /// than as punctuation, and on reveal it becomes the answer in the same place.
    /// The width is fixed at four regardless of how long the answer is, which would
    /// otherwise give away its length.
    private func blank(_ gap: GapCard) -> Text {
        if isRevealed {
            return Text(gap.answer)
                .foregroundColor(Palette.accent)
                .underline(true, color: Palette.accent)
        }
        return Text("____").foregroundColor(Palette.accent)
    }

    // MARK: - The answer

    /// What the panel says: the rule for a gap card, the back for an ordinary one.
    private var answerLine: String? {
        if let gap { return gap.explanation }
        return back
    }

    @ViewBuilder
    private var answerPanel: some View {
        VStack(spacing: 8) {
            // A gap card has already shown its answer *in the sentence*, so the
            // panel carries the rule instead of repeating the word — and it is
            // omitted entirely when there is no rule to carry, rather than drawing
            // an empty line where the answer used to be.
            if let answerLine, !answerLine.isEmpty {
                Text(answerLine)
                    .scaledFont(gap == nil ? 24 : 18, weight: .semibold,
                                relativeTo: gap == nil ? .title2 : .body)
                    .foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let example, !example.isEmpty {
                Text(example)
                    .scaledFont(15, relativeTo: .subheadline)
                    .foregroundStyle(Palette.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Any Sheet column the app does not know about, in header order (D1).
            ForEach(extras, id: \.key) { extra in
                Text(extra.value)
                    .scaledFont(15, relativeTo: .subheadline)
                    .foregroundStyle(Palette.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Palette.accentSoft.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The hint became a pill, and moved.
    ///
    /// It used to be pinned to the bottom edge of a full-height card, half a
    /// screen away from the word it refers to, in grey — which read as a caption
    /// on the card rather than as the one thing to do next. Now it sits directly
    /// under the prompt, which is also the only position that survives the card
    /// hugging its content.
    private func revealHint(_ prompt: LocalizedStringKey) -> some View {
        Text(prompt)
            .scaledFont(13, weight: .medium, relativeTo: .caption)
            .foregroundStyle(Palette.onSurfaceMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Palette.surface, in: Capsule())
    }
}
