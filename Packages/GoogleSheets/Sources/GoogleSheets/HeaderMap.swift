import Foundation

/// Resolves a deck worksheet's columns by header name (§3.1).
///
/// By name, never by position: the owner edits this sheet by hand and will
/// reorder or insert columns. Positional parsing would keep working and quietly
/// write answers into the tags column.
public struct HeaderMap: Equatable, Sendable {
    /// Columns §3.1 gives meaning to. Everything else is an extra (D1).
    public static let known: [String] = [
        "id", "front", "back", "example", "tags", "reverse", "updated_at", "deleted",
    ]
    public static let required: [String] = ["front", "back"]

    /// Normalised header name → column index.
    public let indexByName: [String: Int]
    /// Headers not in `known`, in the sheet's own column order (D1).
    public let extraColumns: [String]
    /// The header row as written, for writing rows back in place (§4.4).
    public let headerRow: [String]

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyHeaderRow
        case missingRequiredColumn(String)
        case duplicateColumn(String)

        public var description: String {
            switch self {
            case .emptyHeaderRow:
                "перший рядок порожній — потрібні заголовки front і back"
            case .missingRequiredColumn(let name):
                "бракує обовʼязкового стовпця «\(name)»"
            case .duplicateColumn(let name):
                "стовпець «\(name)» зустрічається двічі"
            }
        }
    }

    /// Header names are matched case-insensitively and trimmed, because "Front "
    /// is what a spreadsheet actually contains after a day of editing.
    public static func normalise(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(headerRow: [String]) throws {
        let normalised = headerRow.map(Self.normalise)
        guard normalised.contains(where: { !$0.isEmpty }) else { throw Failure.emptyHeaderRow }

        var indexByName: [String: Int] = [:]
        var extras: [String] = []
        for (index, name) in normalised.enumerated() where !name.isEmpty {
            // A duplicate is ambiguous, not recoverable: two `back` columns give
            // no way to know which one the owner means.
            guard indexByName[name] == nil else { throw Failure.duplicateColumn(name) }
            indexByName[name] = index
            if !Self.known.contains(name) { extras.append(name) }
        }

        for name in Self.required where indexByName[name] == nil {
            throw Failure.missingRequiredColumn(name)
        }

        self.indexByName = indexByName
        self.extraColumns = extras
        self.headerRow = headerRow
    }

    public func index(of column: String) -> Int? {
        indexByName[Self.normalise(column)]
    }

    /// A cell's value, or `nil` when the column is absent or the row is short —
    /// Google omits trailing empty cells, so short rows are the norm.
    public func value(_ column: String, in row: [String]) -> String? {
        guard let index = index(of: column), index < row.count else { return nil }
        let value = row[index]
        return value.isEmpty ? nil : value
    }

    /// `TRUE`/`FALSE` as §3.1 writes them, tolerant of what people actually type.
    public func boolean(_ column: String, in row: [String], default fallback: Bool = false) -> Bool {
        guard let raw = value(column, in: row)?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return fallback
        }
        return ["true", "yes", "1", "y", "так"].contains(raw)
    }

    /// Extras for one row, in header order, skipping empties (D1).
    public func extras(in row: [String]) -> (values: [String: String], order: [String]) {
        var values: [String: String] = [:]
        for name in extraColumns {
            if let value = value(name, in: row) { values[name] = value }
        }
        return (values, extraColumns)
    }
}
