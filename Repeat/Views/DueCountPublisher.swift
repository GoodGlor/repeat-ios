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
    /// Publishes numbers Home has already computed.
    ///
    /// The goal and the streak travel with the count (#111) rather than being
    /// re-derived in the widget, for the reason the count itself is published: a
    /// second derivation is a second definition, and the two would eventually
    /// disagree about the same day.
    static func publish(
        plan: QueuePlan,
        goal: DailyGoal,
        streak: Int,
        now: Date = .now,
        reloadWidgets: Bool = true,
        to url: URL? = AppGroup.dueCountURL
    ) {
        write(DueCount(due: plan.count, day: Calendar.current.startOfDay(for: now),
                       goalTarget: goal.target, goalDone: goal.done, streak: streak,
                       generatedAt: now),
              reloadWidgets: reloadWidgets, to: url)
    }

    /// Builds the plan and publishes it. Used off the main actor, after a sync.
    ///
    /// Everything Home would have shown, derived here from the same inputs — this
    /// is what keeps the widget honest on a day the app is never opened.
    ///
    /// - Parameter goalCache: read, never written. Injectable so a test does not
    ///   have to reach into `UserDefaults.standard`.
    static func publish(
        from context: ModelContext,
        config: QueueConfig = QueueConfig(),
        now: Date = .now,
        reloadWidgets: Bool = true,
        to url: URL? = AppGroup.dueCountURL,
        goalCache: DailyGoalCache = DailyGoalCache()
    ) {
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        publishDecks(from: context)
        var generator = SystemRandomNumberGenerator()
        let logsToday = logs.filter { Calendar.current.isDate($0.reviewedAt, inSameDayAs: now) }
        let plan = QueueBuilder.plan(
            decks: decks,
            now: now,
            config: config,
            recentLogs: logs,
            logsToday: logsToday,
            using: &generator
        )
        // The target Home cached this morning, **read and not written**. §5.1 makes
        // the target what today looked like the first time *Home* built it, and a
        // background writer would quietly change the number Home then shows — a
        // behaviour change this card was not asked to make. The cost of leaving it
        // read-only: on a day the app is never opened the target is re-derived on
        // each publish, so the ring's denominator can shift slightly as cards come
        // due. One line to reverse if that ever looks wrong.
        let goal = DailyGoal.make(
            reviewedToday: HomeSummary.reviewedCount(logsToday: logsToday, now: now),
            dueCount: plan.count,
            cachedTarget: goalCache.target(on: now)
        )
        let streak = Streak.length(
            reviewDates: logs.filter { $0.rating != 0 }.map(\.reviewedAt),
            frozenDays: Freeze.days(in: context),
            now: now
        )
        publish(plan: plan, goal: goal, streak: streak,
                now: now, reloadWidgets: reloadWidgets, to: url)
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
