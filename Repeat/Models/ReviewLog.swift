import Foundation
import SwiftData
import Scheduling

/// One review, appended locally and later pushed to the `_log` worksheet (§3.1).
/// Append-only: this is the input the FSRS optimizer runs on, and the history that
/// makes "Rebuild scheduling from `_log`" possible (#41, D4).
@Model
final class ReviewLog {
    var cardId: String
    var direction: Direction
    /// 1–4 for Again/Hard/Good/Easy. `0` marks an undo of an already-uploaded
    /// review (§5.5) and is not a review — replay must skip it.
    var rating: Int
    var reviewedAt: Date
    var elapsedDays: Int
    var scheduledDays: Int
    var stateBefore: SchedulingState
    var uploaded: Bool

    /// The card's scheduling fields immediately before this review, for undo.
    var prevState: Data

    init(
        cardId: String,
        direction: Direction,
        rating: Int,
        reviewedAt: Date = .now,
        elapsedDays: Int,
        scheduledDays: Int,
        stateBefore: SchedulingState,
        prevState: CardSchedulingSnapshot,
        uploaded: Bool = false
    ) throws {
        self.cardId = cardId
        self.direction = direction
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.stateBefore = stateBefore
        self.uploaded = uploaded
        self.prevState = try prevState.encoded()
    }

    func decodedPrevState() throws -> CardSchedulingSnapshot {
        try CardSchedulingSnapshot.decoded(from: prevState)
    }

    /// Builds the log row for a rating the scheduler has just computed, so the
    /// numbers written to `_log` are the scheduler's own rather than a second,
    /// drifting derivation of them.
    convenience init(card: Card, outcome: GradeOutcome) throws {
        try self.init(
            cardId: card.id,
            direction: card.direction,
            rating: outcome.grade.rawValue,
            reviewedAt: outcome.reviewedAt,
            elapsedDays: outcome.elapsedDays,
            scheduledDays: outcome.scheduledDays,
            stateBefore: outcome.stateBefore,
            prevState: outcome.previous
        )
    }
}
