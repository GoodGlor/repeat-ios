import XCTest
@testable import Scheduling

/// Card #4 acceptance.
final class SchedulerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The preview must not be able to lie

    /// The whole reason preview and apply share an engine call: a button that says
    /// `3d` and then schedules something else is a silent trust failure.
    func testPreviewMatchesWhatApplyingActuallySchedules() throws {
        let scheduler = Scheduler()
        for (name, card, at) in try parityCases(scheduler) {
            let preview = try scheduler.preview(for: card, now: at)
            for grade in Grade.allCases {
                let predicted = try XCTUnwrap(preview[grade], "\(name) \(grade)")
                let applied = try scheduler.apply(grade, to: card, now: at)
                XCTAssertEqual(
                    predicted.due, applied.snapshot.due,
                    "\(name)/\(grade): button promised \(predicted.label)"
                )
                XCTAssertEqual(predicted.resultingState, applied.snapshot.state, "\(name)/\(grade)")
            }
        }
    }

    /// Every state, plus the two shapes #122 actually broke.
    ///
    /// The four-state sweep alone does not reach them: its synthetic `.learning`
    /// card carries `learningStepIndex 0`, so `Good` gives it `10m` and it never
    /// graduates — which is exactly why the collapse survived this test for so
    /// long. The last two cases are cards that really are one `Good` away from
    /// leaving their steps.
    private func parityCases(_ scheduler: Scheduler) throws -> [(String, CardSchedulingSnapshot, Date)] {
        var cases: [(String, CardSchedulingSnapshot, Date)] = SchedulingState.allCases.map { state in
            var card = CardSchedulingSnapshot(state: state, due: now)
            if state != .new {
                card.stability = 8
                card.difficulty = 5
                card.reps = 4
                card.scheduledDays = 8
                card.lastReview = now.addingTimeInterval(-8 * 86_400)
            }
            return ("\(state)", card, now)
        }

        let graduating = try walk([.again, .good], from: CardSchedulingSnapshot(due: now), with: scheduler)
        cases.append(("learning, one Good from graduating", graduating.card, graduating.at))

        let lapsed = try scheduler.apply(.again, to: reviewCard(stability: 2), now: now).snapshot
        cases.append(("relearning after a lapse", lapsed, lapsed.due))

        return cases
    }

    func testAllFourGradesArePreviewed() throws {
        let preview = try Scheduler().preview(for: CardSchedulingSnapshot(due: now), now: now)
        XCTAssertEqual(Set(preview.keys), Set(Grade.allCases))
    }

    // MARK: - State transitions follow the configured steps (D3)

    /// Anki semantics, which FSRS's short-term scheduler follows: on a new card
    /// `Again` sits on step 1 and `Good` advances to step 2 — `Good` does not
    /// replay `1m`. Asserting the other way round is the easy mistake, so the
    /// real behaviour is pinned here.
    func testNewCardEntersTheConfiguredLearningSteps() throws {
        let scheduler = Scheduler()
        let fresh = CardSchedulingSnapshot(due: now)

        let again = try scheduler.apply(.again, to: fresh, now: now).snapshot
        XCTAssertEqual(again.state, .learning)
        XCTAssertEqual(again.due.timeIntervalSince(now) / 60, 1, accuracy: 0.5, "Again holds step 1 (1m)")

        let good = try scheduler.apply(.good, to: fresh, now: now).snapshot
        XCTAssertEqual(good.state, .learning)
        XCTAssertEqual(good.due.timeIntervalSince(now) / 60, 10, accuracy: 0.5, "Good advances to step 2 (10m)")

        let easy = try scheduler.apply(.easy, to: fresh, now: now).snapshot
        XCTAssertEqual(easy.state, .review, "Easy graduates immediately")
        XCTAssertGreaterThan(easy.due.timeIntervalSince(now), 86_400)
    }

    func testGoodOnTheLastLearningStepGraduatesToReview() throws {
        let scheduler = Scheduler()
        let onLastStep = try scheduler.apply(.good, to: CardSchedulingSnapshot(due: now), now: now).snapshot
        let at = onLastStep.due

        let graduated = try scheduler.apply(.good, to: onLastStep, now: at).snapshot
        XCTAssertEqual(graduated.state, .review)
        XCTAssertGreaterThan(graduated.due.timeIntervalSince(at), 86_400,
                             "leaving learning means an interval measured in days")
    }

    // MARK: - #122: Easy has to buy something Good does not

    /// Graduating out of learning is the one transition FSRS computes a grade at
    /// a time: `newState` and `learningState` call `applyLearningSteps` per grade,
    /// and only `reviewState` runs `nextIntervalReview` to order them against each
    /// other. On a card whose stability is still low — any card rated `Again` at
    /// least once — Good and Easy both fall under `nextInterval`'s `max(1, …)`
    /// floor, land on the same day, and `Easy` promises nothing.
    ///
    /// A card walked straight `new → Good → Good` does *not* show it: its
    /// stability is high enough to give Good `2d` and Easy `4d`. That is why the
    /// setup here rates `Again` first.
    func testEasyBeatsGoodWhenALearningCardGraduates() throws {
        let scheduler = Scheduler()
        let onLastStep = try walk([.again, .good], from: CardSchedulingSnapshot(due: now), with: scheduler)
        let at = onLastStep.card.due

        let good = try scheduler.apply(.good, to: onLastStep.card, now: at).snapshot
        let easy = try scheduler.apply(.easy, to: onLastStep.card, now: at).snapshot

        XCTAssertEqual(onLastStep.card.state, .learning, "the setup has to still be in learning")
        XCTAssertEqual(good.state, .review, "…and Good has to be the step that graduates it")
        XCTAssertEqual(easy.state, .review)
        XCTAssertGreaterThanOrEqual(easy.due.timeIntervalSince(good.due), 86_400,
                                    "Easy must buy at least a day over Good")
        XCTAssertGreaterThan(easy.scheduledDays, good.scheduledDays,
                             "the `_log` figure moves with the due date, or replay undoes it")
    }

    /// The same collapse on the far more common path: a review card that lapsed.
    /// This is the shape in the owner's screenshot — `Again 10m` and `Hard 15m`
    /// are the single relearning step and that step × 1.5.
    func testEasyBeatsGoodWhenARelearningCardGraduates() throws {
        let scheduler = Scheduler()
        let lapsed = try scheduler.apply(.again, to: reviewCard(stability: 2), now: now).snapshot
        let at = lapsed.due

        let good = try scheduler.apply(.good, to: lapsed, now: at).snapshot
        let easy = try scheduler.apply(.easy, to: lapsed, now: at).snapshot

        XCTAssertEqual(lapsed.state, .relearning)
        XCTAssertEqual(good.state, .review)
        XCTAssertGreaterThanOrEqual(easy.due.timeIntervalSince(good.due), 86_400)
        XCTAssertGreaterThan(easy.scheduledDays, good.scheduledDays)
    }

    /// The owner-visible symptom, in the owner's terms: the row read
    /// `Again 10m · Hard 15m · Good 1d · Easy 1d` — four buttons, three promises.
    func testTheGraduatingRatingRowShowsFourDifferentLabels() throws {
        let scheduler = Scheduler()
        let lapsed = try scheduler.apply(.again, to: reviewCard(stability: 2), now: now).snapshot

        let previews = try scheduler.preview(for: lapsed, now: lapsed.due)
        let labels = try Grade.allCases.map { try XCTUnwrap(previews[$0]).label }

        XCTAssertEqual(Set(labels).count, 4, "the row read \(labels.joined(separator: " · "))")
    }

    /// Nothing may be adjusted on a card already in review: `nextIntervalReview`
    /// has ordered the grades there since before #122, and the fix must be a
    /// no-op rather than a second, competing rule.
    func testAReviewCardsIntervalsAreLeftExactlyAsFsrsSetThem() throws {
        let scheduler = Scheduler()
        for stability in [1.0, 2.0, 3.0, 6.0, 15.0, 60.0] {
            let card = reviewCard(stability: stability)
            let preview = try scheduler.preview(for: card, now: now)
            for grade in Grade.allCases {
                let promised = try XCTUnwrap(preview[grade])
                let applied = try scheduler.apply(grade, to: card, now: now)
                XCTAssertEqual(promised.due, applied.snapshot.due, "s=\(stability) \(grade)")
            }
            let dues = try Grade.allCases.map { try XCTUnwrap(preview[$0]).due }
            XCTAssertEqual(dues, dues.sorted(), "s=\(stability): Again ≤ Hard ≤ Good ≤ Easy")
        }
    }

    // MARK: - Helpers

    private func reviewCard(stability: Double) -> CardSchedulingSnapshot {
        CardSchedulingSnapshot(
            state: .review, due: now, stability: stability, difficulty: 6,
            scheduledDays: Int(stability), reps: 5,
            lastReview: now.addingTimeInterval(-stability * 86_400)
        )
    }

    /// Rates a card through a sequence, each rating at the previous one's due
    /// date — the only way to reach a low-stability card sitting on its last
    /// learning step.
    private func walk(
        _ grades: [Grade],
        from start: CardSchedulingSnapshot,
        with scheduler: Scheduler
    ) throws -> (card: CardSchedulingSnapshot, at: Date) {
        var card = start
        var at = now
        for grade in grades {
            card = try scheduler.apply(grade, to: card, now: at).snapshot
            at = card.due
        }
        return (card, at)
    }

    func testAgainOnAReviewCardRelearnsAndCountsALapse() throws {
        let scheduler = Scheduler()
        let card = CardSchedulingSnapshot(
            state: .review, due: now, stability: 20, difficulty: 5,
            scheduledDays: 20, reps: 6, lapses: 1,
            lastReview: now.addingTimeInterval(-20 * 86_400)
        )
        let outcome = try scheduler.apply(.again, to: card, now: now)
        XCTAssertEqual(outcome.snapshot.state, .relearning)
        XCTAssertEqual(outcome.snapshot.lapses, 2)
        XCTAssertEqual(outcome.snapshot.due.timeIntervalSince(now) / 60, 10, accuracy: 0.5)
    }

    func testEasyIsAlwaysScheduledFurtherOutThanAgain() throws {
        let scheduler = Scheduler()
        let card = CardSchedulingSnapshot(state: .review, due: now, stability: 15, difficulty: 5,
                                          scheduledDays: 15, reps: 5,
                                          lastReview: now.addingTimeInterval(-15 * 86_400))
        let preview = try scheduler.preview(for: card, now: now)
        let ordered = try Grade.allCases.map { try XCTUnwrap(preview[$0]).due }
        XCTAssertEqual(ordered, ordered.sorted(), "Again ≤ Hard ≤ Good ≤ Easy")
    }

    // MARK: - Outcome carries what the log row needs

    func testOutcomeCarriesThePreviousStateForUndo() throws {
        let card = CardSchedulingSnapshot(state: .review, due: now, stability: 9.5, difficulty: 4.25,
                                          scheduledDays: 9, reps: 3, lapses: 1,
                                          lastReview: now.addingTimeInterval(-9 * 86_400))
        let outcome = try Scheduler().apply(.good, to: card, now: now)
        XCTAssertEqual(outcome.previous, card, "undo restores this verbatim (§5.5)")
        XCTAssertEqual(outcome.stateBefore, .review)
        XCTAssertEqual(outcome.grade, .good)
        XCTAssertEqual(outcome.reviewedAt, now)
        XCTAssertNotEqual(outcome.snapshot, card)
    }

    func testLearningStepIndexIsCarriedSoStepsDoNotRestart() throws {
        let scheduler = Scheduler()
        let first = try scheduler.apply(.good, to: CardSchedulingSnapshot(due: now), now: now)
        XCTAssertEqual(first.snapshot.state, .learning)
        let resumed = try scheduler.apply(.good, to: first.snapshot, now: first.snapshot.due)
        XCTAssertGreaterThan(resumed.snapshot.due.timeIntervalSince(first.snapshot.due), 60 * 5)
    }

    // MARK: - Parameters from the Sheet (§5.1)

    /// `w[0…3]` are the initial stabilities for the four grades, so they move
    /// *new* cards. Tweaking them and then measuring a review card — the obvious
    /// setup — changes nothing and would make this test pass vacuously.
    func testCustomWeightsChangeIntervalsWithoutARebuild() throws {
        let fresh = CardSchedulingSnapshot(due: now)
        let stock = try Scheduler().preview(for: fresh, now: now)

        var tweaked = SchedulerConfig().weights
        for index in 0..<4 { tweaked[index] *= 3 }
        let custom = try Scheduler(config: SchedulerConfig(weights: tweaked)).preview(for: fresh, now: now)

        XCTAssertGreaterThan(
            try XCTUnwrap(custom[.easy]).interval, try XCTUnwrap(stock[.easy]).interval,
            "tripling initial stability must push the graduating interval out"
        )
    }

    func testDesiredRetentionChangesIntervals() throws {
        let card = CardSchedulingSnapshot(state: .review, due: now, stability: 10, difficulty: 5,
                                          scheduledDays: 10, reps: 4,
                                          lastReview: now.addingTimeInterval(-10 * 86_400))
        let relaxed = try Scheduler(config: SchedulerConfig(desiredRetention: 0.80))
            .preview(for: card, now: now)[.good]
        let strict = try Scheduler(config: SchedulerConfig(desiredRetention: 0.95))
            .preview(for: card, now: now)[.good]
        XCTAssertGreaterThan(try XCTUnwrap(relaxed).interval, try XCTUnwrap(strict).interval,
                             "wanting to remember less means waiting longer")
    }

    /// The dangerous case: FSRS infers its version from the weight count, so a
    /// wrong-length paste would silently downgrade every future interval.
    func testWrongLengthWeightsAreRejectedRatherThanSilentlyDowngrading() {
        let nineteen = "[\(Array(repeating: "0.5", count: 19).joined(separator: ","))]"
        XCTAssertThrowsError(try SchedulerConfig.weights(fromMeta: nineteen)) { error in
            XCTAssertEqual(error as? SchedulerConfig.ParameterError, .wrongWeightCount(found: 19))
        }
        let twenty = "[\(Array(repeating: "0.5", count: 20).joined(separator: ","))]"
        XCTAssertThrowsError(try SchedulerConfig.weights(fromMeta: twenty))
        XCTAssertThrowsError(try SchedulerConfig.weights(fromMeta: "not json"))
        XCTAssertThrowsError(try SchedulerConfig.weights(fromMeta: "[\"a\"]"))
    }

    func testTwentyOneWeightsAreAcceptedAndSelectVersionSix() throws {
        let raw = "[" + SchedulerConfig().weights.map { String($0) }.joined(separator: ",") + "]"
        let parsed = try SchedulerConfig.weights(fromMeta: raw)
        XCTAssertEqual(parsed.count, 21)
        XCTAssertEqual(Scheduler(config: SchedulerConfig(weights: parsed)).algorithmVersion, .v6)
    }

    func testDefaultConfigurationIsFsrs6WithSpecSteps() {
        let config = SchedulerConfig()
        XCTAssertEqual(config.weights.count, 21)
        XCTAssertEqual(Scheduler().algorithmVersion, .v6)
        XCTAssertEqual(config.learningSteps, ["1m", "10m"])
        XCTAssertEqual(config.relearningSteps, ["10m"])
        XCTAssertFalse(config.enableFuzz, "replay from _log must be deterministic (D4)")
    }

    func testRetentionParsingClampsToTheSettingsRange() throws {
        XCTAssertEqual(try SchedulerConfig.retention(fromMeta: " 0.87 "), 0.87)
        XCTAssertThrowsError(try SchedulerConfig.retention(fromMeta: "0.5"))
        XCTAssertThrowsError(try SchedulerConfig.retention(fromMeta: "0.99"))
        XCTAssertThrowsError(try SchedulerConfig.retention(fromMeta: "high"))
    }

    // MARK: - Determinism (D4 depends on this)

    func testApplyingTheSameRatingTwiceGivesTheSameResult() throws {
        let scheduler = Scheduler()
        let card = CardSchedulingSnapshot(state: .review, due: now, stability: 13, difficulty: 6,
                                          scheduledDays: 13, reps: 7,
                                          lastReview: now.addingTimeInterval(-13 * 86_400))
        let a = try scheduler.apply(.good, to: card, now: now)
        let b = try scheduler.apply(.good, to: card, now: now)
        XCTAssertEqual(a.snapshot, b.snapshot, "fuzz is off, so replay reproduces due dates (D4)")
    }

    // MARK: - Labels

    /// The locale is explicit: these labels are localised now, so "what does the
    /// button say" has no answer without one, and a package test that read the
    /// host's language would pass or fail by machine.
    private static let en = Locale(identifier: "en_US")
    private static let uk = Locale(identifier: "uk_UA")

    func testIntervalLabelsMatchTheMockup() {
        XCTAssertEqual(IntervalFormatter.short(60, locale: Self.en), "1m")
        // FSRS hands back a 1-minute step as slightly under 60s; it must still
        // read "1m", not "<1m".
        XCTAssertEqual(IntervalFormatter.short(59.99, locale: Self.en), "1m")
        XCTAssertEqual(IntervalFormatter.short(20, locale: Self.en), "<1m")
        XCTAssertEqual(IntervalFormatter.short(600, locale: Self.en), "10m")
        XCTAssertEqual(IntervalFormatter.short(3 * 86_400, locale: Self.en), "3d")
        XCTAssertEqual(IntervalFormatter.short(12 * 86_400, locale: Self.en), "12d")
        XCTAssertEqual(IntervalFormatter.short(2 * 3600, locale: Self.en), "2h")
        XCTAssertEqual(IntervalFormatter.short(0, locale: Self.en), "<1m")
        XCTAssertEqual(IntervalFormatter.short(-5, locale: Self.en), "<1m")
        XCTAssertTrue(IntervalFormatter.spoken(3 * 86_400, locale: Self.en).contains("3"))
    }

    /// Months and years are the units `string(from: TimeInterval)` cannot do —
    /// it returns zero for every one of them, which reached the screen as
    /// "Добре 0м". Nothing before this exercised intervals past a month.
    func testLongIntervalsAreNotZero() {
        for (days, expected) in [(45.0, "1.5"), (100.0, "3.3"), (400.0, "13.3"), (800.0, "2.2")] {
            let label = IntervalFormatter.short(days * 86_400, locale: Self.en)
            XCTAssertTrue(label.contains(expected),
                          "\(days) days rendered as \"\(label)\"")
            XCTAssertFalse(label.hasPrefix("0"), "\(days) days rendered as \"\(label)\"")
        }
    }

    /// Sweeps every day from a minute to five years rather than sampling.
    ///
    /// A "0м" label shipped because the sampled values — 45, 100, 400 — all sat
    /// clear of the boundary where a 30-day month, converted back to seconds and
    /// measured by the calendar from 1 January, rounds to zero months. Anything
    /// that renders a leading zero or an empty label is wrong at every input.
    func testNoIntervalRendersAsZeroOrEmpty() {
        for locale in [Self.en, Self.uk] {
            for day in 1...(365 * 5) {
                let label = IntervalFormatter.short(Double(day) * 86_400, locale: locale)
                XCTAssertFalse(label.isEmpty, "day \(day) rendered nothing")
                XCTAssertFalse(label.hasPrefix("0"),
                               "day \(day) rendered \"\(label)\" in \(locale.identifier)")
            }
            for minute in 1...(60 * 47) {
                let label = IntervalFormatter.short(Double(minute) * 60, locale: locale)
                XCTAssertFalse(label.isEmpty, "minute \(minute) rendered nothing")
                XCTAssertFalse(label.hasPrefix("0"),
                               "minute \(minute) rendered \"\(label)\"")
            }
        }
    }

    /// The exact values from the screenshot: 31, 34 and 40 days all read "0м".
    func testTheIntervalsThatShippedAsZeroMonths() {
        for days in [30.0, 31.0, 34.0, 40.0, 44.0] {
            let label = IntervalFormatter.short(days * 86_400, locale: Self.en)
            XCTAssertTrue(label.hasPrefix("1"), "\(days) days rendered as \"\(label)\"")
        }
    }

    /// The defect #37's XXL screenshot exposed: the rating buttons read "10m" and
    /// "15d" under Ukrainian copy, because these abbreviations were hardcoded
    /// Latin with a comment deferring them to #38 — and #38 localised the app
    /// target, not this package.
    func testIntervalLabelsFollowTheLocale() {
        let day = IntervalFormatter.short(3 * 86_400, locale: Self.uk)
        XCTAssertTrue(day.contains("3"), day)
        XCTAssertFalse(day.hasSuffix("d"), "\(day) is still the Latin abbreviation")

        let minutes = IntervalFormatter.short(600, locale: Self.uk)
        XCTAssertTrue(minutes.contains("10"), minutes)
        XCTAssertFalse(minutes.hasSuffix("m"), "\(minutes) is still the Latin abbreviation")

        // And the two languages must actually differ, or the test above would
        // pass on a formatter that quietly fell back to English.
        XCTAssertNotEqual(IntervalFormatter.short(3 * 86_400, locale: Self.uk),
                          IntervalFormatter.short(3 * 86_400, locale: Self.en))
    }
}
