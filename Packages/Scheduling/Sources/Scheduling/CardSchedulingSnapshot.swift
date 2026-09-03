import Foundation

/// Every scheduling field of a card, as a value.
///
/// This is the currency between the app's SwiftData `Card` and the scheduler: the
/// app maps its model to one of these, the scheduler returns a new one, and the
/// app writes it back. It is also what undo restores (§5.5) and what the nightly
/// backup serialises (§8), so "restore reproduces due dates exactly" has exactly
/// one definition to satisfy.
public struct CardSchedulingSnapshot: Codable, Equatable, Sendable {
    public var state: SchedulingState
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    public var elapsedDays: Int
    public var scheduledDays: Int
    public var reps: Int
    public var lapses: Int
    public var lastReview: Date?
    /// 0-based index into the configured learning / relearning steps. Only
    /// meaningful in `.learning` and `.relearning`. Carried because FSRS keeps it
    /// on its own card: without it, a card part-way through `1m, 10m` would
    /// restart its steps every time the app relaunched.
    public var learningStepIndex: Int
    public var isSuspended: Bool

    public init(
        state: SchedulingState = .new,
        due: Date = .now,
        stability: Double = 0,
        difficulty: Double = 0,
        elapsedDays: Int = 0,
        scheduledDays: Int = 0,
        reps: Int = 0,
        lapses: Int = 0,
        lastReview: Date? = nil,
        learningStepIndex: Int = 0,
        isSuspended: Bool = false
    ) {
        self.state = state
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.reps = reps
        self.lapses = lapses
        self.lastReview = lastReview
        self.learningStepIndex = learningStepIndex
        self.isSuspended = isSuspended
    }
}

extension CardSchedulingSnapshot {
    /// Deterministic encoding.
    ///
    /// `JSONEncoder` does not order keys unless told to, so two encodes of an
    /// identical snapshot can differ byte for byte. That matters because this blob
    /// is persisted in `ReviewLog.prevState` and copied into the nightly backup
    /// (§8): without a stable encoding, "the backup is unchanged" and "this undo
    /// snapshot is the one we wrote" are both unanswerable by comparison.
    /// Note the *absence* of a date strategy. `.iso8601` truncates to whole
    /// seconds, which would move a restored `due` by up to a second — enough to
    /// break "undo restores due exactly" (§5.5) and every replay comparison in
    /// #41. The default encodes the full-precision time interval.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> CardSchedulingSnapshot {
        try decoder.decode(CardSchedulingSnapshot.self, from: data)
    }
}
