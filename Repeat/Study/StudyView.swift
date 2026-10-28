import SwiftUI
import Scheduling

/// The study screen (§6.3).
///
/// Was built against `docs/anki-ios-mockup.html`, which #89 superseded — the card,
/// the rating row and the progress indicator there no longer describe this screen.
struct StudyView: View {
    @Bindable var session: StudySession
    /// Streak is computed by the caller, which already holds the log (§6.5).
    var streak: Int = 0
    /// §5.6: computed by the caller when the session ends, shown once on Done.
    var celebration: [Celebration.Line] = []
    /// #112. Forwarded rather than defaulted, because naming a freeze needs the
    /// owner's context and this view has none.
    var markFreezeAnnounced: () -> Void = {}
    var onClose: () -> Void
    var onAddCards: () -> Void = {}

    /// Injected by tests, and by the debug launch argument that proves the
    /// screen speaks without anyone having to listen to it.
    var speaker: (any CardSpeaker)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var systemSpeaker = SystemSpeaker()
    /// §6.3's type-answer mode. Kept here rather than on the session: it is
    /// input, not scheduling state, and it must not survive an undo.
    @State private var typed = ""
    @State private var submittedAnswer: String?
    /// #149: the current card's picture, read from disk once per card rather
    /// than on every body pass — the body reruns on every frame of a swipe.
    /// Keyed by card id so a picture never shows on the card after it.
    @State private var picture: (cardId: String, image: UIImage)?
    /// §6.3 says gestures are optional and on by default; #21 wires the toggle.
    private let gesturesEnabled = true

    private var voice: any CardSpeaker { speaker ?? systemSpeaker }

    private var autoTTSForCurrentCard: Bool {
        session.current?.note.deck.autoTTS ?? false
    }

    /// Per deck, read off the card on screen — §5.2 interleaves decks, so a
    /// session spans them and the mode must not leak from one into the next.
    private var typeAnswerForCurrentCard: Bool {
        session.current?.note.deck.typeAnswer ?? false
    }

    /// What a typed answer is compared against (#88).
    ///
    /// For an ordinary card it is the back. For a sentence with a gap it is the
    /// **fragment that fills the gap** — typing `to` for
    /// `"I decided ___ enable thinking mode."` is right, and comparing it against
    /// `"to — decided to enable (decide + to + дієслово)"` marked it wrong. That
    /// was §6.3's typed mode quietly failing the one card shape #88 exists for.
    ///
    /// `AnswerDiff` is reused rather than re-implemented: it already normalises
    /// case and whitespace and deliberately does not fold diacritics, and a second
    /// comparison would be a second set of those decisions to keep in step.
    private func expectedAnswer(for card: Card) -> String {
        GapCard(front: card.note.front, back: card.note.back)?.answer ?? card.note.back
    }

    /// #88: VoiceOver reads the gap the way the speaker does, rather than saying
    /// "underscore underscore underscore" — which is both noise and a letter count
    /// the sighted reader does not get.
    private func spokenFront(_ card: Card) -> String {
        StudySpeech.spokenFront(front: card.note.front, back: card.note.back)
    }

    private var answerDiff: [AnswerDiff.Segment]? {
        guard let submittedAnswer, let card = session.current else { return nil }
        return AnswerDiff.compare(typed: submittedAnswer, expected: expectedAnswer(for: card))
    }

    private var answerWasCorrect: Bool {
        guard let submittedAnswer, let card = session.current else { return false }
        return AnswerDiff.isCorrect(typed: submittedAnswer, expected: expectedAnswer(for: card))
    }

    private func submitTypedAnswer() {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submittedAnswer = typed
        session.reveal()
    }

    /// #89: grading and undo move the card instead of swapping it.
    ///
    /// One place rather than at each call site — the rating row, the swipe and
    /// the shake all end here, so they cannot animate differently from one
    /// another. `reduceMotion` collapses all three to an instant change.
    private var cardMotion: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private func submit(_ grade: Grade) {
        withAnimation(cardMotion) { session.rate(grade) }
    }

    private func undo() {
        // `undo` reports whether there was anything to take back; the shake
        // gesture calls it unconditionally, so the answer is genuinely unused
        // here rather than accidentally dropped.
        _ = withAnimation(cardMotion) { session.undo() }
    }

    private func play(_ plan: StudySpeech.Plan) {
        switch plan {
        case .silent: voice.stop()
        case let .speak(text): voice.speak(text)
        }
    }

