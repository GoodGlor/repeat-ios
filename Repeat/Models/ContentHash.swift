import Foundation
import CryptoKit

/// The one place a note's content fingerprint is computed (§3.2).
///
/// Sync compares this to decide whether a Sheet row's *content* changed; a
/// mismatch rewrites `Note` fields and never touches `Card` scheduling (§4.3).
/// Anything included here therefore propagates on edit, and anything omitted is
/// invisible to sync.
enum ContentHash {
    /// Separator that cannot occur in Sheet content, so no combination of field
    /// values can collide by re-splitting differently ("a|b" + "c" vs "a" + "b|c").
    private static let unit = "\u{1F}"

    static func of(
        front: String,
        back: String,
        example: String?,
        tags: [String],
        reverse: Bool,
        extras: [String: String],
        extraOrder: [String]
    ) -> String {
        var parts = [
            front,
            back,
            example ?? "",
            tags.joined(separator: ","),
            reverse ? "TRUE" : "FALSE",
        ]
        // Extras are hashed in header order (D1) so reordering columns in Sheets
        // registers as a change — the display order is part of the content.
        for key in extraOrder {
            parts.append(key)
            parts.append(extras[key] ?? "")
        }
        let joined = parts.joined(separator: unit)
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
