import Foundation
import FSRS

/// What one rating button will do to the card, computed live (§6.3).
public struct GradePreview: Equatable, Sendable {
    public let grade: Grade
    public let due: Date
    public let interval: TimeInterval
    public let resultingState: SchedulingState

    /// The label on the button.
    public var label: String { IntervalFormatter.short(interval) }
    /// VoiceOver reads the interval as part of the button (§8).
    public var spokenLabel: String { IntervalFormatter.spoken(interval) }
}

/// The result of rating a card: the new scheduling state, plus the numbers the
/// `_log` row needs (§3.1). The caller writes both — this type touches no store.
public struct GradeOutcome: Equatable, Sendable {
    public let snapshot: CardSchedulingSnapshot
    public let previous: CardSchedulingSnapshot
    public let grade: Grade
    public let reviewedAt: Date
    public let elapsedDays: Int
    public let scheduledDays: Int
    public var stateBefore: SchedulingState { previous.state }
}

/// The one seam between the app and `swift-fsrs` (§5.1).
///
/// It is a separate module rather than a file for a concrete reason: the library
/// exports `Card`, `CardState` and `ReviewLog`, all of which the app also
/// declares, and the module name cannot disambiguate them because the package
/// contains a *class* named `FSRS` that shadows it — `FSRS.Card` resolves to a
/// member of the class and fails to compile. Inside this module no such names are
/// declared, so the library's types resolve cleanly, and the app never imports
/// FSRS at all. The boundary is enforced by construction rather than by
/// convention.
///
/// It also keeps the promise the study screen depends on: the intervals shown on
/// the buttons and the intervals actually applied come from the same engine call,
/// so a preview cannot drift from what a tap really does.
public struct Scheduler: Sendable {
    public let config: SchedulerConfig
    private let engine: FSRS

    public init(config: SchedulerConfig = SchedulerConfig()) {
        self.config = config
        self.engine = FSRS(parameters: config.fsrsParameters)
    }

    /// Which FSRS generation the configured weights actually select. Guards
    /// against a dependency downgrade quietly changing everyone's scheduling.
    public var algorithmVersion: AlgorithmVersion {
        AlgorithmVersion.detect(config.weights)
    }

    /// The four next intervals for a card, as the study screen labels them.
    public func preview(
        for snapshot: CardSchedulingSnapshot,
        now: Date = .now
    ) throws -> [Grade: GradePreview] {
        let preview = try engine.repeat(card: card(from: snapshot), now: now)
        var result: [Grade: GradePreview] = [:]
        for grade in Grade.allCases {
            guard let item = preview[grade.fsrs] else { continue }
            result[grade] = GradePreview(
                grade: grade,
                due: item.card.due,
                interval: item.card.due.timeIntervalSince(now),
                resultingState: SchedulingState(item.card.state)
            )
        }
        return result
    }

    /// Applies a rating, returning the new scheduling state alongside the previous
    /// one — the previous is what undo restores (§5.5).
    public func apply(
        _ grade: Grade,
        to snapshot: CardSchedulingSnapshot,
        now: Date = .now
    ) throws -> GradeOutcome {
        let updated = try engine.next(card: card(from: snapshot), now: now, grade: grade.fsrs).card

        var next = snapshot
        next.state = SchedulingState(updated.state)
        next.due = updated.due
        next.stability = updated.stability
        next.difficulty = updated.difficulty
        next.elapsedDays = Int(updated.elapsedDays.rounded())
        next.scheduledDays = Int(updated.scheduledDays.rounded())
        next.reps = updated.reps
        next.lapses = updated.lapses
        next.lastReview = now
        next.learningStepIndex = updated.learningSteps

        return GradeOutcome(
            snapshot: next,
            previous: snapshot,
            grade: grade,
            reviewedAt: now,
            // The engine's own figure — the real gap since the last review, not the
            // value the card was carrying, which is the previous review's gap. `_log`
            // feeds the optimizer and #41's replay, so a stale number here corrupts both.
            elapsedDays: next.elapsedDays,
            scheduledDays: next.scheduledDays
        )
    }

    /// How likely the card is to be recalled right now. #33 uses it to decide
    /// which cards can safely be pushed out of a backlog — the most fragile stay.
    public func retrievability(of snapshot: CardSchedulingSnapshot, now: Date = .now) -> Double {
        engine.getRetrievability(card: card(from: snapshot), now: now).number
    }

    private func card(from snapshot: CardSchedulingSnapshot) -> Card {
        Card(
            due: snapshot.due,
            stability: snapshot.stability,
            difficulty: snapshot.difficulty,
            elapsedDays: Double(snapshot.elapsedDays),
            scheduledDays: Double(snapshot.scheduledDays),
            learningSteps: snapshot.learningStepIndex,
            reps: snapshot.reps,
            lapses: snapshot.lapses,
            state: snapshot.state.fsrs,
            lastReview: snapshot.lastReview
        )
    }
}
