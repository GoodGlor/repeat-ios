import XCTest
import Scheduling
@testable import Repeat

/// #24 — the first-run flow's two promises.
final class OnboardingTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "onboarding-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return suite
    }

    // MARK: - Acceptance: skipping still lands in the setup sheet

    func testSkippingTheExplanationStillReachesSetup() {
        // From any page, not just the first — someone can skip halfway through.
        XCTAssertEqual(Onboarding.skip(from: .pages(index: 0)), .setup)
        XCTAssertEqual(Onboarding.skip(from: .pages(index: 2)), .setup)
    }

    func testSetupIsNotItselfSkippable() {
        // Skip is a statement about the explanation, not about wanting an empty
        // app; from setup it can only finish.
        XCTAssertEqual(Onboarding.skip(from: .setup), .finished)
    }

    func testThePagesRunThroughToSetupAndThenFinish() {
        var step = Onboarding.Step.pages(index: 0)
        step = Onboarding.next(after: step)
        XCTAssertEqual(step, .pages(index: 1))
        step = Onboarding.next(after: step)
        XCTAssertEqual(step, .pages(index: 2))
        step = Onboarding.next(after: step)
        XCTAssertEqual(step, .setup, "the last page leads to setup, not out")
        step = Onboarding.next(after: step)
        XCTAssertEqual(step, .finished)
    }

    // MARK: - Presenting exactly once

    func testOnboardingIsShownOnceAndThenNotAgain() {
        let store = defaults()
        XCTAssertTrue(Onboarding.shouldPresent(defaults: store))

        Onboarding.markCompleted(defaults: store)
        XCTAssertFalse(Onboarding.shouldPresent(defaults: store))
    }

    /// Someone who ran the flow and declined to connect a spreadsheet is not
    /// asked again on every launch: Home's "Потребує уваги" section already says
    /// the connection is missing, and a modal that cannot be escaped permanently
    /// is worse than a row that can be ignored.
    func testCompletingWithoutASpreadsheetDoesNotReopenTheFlow() {
        let store = defaults()
        Onboarding.markCompleted(defaults: store)
        XCTAssertFalse(Onboarding.shouldPresent(defaults: store))
        XCTAssertNotNil(NeedsAttention.authProblem(status: .notConfigured),
                        "the missing connection has to be surfaced somewhere")
    }

    func testReplayFromSettingsBringsTheFlowBack() {
        let store = defaults()
        Onboarding.markCompleted(defaults: store)
        Onboarding.replay(defaults: store)
        XCTAssertTrue(Onboarding.shouldPresent(defaults: store))
    }

    // MARK: - The second screen shows the app's real numbers

    /// §6.1 asks for "the four buttons with the interval preview under each". The
    /// screen renders the scheduler's own answer for a brand-new card, so it
    /// cannot drift away from what the study screen will actually do.
    func testTheIntervalPreviewsAreTheSchedulersOwn() throws {
        let previews = try Scheduler().preview(for: CardSchedulingSnapshot())
        XCTAssertEqual(Set(previews.keys), Set(Grade.allCases))
        // Ordered: a harder answer must never come back later than an easier one.
        let byGrade = Grade.allCases.compactMap { previews[$0]?.interval }
        XCTAssertEqual(byGrade, byGrade.sorted(),
                       "Again ≤ Hard ≤ Good ≤ Easy for a new card")
    }
}
