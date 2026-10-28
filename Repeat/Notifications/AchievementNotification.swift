import Foundation
import SwiftData
import UserNotifications
import Scheduling

/// One notification for badges that unlocked while nobody was looking (§5.5).
///
/// Evaluation runs on Home while the app is active, and there the Done screen is
/// the celebration. The only evaluation that can run with the app inactive is the
/// daily background refresh, and that is the only production caller. Two rules
/// from #108 carry over: whoever shows a badge writes the ledger, and writes it
/// late — here, after the centre accepted the request, never before and never on
/// a refusal, so a badge that was not announced stays fresh for the next Done
/// screen.
enum AchievementNotification {
    /// One identifier. A second badge the same day replaces the first in
    /// Notification Centre rather than stacking (§2: one a day).
    static let identifier = "com.goodglor.repeat.achievement"

    static var title: String { Localized.string("Досягнення") }

    /// The first fresh badge's notification title, and a count of the rest. All
    /// of them are marked shown; the rest are one tap away in Stats.
    static func body(for badges: [Achievements.Badge], locale: Locale = .current) -> String {
        guard let first = badges.first else { return "" }
        let more = badges.count - 1
        guard more > 0 else { return first.notificationTitle(locale: locale) }
        return Localized.string("\(first.notificationTitle(locale: locale)) та ще \(more)", locale: locale)
    }

    /// Posts for `fresh`, unless the scene is active (the Done screen owns that
    /// case) or notifications are off (R2: the reminder toggle is where
    /// authorisation was asked). Badges a Done screen is currently displaying
    /// are subtracted first — see `OnScreenBadges` for the suspended-process
    /// case the scene check cannot see. Returns what it announced.
    @discardableResult
    nonisolated(nonsending) static func post(
        fresh: [Achievements.Badge],
        sceneIsActive: Bool,
        enabled: Bool,
        ledger: AchievementLedger,
        now: Date = .now,
        using scheduler: any NotificationScheduling
    ) async -> [Achievements.Badge] {
        guard !sceneIsActive, enabled, !fresh.isEmpty else { return [] }

        // Before anything is built or delivered: a badge on a Done screen is
        // being celebrated by that screen, whose undo is still live. An inactive
        // scene does not mean nobody is looking — a locked phone with the Done
        // screen up is inactive too.
        let onScreen = await OnScreenBadges.current
        let announceable = fresh.filter { !onScreen.contains($0) }
        guard !announceable.isEmpty else { return [] }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body(for: announceable)
        content.sound = .default
        content.userInfo = [NotificationRouter.userInfoKey: DeepLink.stats]
        // No trigger: deliver now. Nothing can make this false by the time it
        // arrives — it is already true.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do { try await scheduler.add(request) } catch { return [] }

        // Accepted by the centre is as far as this can check, and under the
        // `.provisional` authorisation `NotificationScheduling.requestAuthorization`
        // asks for, "accepted" can mean a quiet line in Notification Centre
        // rather than a banner. Marking shown anyway is a deliberate choice, not
        // an oversight: the Stats badge grid *is* this ledger — a badge written
        // here appears there permanently, dated (`StatsSummary.achievements`) —
        // so the worst case is a celebration that was quieter than intended,
        // never one that is lost. Gating on full authorisation would need a new
        // protocol requirement and would make badges stricter than the daily
        // reminder that chose provisional in the first place.
        ledger.markShown(announceable, on: now)
        return announceable
    }

    /// Evaluates the store and posts. `nonisolated(nonsending)` for the reason
    /// `DailyReminder.refresh` gives: the context is the caller's, and a context
    /// is used only on the actor that owns it.
    @discardableResult
    nonisolated(nonsending) static func refresh(
        in context: ModelContext,
        sceneIsActive: Bool,
        enabled: Bool,
        queueConfig: QueueConfig = QueueConfig(),
        ledger: AchievementLedger = AchievementLedger(),
        now: Date = .now,
        calendar: Calendar = .current,
        using scheduler: any NotificationScheduling = SystemNotificationScheduler()
    ) async -> [Achievements.Badge] {
        // Cheap exits first: no fetch when nothing could be posted.
        guard !sceneIsActive, enabled else { return [] }

        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        // `owedToday` is Home's number — the plan under Home's caps, now — so
        // "all decks green" means here what it means on screen (#107 ruling 4).
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(
            decks: decks, now: now, config: queueConfig, recentLogs: logs,
            logsToday: logs.filter { calendar.isDate($0.reviewedAt, inSameDayAs: now) },
            calendar: calendar, using: &generator
        )
        let facts = Achievements.Facts.make(in: context, logs: logs, owedToday: plan.count,
                                            now: now, calendar: calendar)
        let fresh = Achievements.evaluate(facts: facts, ledger: ledger).fresh
        return await post(fresh: fresh, sceneIsActive: sceneIsActive, enabled: enabled,
                          ledger: ledger, now: now, using: scheduler)
    }
}
