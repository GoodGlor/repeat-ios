import Foundation
import SwiftData
import WidgetKit
import Scheduling

/// Keeps the widget's number equal to Home's (§7.1).
///
/// One place writes the file, so the two cannot drift into different definitions
/// of "due". Home publishes the plan it is already showing; the sync actor
/// publishes a freshly built one, which is what Home *would* show — that is what
/// keeps the widget honest on a day the app is never opened.
enum DueCountPublisher {
    /// Publishes a count Home has already computed.
    static func publish(
        plan: QueuePlan,
        now: Date = .now,
        reloadWidgets: Bool = true,
        to url: URL? = AppGroup.dueCountURL
    ) {
        write(DueCount(due: plan.count, day: Calendar.current.startOfDay(for: now),
                       generatedAt: now),
              reloadWidgets: reloadWidgets, to: url)
    }

    /// Builds the plan and publishes it. Used off the main actor, after a sync.
    static func publish(
        from context: ModelContext,
        config: QueueConfig = QueueConfig(),
        now: Date = .now,
        reloadWidgets: Bool = true,
        to url: URL? = AppGroup.dueCountURL
    ) {
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        publishDecks(from: context)
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(
            decks: decks,
            now: now,
            config: config,
            recentLogs: logs,
            logsToday: logs.filter { Calendar.current.isDate($0.reviewedAt, inSameDayAs: now) },
            using: &generator
        )
        publish(plan: plan, now: now, reloadWidgets: reloadWidgets, to: url)
    }

    /// §7.3: the Share Extension's deck picker cannot read SwiftData, so the app
    /// leaves it a list. Published alongside the due count because both are
    /// refreshed by exactly the same events.
    static func publishDecks(from context: ModelContext) {
        let decks = ((try? context.fetch(FetchDescriptor<Deck>())) ?? [])
            .filter { $0.deletedAt == nil && $0.malformedReason == nil }
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
            .map { SharedDecks.Entry(title: $0.sheetTitle, colorHex: $0.colorHex) }
        try? SharedDecks(decks: decks).write()
    }

    private static func write(_ count: DueCount, reloadWidgets: Bool, to url: URL?) {
        guard (try? count.write(to: url)) == true else { return }
        // §7.1: after each session. WidgetKit coalesces these itself, so calling
        // it on every publish is cheaper than deciding when it matters.
        if reloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
    }
}
