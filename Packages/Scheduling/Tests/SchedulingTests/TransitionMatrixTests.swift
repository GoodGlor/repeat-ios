import XCTest
@testable import Scheduling

/// Card #9: grade mapping and state transitions across all four states.
///
/// `SchedulerTests` covers the paths a session walks. This covers the whole
/// 4 × 4 grid, including the combinations a normal session rarely produces —
/// which are exactly the ones a scheduling regression would hide in.
final class TransitionMatrixTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scheduler = Scheduler()

    private func card(in state: SchedulingState) -> CardSchedulingSnapshot {
        switch state {
        case .new:
            CardSchedulingSnapshot(due: now)
        case .learning:
            CardSchedulingSnapshot(state: .learning, due: now, stability: 0.5, difficulty: 5,
                                   scheduledDays: 0, reps: 1,
                                   lastReview: now.addingTimeInterval(-600), learningStepIndex: 1)
        case .review:
            CardSchedulingSnapshot(state: .review, due: now, stability: 18, difficulty: 5,
                                   scheduledDays: 18, reps: 7, lapses: 1,
                                   lastReview: now.addingTimeInterval(-18 * 86_400))
        case .relearning:
            CardSchedulingSnapshot(state: .relearning, due: now, stability: 2, difficulty: 7,
                                   scheduledDays: 0, reps: 9, lapses: 3,
                                   lastReview: now.addingTimeInterval(-600))
        }
    }

    /// The invariants that must hold whatever the parameters are.
    func testEveryStateAndGradeCombinationLandsInALegalState() throws {
        for state in SchedulingState.allCases {
            for grade in Grade.allCases {
                let result = try scheduler.apply(grade, to: card(in: state), now: now).snapshot
                let context = "\(state) + \(grade)"

                XCTAssertNotEqual(result.state, .new, "\(context): nothing returns to new")
                XCTAssertGreaterThan(result.due, now, "\(context): must be scheduled forward")

                switch (state, grade) {
                case (_, .easy):
                    XCTAssertEqual(result.state, .review, "\(context): Easy always graduates")
                case (.new, _), (.learning, .again):
                    XCTAssertEqual(result.state, .learning, context)
                case (.review, .again), (.relearning, .again):
                    XCTAssertEqual(result.state, .relearning, context)
                case (.review, _):
                    XCTAssertEqual(result.state, .review, "\(context): only Again leaves review")
                default:
                    XCTAssertTrue([.learning, .relearning, .review].contains(result.state), context)
                }
            }
        }
    }

    func testOnlyAgainOnALearnedCardCountsALapse() throws {
        for state in SchedulingState.allCases {
            let before = card(in: state)
            for grade in Grade.allCases {
                let after = try scheduler.apply(grade, to: before, now: now).snapshot
                let expected = (grade == .again && state == .review) ? before.lapses + 1 : before.lapses
                XCTAssertEqual(after.lapses, expected, "\(state) + \(grade)")
            }
        }
    }

    func testEveryRatingCountsARep() throws {
        for state in SchedulingState.allCases {
            let before = card(in: state)
            for grade in Grade.allCases {
                let after = try scheduler.apply(grade, to: before, now: now).snapshot
                XCTAssertEqual(after.reps, before.reps + 1, "\(state) + \(grade)")
                XCTAssertEqual(after.lastReview, now, "\(state) + \(grade)")
            }
        }
    }

    /// The raw values are a wire format: they are written to `_log`'s `rating`
    /// column (§3.1) and read back by #41's replay, so they cannot be renumbered
    /// for convenience.
    func testGradeRawValuesAreTheLogWireFormat() {
        XCTAssertEqual(Grade.again.rawValue, 1)
        XCTAssertEqual(Grade.hard.rawValue, 2)
        XCTAssertEqual(Grade.good.rawValue, 3)
        XCTAssertEqual(Grade.easy.rawValue, 4)
        XCTAssertNil(Grade(rawValue: 0), "0 is reserved for undo markers (§5.5)")
        XCTAssertEqual(Grade.allCases.count, 4)
    }

    func testSchedulingStateRawValuesAreStable() {
        // Persisted in SwiftData and encoded into ReviewLog.prevState; renumbering
        // would silently reinterpret every stored card.
        XCTAssertEqual(SchedulingState.new.rawValue, 0)
        XCTAssertEqual(SchedulingState.learning.rawValue, 1)
        XCTAssertEqual(SchedulingState.review.rawValue, 2)
        XCTAssertEqual(SchedulingState.relearning.rawValue, 3)
    }

    /// #41 replays `_log` through the scheduler to rebuild every due date, so a
    /// whole sequence — not just one rating — has to be reproducible.
    func testReplayingASequenceOfRatingsIsDeterministic() throws {
        let sequence: [Grade] = [.good, .good, .hard, .again, .good, .easy, .good, .again, .hard, .good]

        func replay() throws -> CardSchedulingSnapshot {
            var snapshot = CardSchedulingSnapshot(due: now)
            var at = now
            for grade in sequence {
                snapshot = try scheduler.apply(grade, to: snapshot, now: at).snapshot
                at = snapshot.due
            }
            return snapshot
        }

        let first = try replay()
        let second = try replay()
        XCTAssertEqual(first, second, "fuzz is off, so replay must reproduce due dates exactly (D4)")
        XCTAssertEqual(first.reps, sequence.count)
        // The card reaches review twice before an Again in this sequence, so two
        // of the two Agains land on a review card and both count.
        XCTAssertEqual(first.lapses, 2)
    }

    /// The undo snapshot travels through JSON in `ReviewLog.prevState`, so
    /// equality of the struct is not enough — the encoding has to round-trip too.
    func testSnapshotRoundTripsThroughItsEncodedForm() throws {
        let original = card(in: .review)
        let encoded = try original.encoded()
        let decoded = try CardSchedulingSnapshot.decoded(from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try decoded.encoded(), encoded, "byte-identical")
        // A plain JSONEncoder does not order keys, which is why the package owns
        // this: two encodes of the same value could otherwise differ.
        XCTAssertEqual(try original.encoded(), try original.encoded())

        // Sub-second precision must survive: an ISO-8601 style encoding would
        // truncate it and move a restored due date by up to a second, which is
        // enough to break §5.5 and #41.
        let precise = CardSchedulingSnapshot(
            state: .review,
            due: Date(timeIntervalSinceReferenceDate: 800_000_000.123456),
            lastReview: Date(timeIntervalSinceReferenceDate: 799_000_000.987654)
        )
        let restored = try CardSchedulingSnapshot.decoded(from: try precise.encoded())
        XCTAssertEqual(restored.due.timeIntervalSinceReferenceDate,
                       precise.due.timeIntervalSinceReferenceDate, accuracy: 1e-9)
        XCTAssertEqual(restored, precise)
    }
}
