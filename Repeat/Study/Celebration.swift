import Foundation

/// §5.6 — what the Done screen adds this session, below the numbers.
///
/// At most five lines, always in this order: a freeze spent, the day's goal
/// closed, a level gained, a record set, badges unlocked. Nothing applying leaves the Done screen
/// exactly as it was (§2.2: a reward, not a field). The badges line draws at most
/// `tileLimit` tiles and counts the rest, so the screen's two buttons stay on it
/// at the largest accessibility size.
///
/// The freeze goes **first** (#112). It is the only line that reports something
/// that happened *to* the owner rather than something they did, and it explains a
/// streak number that would otherwise look wrong — which outranks the day's goal.
enum Celebration {
    enum Line: Equatable {
        case freezeSpent
        case goalClosed
        /// §5.7 (#113), carrying the level just reached.
        case levelGained(Int)
        case record(Records.Kind)
        case badges([Achievements.Badge])
    }

    /// Five since #113 (four since #112). The badge row still caps its own tiles, which is what
    /// actually governs the height at the largest accessibility size.
    static let lineLimit = 5
    static let tileLimit = 3

    static func lines(
        freezeSpent: Bool = false,
        goalClosed: Bool,
        levelGained: Int? = nil,
        record: Records.Kind?,
        badges: [Achievements.Badge]
    ) -> [Line] {
        var lines: [Line] = []
        if freezeSpent { lines.append(.freezeSpent) }
        if goalClosed { lines.append(.goalClosed) }
        if let levelGained { lines.append(.levelGained(levelGained)) }
        if let record { lines.append(.record(record)) }
        if !badges.isEmpty { lines.append(.badges(badges)) }
        assert(lines.count <= lineLimit)
        return lines
    }

    /// The first `tileLimit` badges to draw, and how many were left over.
    static func tiles(_ badges: [Achievements.Badge]) -> (shown: [Achievements.Badge], more: Int) {
        let shown = Array(badges.prefix(tileLimit))
        return (shown, badges.count - shown.count)
    }
}
