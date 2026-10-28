import SwiftUI

/// End-of-session summary (§6.3).
///
/// Was built against the mockup's `.done` screen; #89 replaced that design and
/// `docs/anki-ios-mockup.html` is now marked superseded.
struct DoneView: View {
    let summary: StudySession.Summary
    let streak: Int
    /// §5.6: what this session adds, at most three lines — see `Celebration`.
    /// Empty is the ordinary evening; the screen is unchanged.
    var celebration: [Celebration.Line] = []
    /// The Done screen is the surface that *shows* a badge, so it is the one
    /// that writes the ledger (#107 ruling 6) — at the moment the screen is
    /// **left** by a button, not when it appears; see `leave`. Injected so a
    /// preview or test can stub it; production passes the real ledger.
    var markShown: ([Achievements.Badge]) -> Void = { AchievementLedger().markShown($0) }
    /// #112, and the same contract as `markShown`: a freeze is named once, and
    /// the naming is recorded at the moment the screen is left.
    var markFreezeAnnounced: () -> Void = {}
    var onBackToDecks: () -> Void
    var onAddCards: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var celebrationAppeared = false

    var body: some View {
        // §5.6: three celebration lines on top of the medal, the title, the
        // stats and two buttons do not always fit — measured at AX5, the screen
        // wanted about half as much height again as it had, and "До колод" left
        // it. So the top half scrolls and the buttons stay put.
        //
        // The choice is made by *fit*, not by `isAccessibilitySize`: a quiet
        // evening at AX1–AX3 still fits, and a size test would have taken #89's
        // centred screen away from it and left a void under the buttons. Whether
        // the content overflows is the actual question, and `ViewThatFits`
        // asks it — the same two layouts, no duplicated content.
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                summaryBody
                buttons
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                ScrollView { summaryBody }
                buttons
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
        // While these tiles are on screen this screen owns their celebration and
        // their undo, so nothing else may announce them — see `OnScreenBadges`.
        // Cleared on *disappearance* rather than in `leave`, because a shake
        // undoes the last rating and takes this screen away without a button.
        .onAppear { OnScreenBadges.show(shownBadges) }
        .onDisappear { OnScreenBadges.clear() }
    }

    /// The badges this screen's tiles are showing — the same `.badges` lines
    /// `leave` writes to the ledger.
    private var shownBadges: [Achievements.Badge] {
        var all: [Achievements.Badge] = []
        for case let .badges(badges) in celebration { all += badges }
        return all
    }

    /// Everything above the two buttons.
    private var summaryBody: some View {
        VStack(spacing: 0) {
            // #89: a filled medal rather than a pale disc. This is the one moment
            // in the app worth celebrating, and it was rendered in the same
            // washed-out green as a badge.
            ZStack {
                Circle()
                    .fill(Palette.accentSoft)
                    .frame(width: 116, height: 116)
                Circle()
                    .fill(LinearGradient(colors: [Palette.accentFill, Palette.accentFillDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 92, height: 92)
                    .elevated(.medium)
                Image(systemName: "checkmark")
                    // Deliberately NOT scaled: it is decorative (and
                    // `accessibilityHidden`) inside a fixed circle, so growing it
                    // with Dynamic Type would only push the glyph through the edge.
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 116, height: 116)
            .padding(.bottom, 22)
            .accessibilityHidden(true)

            Text("На сьогодні все")
                .accessibilityIdentifier("done.title")
                .scaledFont(30, weight: .bold, relativeTo: .largeTitle)
                .kerning(-0.6)
                .foregroundStyle(Palette.onSurface)
                .padding(.bottom, 8)

            Text("Наступні картки зʼявляться завтра вранці.")
                .scaledFont(16, relativeTo: .body)
                .foregroundStyle(Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, celebration.isEmpty ? 28 : 12)

            if !celebration.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(celebration.enumerated()), id: \.offset) { _, line in
                        celebrationLine(line)
                    }
                }
                .padding(.bottom, 28)
                // §5.6: one subtle scale-in, no sound. Reduce Motion gets the
                // lines in place with no animation at all.
                .scaleEffect(celebrationAppeared || reduceMotion ? 1 : 0.92)
                .opacity(celebrationAppeared || reduceMotion ? 1 : 0)
                .onAppear {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) {
                        celebrationAppeared = true
                    }
                }
                // Deliberately *no* identifier on this stack: an identifier on a
                // plain container overrides the ones its lines carry, and the UI
                // snapshot showed `done.goal` and `done.record` renamed to it.
            }

