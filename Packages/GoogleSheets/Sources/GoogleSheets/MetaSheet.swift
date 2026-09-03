import Foundation

/// The `_meta` worksheet (§3.1): a key/value tab holding the knobs the Sheet
/// owns, so optimizer output can be pasted in without a rebuild.
public struct MetaSheet: Equatable, Sendable {
    public static let title = "_meta"
    public static let logTitle = "_log"

    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    /// Rows are `key, value`. Blank keys and rows past the second column are
    /// ignored rather than treated as errors — this tab is edited by hand.
    public static func parse(rows: [[String]]) -> MetaSheet {
        var values: [String: String] = [:]
        for row in rows {
            guard let key = row.first?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
            else { continue }
            // A header row is common and harmless to skip.
            if key.lowercased() == "key" { continue }
            values[key.lowercased()] = row.count > 1 ? row[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        return MetaSheet(values: values)
    }

    public var schemaVersion: String? { nonEmpty("schema_version") }
    /// Raw JSON array; the caller validates the length, because only the
    /// scheduling layer knows FSRS-6 needs exactly 21 (§5.1).
    public var rawFSRSParams: String? { nonEmpty("fsrs_params") }
    public var rawDesiredRetention: String? { nonEmpty("desired_retention") }

    private func nonEmpty(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }
}
