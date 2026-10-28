import Foundation

/// The three records §5.2 shows — longest streak, best day, best week — derived
/// from the log on demand, the way `Streak.length` is (spec §2.1).
///
/// Nothing here is stored. A stored record would need correcting on undo, on
/// restore and on rebuild-from-`_log`, and a missed correction would be permanent
/// and invisible; the log already holds every day that ever had a review.
struct Records: Equatable {

    /// A day, or the Monday that starts a week, and how many reviews it held.
    struct Entry: Equatable {
        var start: Date
        var count: Int
    }

    var longestStreak: Int
    /// The first day of the run that holds `longestStreak`, so a session can
    /// tell "I extended my record" from "I overtook it". Ties go to the
    /// earliest run, like every other record here.
    var longestStreakStart: Date?
    var bestDay: Entry?
    var bestWeek: Entry?

    static let empty = Records(longestStreak: 0, longestStreakStart: nil, bestDay: nil, bestWeek: nil)

    /// - Parameter reviewDates: `reviewedAt` of every real review; undo markers
    ///   (rating 0) must already be excluded by the caller — the contract
    ///   `Streak.length` has, so both are fed from `StatsSummary.reviewDates`.
    ///   - frozenDays: days a `StreakFreeze` covers (#112). They bridge a run
    ///     without counting toward it — the same rule `Streak.length` applies,
    ///     and it has to be the same one: if the longest streak did not bridge,
    ///     Home could show a current streak longer than the record it is
    ///     supposedly measured against.
    ///
    ///     `bestDay` and `bestWeek` are deliberately **not** given freezes.
    ///     Those are counts of reviews, and a frozen day has none — a freeze
    ///     buys a day off, and a day off is not anybody's best day.
    static func make(
        reviewDates: [Date],
        frozenDays: Set<Date> = [],
        calendar: Calendar = .current
    ) -> Records {
        make(days: ReviewDays(reviewDates: reviewDates, calendar: calendar),
             frozenDays: frozenDays, calendar: calendar)
    }

    /// The same answer from a day map already built (#136) — see `ReviewDays`.
    static func make(
        days: ReviewDays,
        frozenDays: Set<Date> = [],
        calendar: Calendar = .current
    ) -> Records {
        let perDay = days.counts

        // §5.2: a week is Monday to Sunday whatever the device's region says,
        // so the week is found with a Monday-first copy of the same calendar.
        let weekly = calendar.mondayFirst
        var perWeek: [Date: Int] = [:]
        for (day, count) in perDay {
            guard let monday = weekly.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
            perWeek[monday, default: 0] += count
        }

        let frozen = Set(frozenDays.map { calendar.startOfDay(for: $0) })
        let run = longestRun(days: perDay.keys.sorted(), frozen: frozen, calendar: calendar)
        return Records(
            longestStreak: run.length,
            longestStreakStart: run.start,
            bestDay: best(perDay),
            bestWeek: best(perWeek)
        )
    }

    /// The longest run of consecutive days anywhere in the history — not the
    /// current one, which is `Streak.length`'s question — and where it began.
    /// A later run of equal length does not take the record (`>`, not `>=`).
    private static func longestRun(
        days: [Date],
        frozen: Set<Date>,
        calendar: Calendar
    ) -> (length: Int, start: Date?) {
        var longest = 0
        var longestStart: Date?
        var run = 0
        var runStart: Date?
        var previous: Date?
        for day in days {
            if let previous, isContinuous(from: previous, to: day, frozen: frozen, calendar: calendar) {
                run += 1
            } else {
                run = 1
                runStart = day
            }
            if run > longest {
                longest = run
                longestStart = runStart
            }
            previous = day
        }
        return (longest, longestStart)
    }

    /// Whether two review days belong to the same run: adjacent, or separated
    /// only by days a freeze covered. With no freezes this is exactly the
    /// `previous + 1 == day` test it replaces.
    private static func isContinuous(
        from previous: Date,
        to day: Date,
        frozen: Set<Date>,
        calendar: Calendar
    ) -> Bool {
        var cursor = calendar.date(byAdding: .day, value: 1, to: previous)
        while let candidate = cursor, candidate < day {
            guard frozen.contains(candidate) else { return false }
            cursor = calendar.date(byAdding: .day, value: 1, to: candidate)
        }
        return cursor == day
    }

    /// Highest count; a tie goes to the earliest, so a record's date never moves
    /// once it is set.
    private static func best(_ counts: [Date: Int]) -> Entry? {
        counts
            .map { Entry(start: $0.key, count: $0.value) }
            .max { a, b in a.count < b.count || (a.count == b.count && a.start > b.start) }
    }

    // MARK: - What a session set

    enum Kind: Equatable {
        case longestStreak(Int)
        case bestDay(Int)
        case bestWeek(Int)
    }

    /// `StreakChip.isWorthShowing`'s floor, kept in step by hand: a one-day
    /// streak is shown nowhere, so it is announced nowhere.
    static let shortestStreakWorthNaming = 2

    /// The records `after` beats in `before`, most worth naming first.
    ///
    /// "Beats" means *overtakes*, not *extends*. On your record run every day
    /// is one longer than the day before, and a line that appears every evening
    /// is wallpaper (§2.2) — so a streak is named only when the run holding the
    /// record changes, a day only when the record moves to another day, a week
    /// only when it moves to another week. Two further silences: a one-day
    /// streak is not a record, and nothing beats an empty history — the first
    /// session ever sets every record and announces none.
    static func newlySet(before: Records, after: Records) -> [Kind] {
        var kinds: [Kind] = []
        if after.longestStreak > before.longestStreak,
           after.longestStreak >= shortestStreakWorthNaming,
           after.longestStreakStart != before.longestStreakStart {
            kinds.append(.longestStreak(after.longestStreak))
        }
        if let day = after.bestDay, let previous = before.bestDay,
           day.count > previous.count, day.start != previous.start {
            kinds.append(.bestDay(day.count))
        }
        if let week = after.bestWeek, let previous = before.bestWeek,
           week.count > previous.count, week.start != previous.start {
            kinds.append(.bestWeek(week.count))
        }
        return kinds
    }
}

extension Calendar {
    /// The same calendar with weeks starting on Monday. §5.2 defines "best week"
    /// as Monday to Sunday; `Calendar.current` starts on Sunday in some regions.
    var mondayFirst: Calendar {
        var copy = self
        copy.firstWeekday = 2
        return copy
    }
}
