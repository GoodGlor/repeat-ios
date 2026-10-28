import Foundation

/// Reviews per local day, built once (#136).
///
/// `Streak.length`, `Records.make` and `Heatmap.make` each used to map the whole
/// log to start-of-day themselves. On the 10k fixture that single line costs
/// **13.7 ms**, and each of those three functions measured 12.9–13.9 ms — they were
/// almost entirely this, done three times over for the same answer.
///
/// Counts rather than a `Set`, because that is the shape that serves all three:
/// `Records` needs a per-day total for `bestDay` and `bestWeek`, `Heatmap` needs one
/// per cell, and "was there a review that day" is `counts[day] != nil`, which is the
/// same O(1) lookup a `Set` would give.
///
/// Must be built with the calendar its readers use: the keys are start-of-day in
/// that calendar's time zone, and mixing two would put a review on the wrong day.
struct ReviewDays: Equatable {
    /// Start-of-day → number of real reviews that day. Undo markers (rating 0) are
    /// the caller's job to exclude, the same contract `reviewDates` has always had.
    let counts: [Date: Int]

    init(counts: [Date: Int]) {
        self.counts = counts
    }

    init(reviewDates: [Date], calendar: Calendar = .current) {
        var counts: [Date: Int] = [:]
        for date in reviewDates {
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }
        self.counts = counts
    }

    var isEmpty: Bool { counts.isEmpty }

    func hasReview(on day: Date) -> Bool { counts[day] != nil }
}
