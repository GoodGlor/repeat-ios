import SwiftUI

/// A ring showing how far through something you are (#89).
///
/// Replaces the hairline capsule at the top of the study screen and gives Home's
/// hero a shape instead of a bare numeral. A ring rather than a bar because it
/// holds its own label: the number and the progress occupy one piece of the
/// layout instead of two, which is what buys back the empty half-screen the card
/// complains about.
///
/// Decorative by default — `accessibilityHidden` — because in both places it sits
/// beside text that already states the same figure. Duplicating it in VoiceOver
/// would make every screen say the count twice.
struct ProgressRing<Label: View>: View {
    /// 0…1. Clamped, because a plan that grows mid-session (an undo, a sync) can
    /// briefly hand this a value outside the range and a ring that overdraws
    /// itself looks like a bug.
    var progress: Double
    var lineWidth: CGFloat = 6
    var tint: Color = Palette.accent
    var track: Color = Palette.separator
    @ViewBuilder var label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at twelve o'clock. Without this the ring fills from the
                // right, which reads as an arbitrary arc rather than progress.
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: clamped)

            label()
        }
        .accessibilityHidden(true)
    }
}

extension ProgressRing where Label == EmptyView {
    init(progress: Double,
         lineWidth: CGFloat = 6,
         tint: Color = Palette.accent,
         track: Color = Palette.separator) {
        self.init(progress: progress, lineWidth: lineWidth, tint: tint, track: track) {
            EmptyView()
        }
    }
}
