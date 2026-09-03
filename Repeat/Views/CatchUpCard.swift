import SwiftUI

/// §5.3's offer on Home.
///
/// Presentational only: whether there is a backlog is `CatchUp.offer`'s decision,
/// and it is made from the queue rather than from a stored "dismissed" flag —
/// which is how the offer disappears the moment the backlog clears.
struct CatchUpCard: View {
    let offer: CatchUp.Offer
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Накопичилось", systemImage: "tray.full")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.hard)

            Text(Localized.string("Сьогодні \(offer.dueReviews) повторень — це набагато більше за звичайні \(Int(offer.dailyAverage.rounded())) на день."))
                .font(.subheadline)
                .foregroundStyle(Palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onAccept()
            } label: {
                Text("Розтягнути на 3 дні")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Palette.hardSoft, in: .rect(cornerRadius: 12))
                    .foregroundStyle(Palette.hard)
            }
            .buttonStyle(PressableButtonStyle())

            // The consequence, before the tap rather than after it: this moves
            // real due dates, and someone should know how much before agreeing.
            Text("Сьогодні залишиться \(offer.remaining). Решта \(offer.moving) переїде на завтра й післязавтра — почнемо з тих, що ти памʼятаєш найкраще.")
                .font(.caption)
                .foregroundStyle(Palette.onSurfaceMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Palette.radius))
        .elevated(.low)
    }
}
