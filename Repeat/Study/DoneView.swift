import SwiftUI

/// End-of-session summary (§6.3).
///
/// Was built against the mockup's `.done` screen; #89 replaced that design and
/// `docs/anki-ios-mockup.html` is now marked superseded.
struct DoneView: View {
    let summary: StudySession.Summary
    let streak: Int
    var onBackToDecks: () -> Void
    var onAddCards: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

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
                .padding(.bottom, 28)

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

            Button(action: onBackToDecks) {
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

            Button(action: onAddCards) {
                Text("Додати нові картки")
                    .scaledFont(17, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            }
            .buttonStyle(PressableButtonStyle())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
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
}
