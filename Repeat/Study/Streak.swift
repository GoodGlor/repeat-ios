import Foundation

/// Consecutive days with at least one review (§6.3, §6.5).
///
/// Derived from `_log` rather than stored. A counter would have to be corrected
/// on every undo, every restore from backup and every rebuild from `_log` (#41),
/// and any missed correction would be permanent and invisible. The log already
/// records exactly which days had reviews.
enum Streak {
    /// - Parameter reviewDates: `reviewedAt` of every real review; undo markers
    ///   (rating 0) must already be excluded by the caller.
    static func length(reviewDates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let days = Set(reviewDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        // A day with no session yet does not break the streak until it ends, so
        // count back from yesterday when today is still empty.
        var cursor = days.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        guard days.contains(cursor) else { return 0 }

        var length = 0
        while days.contains(cursor) {
            length += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return length
    }
}
