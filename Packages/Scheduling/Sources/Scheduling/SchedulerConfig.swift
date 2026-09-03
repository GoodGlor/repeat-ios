import Foundation
import FSRS

/// Everything that tunes scheduling (§5.1). Defaults are FSRS-6; the Sheet can
/// override weights and retention through `_meta` without a rebuild.
public struct SchedulerConfig: Equatable, Sendable {
    /// §5.1 default 0.90; Settings slider 0.80–0.95.
    public var desiredRetention: Double
    /// FSRS-6 requires 21 weights. The library's `defaultW` is the 19-element v5
    /// vector kept for its own test parity, so v6 must be asked for explicitly —
    /// this is the single place that does so.
    public var weights: [Double]
    /// D3: `1m, 10m` learning, `10m` relearning.
    public var learningSteps: [String]
    public var relearningSteps: [String]
    /// Off, which is what makes "rebuild scheduling from `_log`" deterministic (D4).
    public var enableFuzz: Bool

    public static let fsrs6WeightCount = 21
    public static let retentionRange = 0.80...0.95

    public init(
        desiredRetention: Double = 0.90,
        weights: [Double] = FSRSDefaults.defaultWv6,
        learningSteps: [String] = FSRSDefaults.defaultLearningSteps,
        relearningSteps: [String] = FSRSDefaults.defaultRelearningSteps,
        enableFuzz: Bool = false
    ) {
        self.desiredRetention = desiredRetention
        self.weights = weights
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
        self.enableFuzz = enableFuzz
    }

    var fsrsParameters: FSRSParameters {
        FSRSParameters(
            requestRetention: desiredRetention,
            w: weights,
            enableFuzz: enableFuzz,
            enableShortTerm: true,
            learningSteps: learningSteps,
            relearningSteps: relearningSteps
        )
    }

    public enum ParameterError: Error, Equatable, CustomStringConvertible {
        case notAnArrayOfNumbers
        case wrongWeightCount(found: Int)
        case retentionNotANumber
        case retentionOutOfRange(found: Double)

        public var description: String {
            switch self {
            case .notAnArrayOfNumbers:
                "fsrs_params must be a JSON array of numbers"
            case .wrongWeightCount(let found):
                "fsrs_params must hold exactly \(SchedulerConfig.fsrs6WeightCount) numbers for FSRS-6, found \(found)"
            case .retentionNotANumber:
                "desired_retention must be a number"
            case .retentionOutOfRange(let found):
                "desired_retention must be between 0.80 and 0.95, found \(found)"
            }
        }
    }

    /// Parses `_meta.fsrs_params` (§3.1).
    ///
    /// The length check is not defensive padding. FSRS infers its version from the
    /// weight count, treating any non-21 length as v5 — so a 20-number paste from
    /// the optimizer would silently downgrade every future interval, with no error
    /// anywhere. §5.1 requires rejecting it and surfacing it under "Needs
    /// attention" instead.
    public static func weights(fromMeta raw: String) throws -> [Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([Double].self, from: data)
        else { throw ParameterError.notAnArrayOfNumbers }
        guard parsed.count == fsrs6WeightCount else {
            throw ParameterError.wrongWeightCount(found: parsed.count)
        }
        return parsed
    }

    public static func retention(fromMeta raw: String) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ParameterError.retentionNotANumber
        }
        guard retentionRange.contains(value) else {
            throw ParameterError.retentionOutOfRange(found: value)
        }
        return value
    }
}
