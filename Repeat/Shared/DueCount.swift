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

    public init(due: Int, day: Date, generatedAt: Date = .now) {
        self.due = due
        self.day = day
        self.generatedAt = generatedAt
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
