import Foundation
import Scheduling

/// Reproduces scheduling by replaying `_log` through FSRS (§8, D4).
///
/// This is the recovery path that survives losing the phone, which a local
/// snapshot does not — and the reason the iCloud Drive mirror was dropped rather
/// than built. It works only because fuzz is disabled on the pinned FSRS revision
/// (`4fbaf20`): with fuzz on, two replays of the same history would produce
/// different due dates and this card would be impossible. **Do not bump that pin
/// casually.**
///
/// Deliberately free of SwiftData and of the network: everything here is value
/// code, so a 5k-row replay can run off the main actor without sending a model
/// across an actor boundary.
enum LogReplay {

    struct Row: Equatable, Sendable {
        let cardId: String
        let grade: Grade
        let reviewedAt: Date
    }

    struct Parse: Equatable, Sendable {
        var rows: [Row] = []
        /// `rating == 0` — undo markers (§5.5), not reviews. `Streak` and
        /// `StatsSummary` filter the same way; this is the third reader of that
        /// rule and the last place it should ever be restated.
        var undoMarkers = 0
        /// Rows that could not be read at all. Reported rather than dropped
        /// silently: a `_log` the owner has hand-edited is exactly when someone
        /// needs to know.
        var malformed = 0

        var reviewCount: Int { rows.count }
    }

    // MARK: - Parsing

    /// Column order comes from the header row when there is one.
    ///
    /// `LogPush` writes positionally because only the phone touches this sheet,
    /// but a rebuild is run precisely when something has gone wrong — including a
    /// sheet someone has reordered by hand — so reading is header-mapped where
    /// possible and positional only as a fallback.
    static func parse(_ values: [[String]],
                      timestamp: ISO8601DateFormatter = SheetPush.timestamp) -> Parse {
        var parse = Parse()
        guard !values.isEmpty else { return parse }

        var body = values[..<values.count]
        var layout = positionalColumns
        if let mapped = columns(fromHeader: values[0]) {
            layout = mapped
            body = values[1...]
        }

        for row in body {
            // A trailing blank line in a worksheet is normal, not malformed.
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            guard let cardId = row[safe: layout.cardId]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !cardId.isEmpty,
                  let ratingText = row[safe: layout.rating],
                  let rating = Int(ratingText.trimmingCharacters(in: .whitespaces))
            else {
                parse.malformed += 1
                continue
            }

            if rating == 0 {
                parse.undoMarkers += 1
                continue
            }

            guard let grade = Grade(rawValue: rating),
                  let reviewedText = row[safe: layout.reviewedAt],
                  let reviewedAt = timestamp.date(from: reviewedText.trimmingCharacters(in: .whitespaces))
            else {
                parse.malformed += 1
                continue
            }

            parse.rows.append(Row(cardId: cardId, grade: grade, reviewedAt: reviewedAt))
        }
        return parse
    }

    struct Columns: Equatable {
        var cardId: Int
        var rating: Int
        var reviewedAt: Int
    }

    static var positionalColumns: Columns {
        Columns(cardId: 0, rating: 2, reviewedAt: 3)
    }

    static func columns(fromHeader row: [String]) -> Columns? {
        let names = row.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let cardId = names.firstIndex(of: "card_id"),
              let rating = names.firstIndex(of: "rating"),
              let reviewedAt = names.firstIndex(of: "reviewed_at")
        else { return nil }
        return Columns(cardId: cardId, rating: rating, reviewedAt: reviewedAt)
    }

    // MARK: - Replay

    /// Folds each card's ratings through FSRS from a fresh card.
    ///
    /// Ordering is `(reviewedAt, position in the sheet)`. The timestamp alone is
    /// not a total order — two reviews of the same card can share a second — and
    /// an unstable order would make the result differ between runs, which is the
    /// one thing this feature cannot afford.
    static func replay(_ rows: [Row], scheduler: Scheduler) -> [String: CardSchedulingSnapshot] {
        var byCard: [String: [(index: Int, row: Row)]] = [:]
        for (index, row) in rows.enumerated() {
            byCard[row.cardId, default: []].append((index, row))
        }

        var result: [String: CardSchedulingSnapshot] = [:]
        result.reserveCapacity(byCard.count)

        for (cardId, entries) in byCard {
            let ordered = entries.sorted {
                $0.row.reviewedAt == $1.row.reviewedAt
                    ? $0.index < $1.index
                    : $0.row.reviewedAt < $1.row.reviewedAt
            }
            var snapshot = CardSchedulingSnapshot()
            var applied = false
            for entry in ordered {
                guard let outcome = try? scheduler.apply(entry.row.grade, to: snapshot,
                                                         now: entry.row.reviewedAt)
                else { continue }
                snapshot = outcome.snapshot
                applied = true
            }
            // A card whose every row failed to apply is left out entirely, so the
            // caller resets it to new rather than storing a half-replayed state.
            if applied { result[cardId] = snapshot }
        }
        return result
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
