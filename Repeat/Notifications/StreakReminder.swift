import Foundation
import UserNotifications

/// The evening reminder for a streak that is about to be lost (§5.5, #110).
///
/// `DailyReminder` says cards are waiting. This one says something the owner
/// already has is about to go, and it is silent on every day that would be false.
///
/// **It is scheduled for tonight, or not at all.** `DailyReminder` rolls forward
/// to tomorrow when today's time has passed; this cannot. With no review today the
/// streak breaks at midnight, so a request sitting in the queue for tomorrow
/// evening would announce a streak that no longer exists — and iOS will not
/// re-evaluate it. Scheduling nothing is the honest answer: by tomorrow evening a
/// review has either landed (nothing was at risk) or it has not (nothing is left
/// to save).
///
/// A `streakMinutes` of `0` (midnight) means the streak reminder is **off** — it
/// never has a fire time later than "now" within the same day, so it can never
/// fire — and, just as importantly, it leaves the due-reminder alone: §5.5's
/// arbitration only stands the due-reminder down when a streak reminder is
/// actually going to fire this evening.
enum StreakReminder {
    /// One identifier, forever — every refresh removes it before adding, so a
    /// changed time reschedules rather than stacks.
    static let identifier = "com.goodglor.repeat.streak-reminder"

    struct Plan: Equatable {
        var fireDate: Date
        var length: Int
    }

    /// The streak that would be lost tonight, or `nil` when nothing is at risk.
    ///
    /// Independent of the clock: unlike `plan`, this does not consider whether
    /// tonight's fire time has already passed. Split out so `EveningReminder` can
    /// ask "is a streak at stake this evening?" even after the reminder's own hour
    /// has gone by — the question §5.5's arbitration actually needs, since the
    /// due-reminder must stand down for the whole evening a streak notification
    /// already fired in, not merely until that fire time.
    static func lengthAtRisk(
        logs: [ReviewLog],
        enabled: Bool,
        frozenDays: Set<Date> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int? {
        guard enabled else { return nil }

        // Rating 0 is an undo marker, not a review (§5.5). The same filter
        // `HomeView` and `StatsSummary` apply, for the same reason: an undone
        // review must not hold a streak up.
        let dates = logs.filter { $0.rating != 0 }.map(\.reviewedAt)

        // Nothing is at risk once today has a review.
        guard !dates.contains(where: { calendar.isDate($0, inSameDayAs: now) })
        else { return nil }

        // #112: a day a freeze covered is not a day the streak was broken, so
        // the evening after one must not announce a loss that did not happen.
        let length = Streak.length(reviewDates: dates, frozenDays: frozenDays,
                                   now: now, calendar: calendar)
        guard length > 0 else { return nil }
        return length
    }

    /// Tonight's fire moment for `streakMinutes`, whether or not it has passed.
    /// Never `nextFireDate`'s roll to tomorrow — see the type's doc comment.
    static func fireDateToday(
        streakMinutes: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        // #128: the same calendar question `DailyReminder` asks, bounded to today
        // because this reminder is for tonight or not at all.
        ReminderTime.today(minutes: streakMinutes, now: now, calendar: calendar)
    }

    /// The timing rule applied to an already-computed risk, so the log is walked
    /// only once per refresh (#116).
    static func plan(
        lengthAtRisk: Int?,
        streakMinutes: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Plan? {
        // `streakMinutes == 0` means the streak reminder is off (see the type's
        // doc comment): its "fire time" is midnight, which can never be later
        // than `now` today, so this guard also covers that case on its own — it
        // is named separately because a caller reading the arbitration should not
        // have to re-derive that from the arithmetic.
        guard streakMinutes > 0, let lengthAtRisk else { return nil }
        let fireDate = fireDateToday(streakMinutes: streakMinutes, now: now, calendar: calendar)
        guard fireDate > now else { return nil }
        return Plan(fireDate: fireDate, length: lengthAtRisk)
    }

    /// §5.5's sentence. The three Ukrainian plural forms come from the catalogue
    /// (#38), which is also the only way they can be asserted in a test.
    static func body(length: Int, locale: Locale = .current) -> String {
        Localized.string("Серія \(length) днів — сьогодні ще без повторень", locale: locale)
    }

    static var title: String { Localized.string("Серія під загрозою") }

    // MARK: - Applying

    /// Brings the scheduled notification in line with `plan`. Idempotent.
    ///
    /// Takes an already-computed plan so `EveningReminder` — which needs the plan
    /// to decide the arbitration before anything is scheduled — does not walk the
    /// whole log a second time. #116 is the standing reminder that recomputing a
    /// derived summary per pass is where this app's time actually goes.
    ///
    /// `nonisolated(nonsending)`: the body runs on the **caller's** actor, for the
    /// reason `DailyReminder.refresh` records — three crash reports from the
    /// owner's phone on 2026-09-04, all reading models off the main thread.
    /// - Returns: whether the evening is genuinely covered by a streak reminder.
    ///   `true` when there was nothing to schedule — there is nothing to fall
    ///   back from — and `true` when the request was accepted. **`false` only
    ///   when one was attempted and refused**, which is the case #129 exists for:
    ///   `EveningReminder` has to know, because by then it may already have stood
    ///   the due-reminder down.
    @discardableResult
    nonisolated(nonsending) static func apply(
        _ plan: Plan?,
        using scheduler: any NotificationScheduling,
        calendar: Calendar = .current
    ) async -> Bool {
        // Removed first, always, and whether or not anything replaces it: this is
        // what cancels a reminder the moment a review lands.
        await scheduler.removePending(identifiers: [identifier])
        guard let plan else { return true }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body(length: plan.length)
        content.sound = .default
        content.userInfo = [NotificationRouter.userInfoKey: DeepLink.study]

        // One-shot, like `DailyReminder`: a repeating trigger would keep firing
        // with the streak length frozen at whatever was true the day it was made.
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: plan.fireDate
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        // The one place the answer is decided. `try?` used to swallow this, and
        // the evening went silent with nothing logged anywhere.
        do {
            try await scheduler.add(request)
            return true
        } catch {
            return false
        }
    }

}
