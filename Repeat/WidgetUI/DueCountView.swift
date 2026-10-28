import SwiftUI
import UIKit
import WidgetKit

/// The widget's faces — the count (#26), the daily-goal ring and the streak (#111).
///
/// **Why this is not in `RepeatWidget/`.** `RepeatTests` depends on the app target
/// alone, so nothing under `RepeatWidget/` is reachable by a test in this repo:
/// that is how the freshness rule came to be written twice with nothing asserting
/// the two agreed. This directory is compiled into the app *and* the widget (and
/// deliberately not into the Share Extension, which has no use for it), so
/// `WidgetRenderTests` can host these layouts at the real widget sizes and attach
/// the images. The card's screenshot is produced by the suite rather than by a
/// person holding a simulator.
///
/// **Why the family is a parameter.** `\.widgetFamily` cannot be set from outside
/// a widget host, so a test reading it from the environment could never ask for
/// the medium layout — the very one this card adds. `DueCountEntryView` in the
/// widget reads the environment and hands the value down.
struct DueCountView: View {
    var snapshot: WidgetSnapshot
    var family: WidgetFamily

    /// The app's `Palette.accent`, restated here because `Palette` imports
    /// `Scheduling` and belongs to the app target alone. `WidgetRenderTests`
    /// resolves both in both schemes and asserts they match, so this cannot
    /// quietly drift away from the app it belongs to.
    ///
    /// Dynamic, and that is the whole point: the fixed fill green (`#1E7558`) is
    /// built to carry white text, and as a stroke on the dark widget container it
    /// falls under even the 3:1 asked of a graphical element. The first rendered
    /// pair showed it — dark mode is where one value per colour stops working,
    /// exactly as `Palette`'s own note says.
    static let ringTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 95 / 255, green: 196 / 255, blue: 155 / 255, alpha: 1)
            : UIColor(red: 30 / 255, green: 117 / 255, blue: 88 / 255, alpha: 1)
    })

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular.containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            rectangular.containerBackground(.clear, for: .widget)
        case .systemMedium:
            medium.containerBackground(.fill.tertiary, for: .widget)
        default:
            small.containerBackground(.fill.tertiary, for: .widget)
        }
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                streakBadge
            }
            countInRing(diameter: 80, lineWidth: 7, numberSize: 30)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // Packed from the top with explicit spacing rather than balanced by
        // `Spacer`s. The first cut used spacers, and the rendered image showed the
        // caption pushed clean off the bottom edge — a widget container is small
        // enough that "share out what is left" and "keep everything on screen" are
        // not the same instruction.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var medium: some View {
        HStack(spacing: 18) {
            countInRing(diameter: 96, lineWidth: 8, numberSize: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Repeat")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if snapshot.showsRing {
                    Text("\(snapshot.goalDone) з \(snapshot.goalTarget)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot.streak != nil {
                    HStack(spacing: 4) {
                        Text("Серія")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        streakBadge
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Lock screen
    //
    // Neither gains a ring. A circular complication is a canvas the size of the
    // number already in it, and a rectangular one reads as a sentence — a ring in
    // either would be decoration crowding out the thing it decorates.

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(countText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Text("картки")
                    .font(.system(size: 9))
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Repeat").font(.caption).fontWeight(.semibold)
            Text(headline).font(.headline)
            if snapshot.due != nil {
                HStack(spacing: 6) {
                    Text(subtitle).font(.caption2)
                    if snapshot.streak != nil { streakBadge }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Pieces

    /// The number, inside the goal ring when there is a goal and on its own when
    /// there is not. An empty ring beside an empty count is a scoreboard reporting
    /// that you have not started — the mistake the study screen made before #89.
    private func countInRing(diameter: CGFloat, lineWidth: CGFloat, numberSize: CGFloat) -> some View {
        ZStack {
            if snapshot.showsRing {
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: snapshot.goalProgress)
                    .stroke(Self.ringTint,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // Twelve o'clock. Filling from the right reads as an arbitrary
                    // arc rather than progress — the same reason `ProgressRing`
                    // rotates.
                    .rotationEffect(.degrees(-90))
            }
            Text(countText)
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, lineWidth * 1.5)
        }
        .frame(width: diameter, height: diameter)
    }

    private var streakBadge: some View {
        Group {
            if let streak = snapshot.streak {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                    Text(streak.formatted())
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Self.ringTint)
            }
        }
    }

    // MARK: - Copy

    private var countText: String {
        snapshot.due.map(String.init) ?? "—"
    }

    private var headline: LocalizedStringKey {
        guard let due = snapshot.due else { return "Відкрийте застосунок" }
        return due == 0 ? "На сьогодні все" : "до повторення"
    }

    private var subtitle: LocalizedStringKey {
        snapshot.isDone ? "До завтра" : "Торкніться, щоб почати"
    }

    /// Built by hand rather than left to `.combine`, so the streak is read once and
    /// the count comes through the catalogue's plural rather than a fixed
    /// "карток" — which would have said "1 карток".
    private var accessibilityLabel: String {
        var parts = ["Repeat"]
        if let due = snapshot.due {
            parts.append(due == 0
                ? String(localized: "На сьогодні все")
                : String(localized: "\(due) картка чекає на повторення"))
        } else {
            parts.append(String(localized: "Відкрийте застосунок"))
        }
        if let streak = snapshot.streak {
            parts.append(String(localized: "Серія: \(streak.formatted())"))
        }
        return parts.joined(separator: ", ")
    }
}