    var body: some View {
        if let summary = session.summary {
            DoneView(
                summary: summary,
                streak: streak,
                celebration: celebration,
                markFreezeAnnounced: markFreezeAnnounced,
                onBackToDecks: onClose,
                onAddCards: onAddCards
            )
            // Undo stays reachable from the Done screen: the last card of a
            // session is the one most likely to be misgraded (§5.5).
            .onShake { undo() }
        } else {
            sessionBody
        }
    }

    private var sessionBody: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.bottom, 22)

            if let card = session.current {
                // The card is centred in what is left rather than stretched to
                // fill it (#89) — see `FlashcardFace` for why — and it scrolls
                // when it cannot fit.
                //
                // Both halves are needed. A content-sized card that is merely
                // centred gets **clipped** at the largest Dynamic Type sizes: at
                // AX5 the answer panel ran past the card's own rounded edge and
                // the pronunciation was simply cut off, which is worse than the
                // full-height rectangle this replaced. The `minHeight` frame is
                // applied *outside* the card, so it pads and centres without
                // stretching the surface, and `.basedOnSize` means there is no
                // scrolling to fight the swipe gesture until there is genuinely
                // something to scroll.
                GeometryReader { geometry in
                    ScrollView {
                        cardFace(card)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: .infinity)
                // #89: keyed on the card, so grading *replaces* the card rather
                // than rewriting the text inside a rectangle that never moves.
                // Without the id SwiftUI reuses the same view and there is
                // nothing to transition.
                .id(card.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
                .padding(.bottom, 14)
                if typeAnswerForCurrentCard {
                    TypeAnswerField(
                        typed: $typed,
                        diff: answerDiff,
                        isCorrect: answerWasCorrect,
                        onSubmit: submitTypedAnswer
                    )
                    .padding(.bottom, 12)
                }
                ratingRow
                    // No fixed height: #37 made these labels scale with Dynamic
                    // Type, and 68pt clipped the third line at XXL. The row still
                    // reserves its space while hidden, so revealing an answer does
                    // not shift the card.
                    .opacity(session.isRevealed ? 1 : 0)
                    // Hidden from touch *and* from VoiceOver until revealed, so the
                    // buttons cannot be reached before the answer has been seen.
                    .allowsHitTesting(session.isRevealed)
                    .accessibilityHidden(!session.isRevealed)
            } else if let waitingUntil = session.waitingUntil {
                waitingState(until: waitingUntil)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
        .background(Palette.surface.ignoresSafeArea())
        .onShake { undo() }
        // §6.3's "speak front on show". Keyed on the card's id so it fires once
        // per card — including for the first one, which `onChange` alone would
        // miss.
        .task(id: session.current?.id) {
            typed = ""
            submittedAnswer = nil
            loadPicture(for: session.current)
            play(StudySpeech.onShow(card: session.current))
        }
        // An undo puts an already-graded card back in front of the person, and
        // it has to arrive as a question again rather than as last time's diff.
        .onChange(of: session.isRevealed) { _, revealed in
            if !revealed {
                typed = ""
                submittedAnswer = nil
            }
        }
        // "Toggling auto-TTS off silences the deck immediately": not at the end
        // of the sentence, and not on the next card.
        .onChange(of: autoTTSForCurrentCard) { _, enabled in
            if !enabled { voice.stop() }
        }
        // Leaving the session mid-word and hearing the rest of it from the deck
        // list is the kind of thing that gets an app deleted.
        .onDisappear { voice.stop() }
        #if DEBUG
        // Drives a submission without a keystroke, so the diff renders the same
        // way every time a screenshot is taken.
        .task(id: session.current?.id) {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-typeAnswerTextOnLaunch"),
                  index + 1 < arguments.count else { return }
            typed = arguments[index + 1]
            submitTypedAnswer()
        }
        #endif
    }

    // MARK: - Top bar

    /// #89 replaced the hairline capsule with a ring.
    ///
    /// The capsule was 5pt of `line` spanning the width, and at a glance it was
    /// indistinguishable from a divider — the one piece of feedback saying "you
    /// are getting somewhere" was the faintest thing on the screen. The ring is
    /// the same information at the same size, but it is a shape rather than a
    /// rule, and it leaves the horizontal space for the streak.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    // Fixed, like the Done screen's checkmark and for the same
                    // reason: a glyph inside a circle of fixed diameter cannot
                    // scale with Dynamic Type without growing through the edge —
                    // at AX5 the undo arrow did exactly that and spilled across
                    // the counter beside it. The *button* is 44pt, which is the
                    // minimum tap target and what accessibility actually needs
                    // here; the old 34 was under it.
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.onSurfaceMuted)
                    .frame(width: 44, height: 44)
                    .background(Palette.surfaceRaised, in: Circle())
                    .elevated(.low)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрити")

            ProgressRing(progress: session.progress, lineWidth: 4)
                .frame(width: 30, height: 30)

            Text("\(session.position) / \(session.total)")
                .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                .monospacedDigit()
                // At AX5 this grew until it ran underneath the undo button. The
                // counter is the least important thing in the bar and the only one
                // that can shrink without becoming unusable — a control cannot.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Palette.onSurface)
                .accessibilityLabel("Картка \(session.position) з \(session.total)")

            Spacer(minLength: 0)

            StreakChip(days: streak, isCompact: true)

            // §6.3: top-right, enabled once there is something to take back.
            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(session.canUndo ? Palette.onSurfaceMuted : Palette.separator)
                    .frame(width: 44, height: 44)
                    .background(Palette.surfaceRaised, in: Circle())
                    .elevated(.low)
                    .opacity(session.canUndo ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .disabled(!session.canUndo)
            .accessibilityLabel("Скасувати останню оцінку")
        }
    }

    // MARK: - Card

    /// A missing file means no picture yet (not synced, or the link failed):
    /// the card shows without one.
    private func loadPicture(for card: Card?) {
        guard let card,
              let file = (try? PictureStore.standard())?.existingFile(for: card.note.extras),
              let image = UIImage(contentsOfFile: file.path)
        else { picture = nil; return }
        picture = (card.id, image)
    }

    private func cardFace(_ card: Card) -> some View {
        // The card itself is `FlashcardFace`, shared with onboarding (§6.1). Only
        // the interaction lives here: onboarding shows the same card and must not
        // be able to grade it.
        FlashcardFace(
            front: card.note.front,
            back: card.note.back,
            example: card.note.example,
            extras: card.note.displayExtras,
            picture: picture?.cardId == card.id ? picture?.image : nil,
            isRevealed: session.isRevealed,
            // The hint has to describe the interaction that is actually there.
            prompt: typeAnswerForCurrentCard ? nil : "Торкнись, щоб перевірити",
            // §5.2 interleaves decks, so the deck can change between one tap and
            // the next. Until #89 nothing on the screen said which one you were in.
            deckTitle: card.note.deck.sheetTitle,
            deckColor: Color(hex: card.note.deck.colorHex),
            // A floor, not a fill. Hugging alone went too far the other way: a
            // one-word card shrank to a business card adrift in more empty space
            // than the full-height version it replaced. 340 is about half of what
            // is left after the bar and the rating row, so the card is
            // unmistakably the subject of the screen while still growing for a
            // sentence. In type-answer mode the keyboard takes most of the screen,
            // so the floor drops to what keeps the question readable.
            minHeight: typeAnswerForCurrentCard ? 180 : 340
        )
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .offset(x: dragOffset.width)
        // A card that tilts as it is pushed is the difference between dragging an
        // object and sliding a rectangle. Divided by 22 so a full swipe reaches
        // about 5° — enough to feel physical, not enough to look broken.
        .rotationEffect(.degrees(reduceMotion ? 0 : dragOffset.width / 22))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.isRevealed)
        // §6.3: "text field replaces the reveal interaction". Tapping past the
        // question would make the typing optional, which is the whole mode.
        .onTapGesture { if !typeAnswerForCurrentCard { session.reveal() } }
        // Before the swipe gesture, so a long press is not swallowed by the drag
        // recogniser's minimum distance.
        .onLongPressGesture(minimumDuration: 0.45) {
            let plan = StudySpeech.onLongPress(card: card, isRevealed: session.isRevealed)
            // Hearing the card is not the same as answering it: in type-answer
            // mode the long press speaks and nothing more.
            if !typeAnswerForCurrentCard { session.reveal() }
            play(plan)
        }
        .gesture(swipeGesture)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            session.isRevealed
            ? Localized.string("\(spokenFront(card)). Відповідь: \(card.note.back)")
            : spokenFront(card)
        )
        .accessibilityValue(picture?.cardId == card.id ? Localized.string("з картинкою") : "")
        .accessibilityHint(session.isRevealed ? "" : "Торкніться, щоб побачити відповідь")
        // Only a button when tapping it actually does something. In type-answer
        // mode the card is read, not activated — the text field is the control —
        // and claiming otherwise sends VoiceOver users to a dead end.
        .accessibilityIdentifier("study.card")
        .accessibilityAddTraits(revealsOnTap ? .isButton : .isStaticText)
        // `.onTapGesture` is a gesture, not an action: VoiceOver's double-tap has
        // nothing to invoke unless the activation is declared. Without this the
        // card can be *read* under VoiceOver but never turned over, which is the
        // whole session.
        .accessibilityAction {
            guard revealsOnTap else { return }
            session.reveal()
        }
    }

    /// "Добре, три дні" — the name and the interval in one phrase (§8).
    ///
    /// Static so it can be tested without a session. A missing preview drops the
    /// interval rather than reading a trailing comma into silence, which is what
    /// the previous inline version did before the first preview arrived.
    static func ratingLabel(grade: Grade, preview: GradePreview?) -> String {
        guard let spoken = preview?.spokenLabel, !spoken.isEmpty else { return grade.title }
        return "\(grade.title), \(spoken)"
    }

    /// Tapping the card reveals it only outside type-answer mode (§6.3).
    private var revealsOnTap: Bool { !typeAnswerForCurrentCard && !session.isRevealed }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard gesturesEnabled, session.isRevealed else { return }
                dragOffset = CGSize(width: value.translation.width / 3, height: 0)
            }
            .onEnded { value in
                defer { withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { dragOffset = .zero } }
                guard gesturesEnabled else { return }

                // Before reveal, only an upward swipe does anything — a horizontal
                // swipe must never grade a card that has not been seen.
                if !session.isRevealed {
                    if value.translation.height < -40, !typeAnswerForCurrentCard { session.reveal() }
                    return
                }
                if value.translation.width < -60 { submit(.again) }
                else if value.translation.width > 60 { submit(.good) }
            }
    }

    // MARK: - Ratings

    /// #89: four solid buttons instead of four pale chips.
    ///
    /// These are the only controls a session touches, and they were the weakest
    /// thing on the screen — `tint` on a near-white `…Soft` fill, which reads as
    /// four disabled controls. Now the colour is the button and the label sits on
    /// it in white, measured at 5.6:1 or better (`AccessibilityTests`).
    ///
    /// The glyph is redundant with the word on purpose. Grading happens in under
    /// a second, dozens of times a day, and a shape is recognised faster than a
    /// word is read — but the word stays, because an icon-only rating row is a
    /// memory test about the app instead of about the card.
    private var ratingRow: some View {
        HStack(spacing: 8) {
            ForEach(Grade.allCases, id: \.self) { grade in
                Button {
                    submit(grade)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: grade.symbolName)
                            .scaledFont(15, weight: .bold, relativeTo: .subheadline)
                            .frame(height: 18)
                        Text(grade.title)
                            .scaledFont(14, weight: .semibold, relativeTo: .subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(session.previews[grade]?.label ?? "—")
                            .scaledFont(12, weight: .medium, relativeTo: .caption)
                            .monospacedDigit()
                            // "24.3 міс." is the widest label; at the larger
                            // Dynamic Type sizes it must shrink, not wrap.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(grade.onFill)
                    .background(grade.fill,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .elevated(.low)
                }
                .buttonStyle(PressableButtonStyle())
                // §8: VoiceOver reads the interval as part of the button.
                .accessibilityLabel(Self.ratingLabel(grade: grade,
                                                     preview: session.previews[grade]))
                .accessibilityIdentifier("study.rate.\(grade)")
            }
        }
    }

    // MARK: - Waiting on a learning step

    private func waitingState(until date: Date) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Ще трохи")
                .scaledFont(22, weight: .bold, relativeTo: .title2)
                .foregroundStyle(Palette.onSurface)
            Text("Наступна картка \(date, style: .timer)")
                .scaledFont(15, relativeTo: .subheadline)
                .foregroundStyle(Palette.onSurfaceMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Poll rather than schedule: the wait is short and bounded by the
            // learning step, and this survives the app being backgrounded.
            while session.current == nil && session.summary == nil {
                try? await Task.sleep(for: .seconds(1))
                session.refresh()
            }
        }
    }
}
