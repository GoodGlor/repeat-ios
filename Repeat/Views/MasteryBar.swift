import SwiftUI

/// §5.3's three segments — known ▮ learning ▮ new — as one thin capsule.
///
/// Three shades of the accent, known darkest, and no legend: the row's
/// accessibility label carries the numbers, and Home stays quiet (§2.2).
/// Hidden from VoiceOver as its own element for the same reason `Heatmap`'s
/// cells are — the row is read once, as a sentence.
struct MasteryBar: View {
    let counts: Mastery.Counts

    var body: some View {
        GeometryReader { geometry in
            let total = CGFloat(max(1, counts.total))
            let width = geometry.size.width
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: width * CGFloat(counts.known) / total)
                Rectangle()
                    .fill(Palette.accent.opacity(0.4))
                    .frame(width: width * CGFloat(counts.learning) / total)
                Rectangle()
                    .fill(Palette.line)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
