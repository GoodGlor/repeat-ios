import SwiftUI

/// A year of days shaded by how many reviews each held (§5.2).
///
/// Derived from the log on every load, like everything on the Stats screen.
/// Columns are weeks, oldest first; rows are Monday to Sunday, the same week
/// `Records` uses. The last column is the current week, so today is somewhere
/// down its right-hand edge and the rows below it are blank.
struct Heatmap: Equatable {
    static let weeks = 52
    static let daysPerWeek = 7
    /// How many shades a day can take besides "none".
    static let levels = 4

    /// `cells[week][weekday]` — `week` 0 the oldest, `weekday` 0 Monday. 0 means
    /// no reviews; 1…4 is the day's share of the busiest day in the year.
    var cells: [[Int]]
    /// The Monday that starts column 0.
    var start: Date
    /// Today's row in the last column; the rows below it have not happened.
    var todayWeekday: Int
    /// Over the drawn year only.
    var totalReviews: Int
    var activeDays: Int

    /// - Parameter reviewDates: real reviews only — undo markers already excluded
    ///   by the caller, as for `Streak.length` and `Records.make`.
    static func make(reviewDates: [Date], now: Date = .now, calendar: Calendar = .current) -> Heatmap {
        make(days: ReviewDays(reviewDates: reviewDates, calendar: calendar),
             now: now, calendar: calendar)
    }

    /// The same answer from a day map already built (#136) — see `ReviewDays`.
    static func make(days: ReviewDays, now: Date = .now, calendar: Calendar = .current) -> Heatmap {
        let today = calendar.startOfDay(for: now)
        guard let thisMonday = calendar.mondayFirst.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisMonday)
        else {
            return Heatmap(cells: [], start: today, todayWeekday: 0, totalReviews: 0, activeDays: 0)
        }

        // Filtered from the prebuilt map: that is one pass over the distinct days
        // in the window rather than over every review in history.
        var counts: [Date: Int] = [:]
        for (day, count) in days.counts where day >= start && day <= today {
            counts[day] = count
        }
        let peak = counts.values.max() ?? 0

        var cells = Array(repeating: Array(repeating: 0, count: daysPerWeek), count: weeks)
        for (day, count) in counts {
            // `start` is a Monday, so whole days since it split cleanly into a
            // column and a row. `.day` components step over DST correctly where
            // dividing seconds would not.
            let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
            let week = days / daysPerWeek
            let weekday = days % daysPerWeek
            guard cells.indices.contains(week), (0..<daysPerWeek).contains(weekday) else { continue }
            cells[week][weekday] = level(count: count, peak: peak)
        }

        let todayIndex = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return Heatmap(
            cells: cells,
            start: start,
            todayWeekday: todayIndex % daysPerWeek,
            totalReviews: counts.values.reduce(0, +),
            activeDays: counts.count
        )
    }

    /// 0 for none; otherwise the day's share of the busiest day, in quarters,
    /// rounded up so a single review is never invisible.
    static func level(count: Int, peak: Int) -> Int {
        guard count > 0, peak > 0 else { return 0 }
        let quarter = Int((Double(count) / Double(peak) * Double(levels)).rounded(.up))
        return min(levels, max(1, quarter))
    }
}

/// The grid, drawn in one `Canvas`. 364 views would be 364 layout passes for a
/// picture, and VoiceOver gets one sentence instead of a year of squares.
struct HeatmapView: View {
    let heatmap: Heatmap

    /// The gap as a share of a cell, so the whole grid is one fixed aspect ratio
    /// and the cell size falls out of the width instead of being guessed.
    private static let gapRatio: CGFloat = 0.3

    private static var columns: CGFloat {
        CGFloat(Heatmap.weeks) + CGFloat(Heatmap.weeks - 1) * gapRatio
    }

    static var aspectRatio: CGFloat {
        let rows = CGFloat(Heatmap.daysPerWeek) + CGFloat(Heatmap.daysPerWeek - 1) * gapRatio
        return columns / rows
    }

    var body: some View {
        Canvas { context, size in
            let cell = size.width / Self.columns
            let step = cell * (1 + Self.gapRatio)
            for (week, column) in heatmap.cells.enumerated() {
                for (weekday, level) in column.enumerated() {
                    // The rest of this week has not happened. Leaving it blank is
                    // what makes today findable on the grid.
                    if week == Heatmap.weeks - 1, weekday > heatmap.todayWeekday { continue }
                    let rect = CGRect(x: CGFloat(week) * step, y: CGFloat(weekday) * step,
                                      width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.25),
                                 with: .color(Self.color(level)))
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Активність за рік")
        .accessibilityValue(Localized.string(
            "Повторень: \(heatmap.totalReviews), днів із повтореннями: \(heatmap.activeDays)"))
        .accessibilityIdentifier("stats.heatmap")
    }

    /// Both ends are palette tokens, so the grid follows the scheme (gotcha 29):
    /// `line` for an empty day, `accent` stepped up to full for the busiest.
    static func color(_ level: Int) -> Color {
        switch level {
        case 1: Palette.accent.opacity(0.3)
        case 2: Palette.accent.opacity(0.5)
        case 3: Palette.accent.opacity(0.75)
        case 4: Palette.accent
        default: Palette.line
        }
    }
}
