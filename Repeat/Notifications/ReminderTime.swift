import Foundation

/// Turning "the owner chose 20:00" into an actual moment (#128).
///
/// Both evening reminders used to do this as `startOfDay(for: now) + minutes ×
/// 60`, which assumes every day is 86 400 seconds long. On a spring-forward day
/// it is 82 800, so a reminder set for 20:00 fired at 21:00; on a fall-back day
/// it fired at 19:00. Twice a year, on the two days a reminder is least likely
/// to be looked at closely.
///
/// The fix is to stop doing date arithmetic and ask the calendar the question the
/// owner actually asked: *when is the next moment whose wall clock reads 20:00?*
/// `matchingPolicy: .nextTime` also answers it for a time that does not exist at
/// all — 02:30 on a spring-forward morning resolves forward to 03:00 rather than
/// silently becoming something else.
///
/// One type for both reminders, so the two can never drift apart again — which
/// matters more than it looks: §5.5's arbitration compares their fire dates, and
/// it only survived this bug because both were wrong in the same direction.
enum ReminderTime {

    /// Minutes past midnight, as the calendar wants them.
    private static func components(_ minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0)
    }

    /// The next occurrence of that wall-clock time **strictly** after `now`: a
    /// refresh running at exactly 21:00:00 must schedule tomorrow's reminder, not
    /// one firing in the same instant.
    static func next(after now: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now, matching: components(minutes),
            matchingPolicy: .nextTime, direction: .forward
        ) ?? calendar.startOfDay(for: now).addingTimeInterval(Double(minutes) * 60)
    }

    /// That wall-clock time **today**, whether or not it has already passed.
    ///
    /// Deliberately not `next`: the streak reminder is for tonight or not at all
    /// (see `StreakReminder`), and a request rolled forward to tomorrow evening
    /// would announce a streak that midnight had already ended.
    static func today(minutes: Int, now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        // `nextDate(after:)` is strict, so the search starts a moment before
        // midnight — otherwise a reminder time of 00:00 would match tomorrow's.
        let candidate = calendar.nextDate(
            after: start.addingTimeInterval(-1), matching: components(minutes),
            matchingPolicy: .nextTime, direction: .forward
        )
        // The fallback is the old arithmetic, and it is unreachable for any real
        // time zone: it exists so a calendar that cannot answer at all still
        // produces a moment rather than a crash on the rating path.
        guard let candidate, calendar.isDate(candidate, inSameDayAs: now) else {
            return start.addingTimeInterval(Double(minutes) * 60)
        }
        return candidate
    }
}