            HStack(spacing: 8) {
                stat(summary.reviewed, Localized.string("повторено"),
                     "rectangle.on.rectangle", Palette.accent)
                stat(summary.forgotten, Localized.string("забуто"),
                     "arrow.counterclockwise", Palette.again)
                // Xcode rejects a plural variation whose value omits the count
                // ("Plural variation requires referencing the number"), and a bare
                // numeral over the caption "днів поспіль" reads "1 днів поспіль".
                // So the inflected unit goes in the value — reusing the tested
                // `dayCount` plural — and the caption names the metric, the way
                // the Stats screen already labels this same number.
                stat(StatsSummary.dayCount(streak), Localized.string("серія"),
                     "flame.fill", Palette.streak)
            }
            .padding(.bottom, 28)
        }
    }

    /// The one moment the ledger is written: the user has seen the screen and is
    /// leaving it by a button. Not on appearance — undo is still reachable there
    /// (§5.5), and a badge the undo takes back must not be in the ledger. A
    /// force-quit on this screen re-celebrates once; the ledger's contract
    /// allows exactly that. Waiting here is safe against the background refresh
    /// too: `OnScreenBadges` keeps the notification off the badges this screen
    /// is holding open.
    private func leave(_ action: () -> Void) {
        for case let .badges(badges) in celebration { markShown(badges) }
        if celebration.contains(.freezeSpent) { markFreezeAnnounced() }
        action()
    }

    private var buttons: some View {
        VStack(spacing: 0) {
            Button { leave(onBackToDecks) } label: {
                Text("До колод")
                    .scaledFont(17, weight: .semibold, relativeTo: .body)
                    .frame(maxWidth: .infinity)
                    .padding(17)
                    .background(
                        LinearGradient(colors: [Palette.accentFill, Palette.accentFillDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .elevated(.medium)
            }
            .buttonStyle(PressableButtonStyle())

            Button { leave(onAddCards) } label: {
                Text("Додати нові картки")
                    .scaledFont(17, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    @ViewBuilder
    private func celebrationLine(_ line: Celebration.Line) -> some View {
        switch line {
        case .freezeSpent:
            capsule(symbol: "snowflake", text: Localized.string("Серію збережено — використано заморозку"),
                    tint: Palette.easy, ground: Palette.accentSoft)
                .accessibilityIdentifier("done.freeze")
        case let .levelGained(level):
            capsule(symbol: "chevron.up.circle.fill",
                    text: Localized.string("Новий рівень: \(level)"),
                    tint: Palette.accent, ground: Palette.accentSoft)
                .accessibilityIdentifier("done.level")
        case .goalClosed:
            capsule(symbol: "target", text: Localized.string("Ціль дня виконано"),
                    tint: Palette.accent, ground: Palette.accentSoft)
                .accessibilityIdentifier("done.goal")
        case let .record(kind):
            capsule(symbol: "trophy.fill", text: Self.recordLine(kind),
                    tint: Palette.streak, ground: Palette.streakSoft)
                .accessibilityIdentifier("done.record")
        case let .badges(badges):
            badgeTiles(Celebration.tiles(badges))
                // `.contain` makes the row an element of its own, which is what
                // lets it carry a name: an identifier on a plain stack is handed
                // down to every tile instead, and `done.badge.<badge>` was gone
                // from the tree (measured, at AX5, where the stack is not a grid).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("done.badges")
        }
    }

    /// Tiles wrap into as many rows as the size needs.
    ///
    /// An accessibility size gets one per row in a plain stack, for two measured
    /// reasons: an adaptive grid still fits *two* columns at AX5, where a
    /// two-word title breaks a syllable to a line; and a `LazyVGrid` this far
    /// down a screen that scrolls never builds the rows below the fold, so the
    /// tiles were not in the accessibility tree at all.
    @ViewBuilder
    private func badgeTiles(_ split: (shown: [Achievements.Badge], more: Int)) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 8) { tileRow(split) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                tileRow(split)
            }
        }
    }

    @ViewBuilder
    private func tileRow(_ split: (shown: [Achievements.Badge], more: Int)) -> some View {
        ForEach(split.shown) { badge in
            BadgeTile(badge: badge, earnedOn: .now, style: .compact, identifierPrefix: "done.badge")
        }
        if split.more > 0 {
            Text(Localized.string("+\(split.more)"))
                .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(Palette.streak)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.streakSoft, in: Capsule())
                .accessibilityIdentifier("done.badges.more")
        }
    }

    /// The record capsule's shape, now shared with the goal line.
    private func capsule(symbol: String, text: String, tint: Color, ground: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .scaledFont(13, weight: .semibold, relativeTo: .caption)
                .accessibilityHidden(true)
            Text(text)
                .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                .multilineTextAlignment(.center)
                // No `lineLimit`: at AX5 two lines truncated "Нова найдовша
                // серія — 4 дні" to an ellipsis. The capsule grows instead, and
                // at an accessibility size the screen it sits on scrolls.
                .fixedSize(horizontal: false, vertical: true)
        }
        // Content on a fixed surface is fixed to it (gotcha 29): both tokens
        // are dynamic, both measured in both schemes.
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ground, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: Int, _ caption: String, _ symbol: String, _ tint: Color) -> some View {
        stat("\(value)", caption, symbol, tint)
    }

    /// #89 gave each tile its symbol and its own colour.
    ///
    /// Three identical white tiles holding three unrelated numbers made the
    /// summary read as one figure repeated. Colour separates "how much" from
    /// "how much you got wrong" from "how long you have kept it up".
    private func stat(_ value: String, _ caption: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .scaledFont(13, weight: .bold, relativeTo: .caption)
                .foregroundStyle(tint)
            Text(value)
                .scaledFont(22, weight: .bold, relativeTo: .title2)
                .kerning(-0.4)
                .foregroundStyle(Palette.onSurface)
            Text(caption)
                .scaledFont(12, relativeTo: .caption)
                .foregroundStyle(Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .elevated(.low)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
    }

    /// "Нова найдовша серія — 12 днів". Static so the copy can be tested without
    /// a session; the unit goes through Stats' plural helpers so the two screens
    /// inflect it the same way.
    static func recordLine(_ kind: Records.Kind, locale: Locale = .current) -> String {
        switch kind {
        case let .longestStreak(days):
            Localized.string("Нова найдовша серія — \(StatsSummary.dayCount(days, locale: locale))",
                             locale: locale)
        case let .bestDay(cards):
            Localized.string("Новий найкращий день — \(StatsSummary.cardCount(cards, locale: locale))",
                             locale: locale)
        case let .bestWeek(cards):
            Localized.string("Новий найкращий тиждень — \(StatsSummary.cardCount(cards, locale: locale))",
                             locale: locale)
        }
    }
}
