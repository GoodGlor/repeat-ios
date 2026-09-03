import SwiftUI

/// The streak, shown where it is earned (#89).
///
/// It already existed on Stats and on the Done screen, which are the two places
/// you look *after* the work. Putting it on Home and in the session's top bar is
/// most of what fills the empty space the card complains about — and unlike a
/// decorative filler it is a real number that changes.
///
/// Hidden entirely below two days. "1 day streak" on the first session is not an
/// achievement, and a chip that appears once the streak is worth keeping is a
/// better moment than one that starts at zero.
struct StreakChip: View {
    let days: Int
    /// The session's top bar is dark-on-light but tight; Home has room for the
    /// count spelled out.
    var isCompact = false

    static func isWorthShowing(_ days: Int) -> Bool { days >= 2 }

    var body: some View {
        if Self.isWorthShowing(days) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .scaledFont(isCompact ? 11 : 13, weight: .semibold, relativeTo: .caption)
                Text(isCompact ? "\(days)" : StatsSummary.dayCount(days))
                    .scaledFont(isCompact ? 12 : 14, weight: .semibold, relativeTo: .caption)
                    .monospacedDigit()
            }
            .foregroundStyle(Palette.streak)
            .padding(.horizontal, isCompact ? 8 : 11)
            .padding(.vertical, isCompact ? 4 : 6)
            .background(Palette.streakSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Localized.string("Серія: \(StatsSummary.dayCount(days))"))
            .accessibilityIdentifier("streak.chip")
        }
    }
}
