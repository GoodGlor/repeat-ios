import Foundation

/// The URL scheme the widget and Shortcuts use (§7.1, §7.4).
///
/// Shared with the widget target so the string is written once — a deep link
/// that silently fails to match is the kind of bug nothing catches.
public enum DeepLink {
    public static let scheme = "repeat"
    /// Straight into a session, with no intermediate screen (§7.1).
    public static let study = "repeat://study"
    public static let add = "repeat://add"

    public enum Destination: Equatable {
        case study
        case add
    }

    public static func destination(for url: URL) -> Destination? {
        guard url.scheme == scheme else { return nil }
        // `repeat://study` parses with `study` as the *host*, not the path — the
        // usual reason a hand-written matcher misses.
        switch url.host()?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "study": return .study
        case "add": return .add
        default: return nil
        }
    }
}
