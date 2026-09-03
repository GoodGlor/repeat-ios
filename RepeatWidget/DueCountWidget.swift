import WidgetKit
import SwiftUI

/// §7.1: due count on the lock screen and home screen, one tap into the session.
struct DueEntry: TimelineEntry {
    let date: Date
    let count: DueCount?

    /// A count computed for another day is not a small error — it is the wrong
    /// number. The widget says nothing rather than something false.
    var due: Int? {
        guard let count, count.isFresh(on: date) else { return nil }
        return count.due
    }
}

struct DueCountProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry {
        DueEntry(date: .now, count: DueCount(due: 12, day: Calendar.current.startOfDay(for: .now)))
    }

    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) {
        completion(DueEntry(date: .now, count: DueCount.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        let now = Date.now
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        // Two entries: today's count, and a midnight entry that reads as stale
        // until the app or a background refresh publishes the new day's number.
        let entries = [
            DueEntry(date: now, count: DueCount.read()),
            DueEntry(date: midnight, count: DueCount.read()),
        ]
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

struct DueCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DueCount", provider: DueCountProvider()) { entry in
            DueCountView(entry: entry)
                .widgetURL(URL(string: DeepLink.study))
        }
        .configurationDisplayName("Repeat")
        .description("Скільки карток чекає на повторення.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

/// Each family gets its own shape rather than one layout scaled: a circular
/// complication has room for a number and nothing else, and a rectangular one
/// reads as a sentence.
struct DueCountView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DueEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular.containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            rectangular.containerBackground(.clear, for: .widget)
        default:
            small.containerBackground(.fill.tertiary, for: .widget)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(entry.due.map(String.init) ?? "—")
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
            if entry.due != nil {
                Text(subtitle).font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text(entry.due.map(String.init) ?? "—")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var headline: String {
        guard let due = entry.due else { return "Відкрийте застосунок" }
        return due == 0 ? "На сьогодні все" : "до повторення"
    }

    private var subtitle: String {
        entry.due == 0 ? "До завтра" : "Торкніться, щоб почати"
    }

    private var accessibilityLabel: String {
        guard let due = entry.due else { return "Repeat: кількість невідома" }
        return due == 0 ? "Repeat: на сьогодні все" : "Repeat: \(due) карток до повторення"
    }
}
