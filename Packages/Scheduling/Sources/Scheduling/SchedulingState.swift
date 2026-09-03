import Foundation
import FSRS

/// FSRS scheduling state.
///
/// Named `SchedulingState` rather than the spec's `CardState` because the library
/// exports `CardState` too, and its module cannot be used to disambiguate: the
/// package `FSRS` also contains a *class* named `FSRS`, which shadows the module,
/// so `FSRS.CardState` resolves to a member of the class and fails. Same reason
/// this module exists at all — see `Scheduler`.
public enum SchedulingState: Int, Codable, CaseIterable, Sendable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3

    /// Mapped case by case rather than through `rawValue`. The two enums agree
    /// today; if upstream renumbers, this stops compiling instead of silently
    /// reinterpreting every stored card's state.
    var fsrs: CardState {
        switch self {
        case .new: .new
        case .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }

    /// The `_log` column's spelling (§3.1). Written out rather than derived from
    /// the case name, because the column is a stored data format: renaming a case
    /// must not silently rewrite years of review history.
    public var logName: String {
        switch self {
        case .new: "new"
        case .learning: "learning"
        case .review: "review"
        case .relearning: "relearning"
        }
    }

    init(_ state: CardState) {
        switch state {
        case .new: self = .new
        case .learning: self = .learning
        case .review: self = .review
        case .relearning: self = .relearning
        }
    }
}

/// What the four rating buttons mean (§5.1). Raw values match the `_log` column.
/// `0` is reserved in `_log` for an undo marker (§5.5) and is deliberately not
/// expressible here.
public enum Grade: Int, CaseIterable, Codable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var fsrs: Rating {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }
}

/// Which FSRS generation the configured weights select.
public enum AlgorithmVersion: Equatable, Sendable {
    case v5, v6

    static func detect(_ weights: [Double]) -> AlgorithmVersion {
        FSRSAlgorithmVersion.detect(weights) == .v6 ? .v6 : .v5
    }
}
