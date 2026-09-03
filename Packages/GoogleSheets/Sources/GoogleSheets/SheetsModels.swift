import Foundation

/// One worksheet's identity (§3.1). `sheetId` is the tab's `gid`, which survives
/// a rename — the reason renaming a tab does not lose scheduling state (§4.3).
public struct SheetProperties: Equatable, Sendable {
    public let sheetId: Int
    public let title: String
    public let index: Int

    public init(sheetId: Int, title: String, index: Int) {
        self.sheetId = sheetId
        self.title = title
        self.index = index
    }

    /// Tabs prefixed with `_` are reserved (§3.1) and never become decks.
    public var isReserved: Bool { title.hasPrefix("_") }
}

/// A rectangle of cell values. Google omits trailing empty cells, so rows are
/// ragged and callers must not index blindly.
public struct ValueRange: Equatable, Sendable {
    public let range: String
    public let values: [[String]]

    public init(range: String, values: [[String]]) {
        self.range = range
        self.values = values
    }

    /// The sheet title part of an A1 range, unquoting where Google quoted it.
    public var sheetTitle: String {
        let title = range.split(separator: "!").first.map(String.init) ?? range
        guard title.hasPrefix("'"), title.hasSuffix("'"), title.count >= 2 else { return title }
        return String(title.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
}

public enum SheetsError: Error, Equatable, CustomStringConvertible {
    case auth(GoogleAuthError)
    /// The spreadsheet id does not resolve, or the service account cannot see it.
    case spreadsheetNotFound
    case notShared
    case rateLimited(afterAttempts: Int)
    case server(status: Int, message: String)
    case malformedResponse(String)
    case transport(String)

    public var description: String {
        switch self {
        case .auth(let error): error.description
        case .spreadsheetNotFound:
            "Таблицю не знайдено. Перевірте ID таблиці."
        case .notShared:
            "Немає доступу до таблиці. Поділіться нею зі службовим акаунтом як редактором."
        case .rateLimited(let attempts):
            "Google обмежує запити. Спробували \(attempts) разів — синхронізація продовжиться пізніше."
        case .server(let status, let message):
            "Google повернув помилку \(status): \(message)"
        case .malformedResponse(let detail):
            "Неочікувана відповідь від Google: \(detail)"
        case .transport(let reason):
            "Немає звʼязку з Google: \(reason)"
        }
    }

    public var needsSettingsAttention: Bool {
        switch self {
        case .auth(let error): error.needsSettingsAttention
        case .spreadsheetNotFound, .notShared: true
        case .rateLimited, .server, .malformedResponse, .transport: false
        }
    }
}
