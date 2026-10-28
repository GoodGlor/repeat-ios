import Foundation

/// Everything the widget decides, decided once (#111).
///
/// Lives here, in `Repeat/Shared`, for a reason that is about the test target and
/// not about tidiness: `RepeatTests` depends on the **app** target alone, and the
/// widget's sources are `RepeatWidget` + `Repeat/Shared`. Anything left in
/// `RepeatWidget/` is code no test in this repo can reach — which is how the
/// freshness rule came to be written twice, once in `DueEntry.due` and once in the
/// prose above `DueCount.isFresh`, with nothing asserting they agreed.
///
/// The view above this renders it and decides nothing.
public struct WidgetSnapshot: Equatable, Sendable {
    /// `nil` when there is no file, or the file was computed for another day.
    ///
    /// **One staleness rule for the whole snapshot**, not one per number. The
    /// count is a today-number and obviously expires. The streak is subtler — a
    /// streak computed last night is still true this morning, because
    /// `Streak.length` counts back from yesterday when today is empty — but it is
    /// not true three days later, and a second staleness policy for one file is
    /// exactly how two numbers drift into disagreeing. Everything expires together.
    public var due: Int?
    /// The goal's two numbers rather than just the fraction: the medium layout
    /// says "18 з 30" beside the ring, and a ring with no caption is a shape.
    /// Both 0 when stale.
    public var goalDone: Int
    public var goalTarget: Int
    /// `nil` below two days. A streak of 1 is not a streak, it is today — and a
    /// widget announcing "1" every time someone starts over reads as mockery.
    public var streak: Int?

    /// 0…1, clamped. 0 when stale or when there is no goal.
    public var goalProgress: Double {
        guard goalTarget > 0 else { return 0 }
        return min(1, Double(goalDone) / Double(goalTarget))
    }

    /// `false` when today has no goal at all, so a fresh install draws nothing
    /// rather than an empty ring beside an empty count.
    public var showsRing: Bool { goalTarget > 0 }

    /// The widget has no number to show and says so, rather than showing a stale
    /// one. `DueCountView` draws "Відкрийте застосунок" here.
    public var isStale: Bool { due == nil }
    /// Everything answered. Distinct from stale: this one is good news.
    public var isDone: Bool { due == 0 }

    public init(due: Int?, goalDone: Int, goalTarget: Int, streak: Int?) {
        self.due = due
        self.goalDone = goalDone
        self.goalTarget = goalTarget
        self.streak = streak
    }

    public static func make(
        from count: DueCount?,
        on date: Date,
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        guard let count, count.isFresh(on: date, calendar: calendar) else {
            return WidgetSnapshot(due: nil, goalDone: 0, goalTarget: 0, streak: nil)
        }
        return WidgetSnapshot(
            due: count.due,
            goalDone: count.goalDone,
            goalTarget: count.goalTarget,
            streak: count.streak >= 2 ? count.streak : nil
        )
    }
}
