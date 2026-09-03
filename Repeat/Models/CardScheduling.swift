import Foundation
import SwiftData
import Scheduling

/// Bridges the SwiftData `Card` to the value types the `Scheduling` package works
/// in. The app never imports FSRS; everything crosses here.
extension Card {
    /// The card's scheduling fields as a value.
    var snapshot: CardSchedulingSnapshot {
        CardSchedulingSnapshot(
            state: state, due: due, stability: stability, difficulty: difficulty,
            elapsedDays: elapsedDays, scheduledDays: scheduledDays,
            reps: reps, lapses: lapses, lastReview: lastReview,
            learningStepIndex: learningStepIndex, isSuspended: isSuspended
        )
    }

    /// Writes a snapshot back onto the model. Used by rating, by undo (§5.5) and
    /// by backup restore (§8) — one implementation, so "reproduces due dates
    /// exactly" means the same thing in all three.
    func restore(from snapshot: CardSchedulingSnapshot) {
        state = snapshot.state
        due = snapshot.due
        stability = snapshot.stability
        difficulty = snapshot.difficulty
        elapsedDays = snapshot.elapsedDays
        scheduledDays = snapshot.scheduledDays
        reps = snapshot.reps
        lapses = snapshot.lapses
        lastReview = snapshot.lastReview
        learningStepIndex = snapshot.learningStepIndex
        isSuspended = snapshot.isSuspended
    }
}

extension ModelContext {
    /// Rates a card: applies the scheduler's result and inserts the `_log` row.
    /// Returns the log so the caller can offer undo on it.
    @discardableResult
    func rate(
        _ card: Card,
        _ grade: Grade,
        with scheduler: Scheduler,
        now: Date = .now
    ) throws -> ReviewLog {
        let outcome = try scheduler.apply(grade, to: card.snapshot, now: now)
        let log = try ReviewLog(card: card, outcome: outcome)
        card.restore(from: outcome.snapshot)
        insert(log)
        return log
    }
}
