import Foundation

/// §5.7 — experience points and levels.
///
/// **This card ships under a standing recommendation to cut it** (spec §5.7, and
/// card #113 itself): it measures taps rather than vocabulary, and it competes
/// with the count on Home. It is built so the decision can be made with it
/// running, which is what the card asks for — and built to be deleted in one
/// piece if the answer is no.
///
/// Derived from `_log` like everything else in §2.1. Nothing is stored, so an
/// undo, a restore and a rebuild all produce the right number without anything
/// having to be corrected.
enum XP {

    /// §5.7's table: the harder you found it, the less it was worth.
    static func points(forRating rating: Int) -> Int {
        switch rating {
        case 1: 1   // Знову
        case 2: 2   // Важко
        case 3: 3   // Добре
        case 4: 4   // Легко
        default: 0  // 0 is an undo marker, not a grade (§5.5)
        }
    }

    /// XP needed to reach `level`: 100·n·(n+1)/2, which is 50·n·(n+1).
    static func threshold(forLevel level: Int) -> Int {
        guard level > 0 else { return 0 }
        return 50 * level * (level + 1)
    }

    /// The level `xp` has reached. Level 0 is a real answer — the spec says
    /// level *n* **needs** 100·n·(n+1)/2, and nobody has earned level 1 before
    /// their first hundred points. The chip declines to draw itself there rather
    /// than announcing a zero.
    static func level(xp: Int) -> Int {
        guard xp > 0 else { return 0 }
        var level = 0
        while threshold(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    /// How far into the current level `xp` is, as points earned and points
    /// needed. `nil` at level 0 has no meaning worth showing, so it is not a
    /// special case here — the caller decides whether to draw it.
    static func progress(xp: Int) -> (into: Int, outOf: Int) {
        let level = level(xp: xp)
        let floor = threshold(forLevel: level)
        let ceiling = threshold(forLevel: level + 1)
        return (xp - floor, ceiling - floor)
    }

    // MARK: - From the log

    /// Total XP, with undone reviews taken back out.
    ///
    /// Undo has two shapes (§5.5). A review that has not reached the Sheet is
    /// **deleted**, so it never reaches this function at all. One that has been
    /// uploaded cannot be withdrawn, so a `rating: 0` marker is written beside
    /// it and the original row stays — which means filtering markers out, the way
    /// `Streak` and `Records` do, would leave the undone review's points standing.
    ///
    /// So each marker cancels the most recent earlier review of the **same card
    /// and direction** that has not already been cancelled. That is exactly what
    /// the undo it records did: undo always takes back the latest rating of that
    /// card. Ordering is `(reviewedAt, position)` for the reason `LogReplay`
    /// gives — a timestamp alone is not a total order, and an unstable one would
    /// make the same log produce different totals on different runs.
    static func total(logs: [ReviewLog]) -> Int {
        // Almost every log has no undo markers at all, and on the Stats path this
        // runs over the owner's whole history — #116's lesson is that a per-pass
        // walk is where this app's time actually goes. Without markers the answer
        // is a plain sum: no sort, no dictionary, no allocation per row.
        //
        // This is not premature: the pairing version below cost **452 ms** on the
        // 10 000-card fixture and broke §6.5's 300 ms budget for Stats. Measured,
        // not guessed.
        var total = 0
        var markers = 0
        for log in logs {
            if log.rating == 0 { markers += 1 } else { total += points(forRating: log.rating) }
        }
        guard markers > 0 else { return total }
        return totalPairingUndos(logs: logs)
    }

    /// One key per card and direction, without building a string for each row.
    private struct CardKey: Hashable {
        let cardId: String
        let direction: Direction
    }

    /// The exact answer, for a log that actually contains undo markers.
    ///
    /// Ordering is `(reviewedAt, position)` for the reason `LogReplay` gives — a
    /// timestamp alone is not a total order, and an unstable one would make the
    /// same log produce different totals on different runs.
    private static func totalPairingUndos(logs: [ReviewLog]) -> Int {
        let ordered = logs.enumerated().sorted {
            $0.element.reviewedAt == $1.element.reviewedAt
                ? $0.offset < $1.offset
                : $0.element.reviewedAt < $1.element.reviewedAt
        }.map(\.element)

        // Per card+direction, the ratings seen so far that are still standing.
        var standing: [CardKey: [Int]] = [:]
        var total = 0
        for log in ordered {
            let key = CardKey(cardId: log.cardId, direction: log.direction)
            if log.rating == 0 {
                guard let undone = standing[key]?.popLast() else { continue }
                total -= points(forRating: undone)
            } else {
                standing[key, default: []].append(log.rating)
                total += points(forRating: log.rating)
            }
        }
        return total
    }

    static func level(logs: [ReviewLog]) -> Int {
        level(xp: total(logs: logs))
    }
}
