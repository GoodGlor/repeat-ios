import Foundation

/// The due count as it crosses into the App Group container (§7.1).
///
/// Compiled into the app and the widget, so the format is defined once. The
/// widget extension cannot open SwiftData cheaply — and must not, since it is
/// woken on a budget — so the app publishes a number and the widget renders it.
public struct DueCount: Codable, Equatable, Sendable {
    /// What Home's big number says. Not a raw count of overdue cards: the daily
    /// plan is capped (§5.2), and a widget promising 300 cards when the button
    /// delivers 30 would be lying.
    public var due: Int
    /// The local day the count was computed for. A count from yesterday is not a
    /// small error — it is the wrong number entirely, and saying nothing beats
    /// saying something false.
    public var day: Date
    public var generatedAt: Date

    /// Today's goal, exactly as `DailyGoal` defines it: the target Home cached the
    /// first time it built the day, and the distinct cards graded since (M9 §5.1).
    ///
    /// Published rather than recomputed. The widget could read `DailyGoalCache`
    /// through an App Group defaults suite instead — but then the ring would have a
    /// second derivation, and §7.1's whole rule is that there is one. `0` means
    /// there is no goal today, which draws no ring rather than an empty one.
    public var goalTarget: Int
    public var goalDone: Int
    /// Consecutive days with a review, frozen days bridged (#112).
    public var streak: Int

    public init(
        due: Int,
        day: Date,
        goalTarget: Int = 0,
        goalDone: Int = 0,
        streak: Int = 0,
        generatedAt: Date = .now
    ) {
        self.due = due
        self.day = day
        self.goalTarget = goalTarget
        self.goalDone = goalDone
        self.streak = streak
        self.generatedAt = generatedAt
    }

    /// 0…1, and 0 when there is no goal — the same rule as `DailyGoal.progress`,
    /// restated here because the widget has the numbers and not the type.
    public var goalProgress: Double {
        guard goalTarget > 0 else { return 0 }
        return min(1, Double(goalDone) / Double(goalTarget))
    }

    public func isFresh(on date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, inSameDayAs: date)
    }

    // MARK: - The file

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public func write(to url: URL? = AppGroup.dueCountURL) throws -> Bool {
        guard let url else { return false }
        try Self.encoder().encode(self).write(to: url, options: .atomic)
        return true
    }

    public static func read(from url: URL? = AppGroup.dueCountURL) -> DueCount? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(DueCount.self, from: data)
    }
}

/// The decoder is hand-written, and that is not a style choice.
///
/// A **synthesized** `init(from:)` ignores a property's default and throws
/// `keyNotFound` when the key is absent, so the three properties #111 added would
/// have made every file written before it undecodable — and `read` turns a throw
/// into `nil`, so the widget would have shown "—" until the app next published.
/// The identical mistake nearly shipped in #112's backup file.
///
/// In an **extension** rather than the type body, because declaring an initialiser
/// inside the body would suppress the one above it.
extension DueCount {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        due = try container.decode(Int.self, forKey: .due)
        day = try container.decode(Date.self, forKey: .day)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        goalTarget = try container.decodeIfPresent(Int.self, forKey: .goalTarget) ?? 0
        goalDone = try container.decodeIfPresent(Int.self, forKey: .goalDone) ?? 0
        streak = try container.decodeIfPresent(Int.self, forKey: .streak) ?? 0
    }
}
