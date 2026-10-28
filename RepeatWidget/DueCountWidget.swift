import WidgetKit
import SwiftUI

/// §7.1: due count on the lock screen and home screen, one tap into the session.
/// #111 added the daily-goal ring and the streak on the two home-screen sizes.
///
/// The layouts themselves live in `Repeat/WidgetUI/DueCountView.swift`, where a
/// test can render them — see the note at the top of that file. What is left here
/// is the part WidgetKit owns: the timeline, and reading the family out of the
/// environment.
struct DueEntry: TimelineEntry {
    let date: Date
    let count: DueCount?

    /// Every rendering decision, made once. A count computed for another day is
    /// not a small error — it is the wrong number — and the rule that drops it
    /// drops the goal and the streak with it.
    var snapshot: WidgetSnapshot { .make(from: count, on: date) }
}

struct DueCountProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry {
        DueEntry(date: .now,
                 count: DueCount(due: 12, day: Calendar.current.startOfDay(for: .now),
                                 goalTarget: 30, goalDone: 18, streak: 9))
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
            DueCountEntryView(entry: entry)
                .widgetURL(URL(string: DeepLink.study))
        }
        .configurationDisplayName("Repeat")
        .description("Скільки карток чекає на повторення, і як просувається день.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular])
    }
}

/// The one line `DueCountView` cannot own: `\.widgetFamily` is readable only
/// inside a widget host, and a view that reads it there is a view no test can ask
/// for the medium layout.
struct DueCountEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DueEntry

    var body: some View {
        DueCountView(snapshot: entry.snapshot, family: family)
    }
}
