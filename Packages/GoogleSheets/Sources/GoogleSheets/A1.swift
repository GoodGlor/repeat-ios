import Foundation

/// A1 notation. Small, but wrong exactly once at the 26th column, so it is worth
/// having in one tested place.
public enum A1 {
    /// 0-based column index to letters: 0 → A, 25 → Z, 26 → AA.
    public static func column(_ index: Int) -> String {
        precondition(index >= 0)
        var remaining = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    /// Quotes a sheet title when A1 requires it, doubling embedded apostrophes.
    public static func quote(_ title: String) -> String {
        let needsQuoting = title.contains { !$0.isLetter && !$0.isNumber && $0 != "_" }
        guard needsQuoting else { return title }
        return "'\(title.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// A single cell, e.g. `'Phrasal verbs'!C7`.
    public static func cell(sheet: String, column columnIndex: Int, row: Int) -> String {
        "\(quote(sheet))!\(column(columnIndex))\(row)"
    }

    /// A whole row range across `width` columns, e.g. `Verbs!A7:H7`.
    public static func row(sheet: String, width: Int, row: Int) -> String {
        "\(quote(sheet))!A\(row):\(column(max(0, width - 1)))\(row)"
    }

    /// Every data row of a sheet, header included.
    public static func allRows(sheet: String) -> String {
        "\(quote(sheet))!A:ZZ"
    }

    /// The append target for a whole sheet: `_log!A:G`. Bounded to the log's own
    /// width so a stray value further right cannot make Google treat a wider
    /// rectangle as the table and append past it.
    public static func allRows(sheet: String, width: Int) -> String {
        "\(quote(sheet))!A:\(column(max(0, width - 1)))"
    }

    /// Percent-encodes a range for use as a **path segment**.
    ///
    /// The Sheets append endpoint is `…/values/{range}:append`, so the range's own
    /// `:` — as in `A:ZZ` — has to be escaped or Google reads the range as running
    /// up to the wrong colon and rejects it. `!` and quotes stay literal: Google
    /// requires them, and escaping them produces `Unable to parse range`.
    static func pathEscaped(_ range: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":/?#[]@")
        return range.addingPercentEncoding(withAllowedCharacters: allowed) ?? range
    }
}
