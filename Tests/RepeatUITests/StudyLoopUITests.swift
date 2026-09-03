import XCTest

/// #39 — the study loop and the add-card flow, driven through the real UI.
///
/// Every other test in this repo calls `StudySession` directly. None of them can
/// tell you whether the button that starts a session is wired to it, whether the
/// card can be turned over by touch, or whether rating advances the screen —
/// which is exactly the seam this app's bugs have lived in. #37 found a card that
/// VoiceOver could read but never reveal; a unit test could not have.
///
/// Determinism comes from the DEBUG launch arguments rather than from tapping
/// through setup, so a run does not depend on what the simulator happened to
/// contain. Elements are addressed by `accessibilityIdentifier`, never by copy:
/// #38 rewrote every user-facing string in the app.
final class StudyLoopUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Ukrainian is the app's primary language; pinning it keeps a run on an
        // English Mac identical to a run on a Ukrainian one.
        app.launchArguments = ["-AppleLanguages", "(uk)", "-AppleLocale", "uk_UA"] + arguments
        app.launch()
        return app
    }

    private static let timeout: TimeInterval = 20

    // MARK: - The study loop

    /// The card's first line: launch → start review → reveal → rate → finish →
    /// Done screen.
    func testAWholeSessionCanBeCompleted() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let start = app.buttons["home.startSession"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertTrue(start.isEnabled, "nothing was due — the seed did not produce a queue")
        start.tap()

        let card = app.buttons["study.card"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "the study screen never appeared")

        // Easy, not Good. The sample deck is all new cards, and §5.1 puts a new
        // card rated Good onto a 1-minute learning step — it returns to the queue
        // and the session never ends inside a test's lifetime. Easy graduates it.
        // That is the app behaving correctly; the first version of this test sat
        // there tapping Good until it timed out.
        let easy = app.buttons["study.rate.easy"]
        let done = app.staticTexts["done.title"]

        // Bounded, so a queue that never drains fails here rather than hanging
        // the run. The sample deck is ten cards; 60 taps is ample slack.
        for _ in 0..<60 {
            if done.exists { break }
            guard card.exists else { break }
            card.tap()                                  // reveal
            guard easy.waitForExistence(timeout: 5) else { break }
            easy.tap()                                  // rate
        }

        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout),
                      "the session never reached the Done screen")
    }

    /// Revealing is the interaction the whole screen exists for, and it is a bare
    /// tap gesture rather than a button's action — the thing #37 found VoiceOver
    /// could not activate. Worth its own assertion rather than only being implied
    /// by the full run.
    ///
    /// The rating buttons are on screen before the reveal too (showing "—"), so
    /// their presence proves nothing. What changes is the card's own accessibility
    /// label: the question alone before, the question *and the answer* after.
    func testTappingTheCardRevealsTheAnswer() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch",
                          "-startSessionOnLaunch"])

        let card = app.buttons["study.card"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "the study screen never appeared")

        let question = card.label
        XCTAssertFalse(question.isEmpty, "the card had no spoken label")
        XCTAssertFalse(question.contains("Відповідь:"),
                       "the answer was already showing before the card was tapped")

        card.tap()

        let revealed = NSPredicate(format: "label CONTAINS %@", "Відповідь:")
        expectation(for: revealed, evaluatedWith: card)
        waitForExpectations(timeout: Self.timeout)

        for grade in ["again", "hard", "good", "easy"] {
            XCTAssertTrue(app.buttons["study.rate.\(grade)"].exists, "no \(grade) button")
        }
    }

    // MARK: - Offline

    /// §8: "every screen works with no network". The sync layer's offline path is
    /// covered by unit tests, but nothing had ever driven the *app* with a dead
    /// network — which is how #86 found Home telling the owner to go and look at
    /// Settings when the only thing wrong was the signal.
    func testAWholeSessionCanBeCompletedWithNoNetwork() {
        let app = launch(["-offlineOnLaunch", "-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let start = app.buttons["home.startSession"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertTrue(start.isEnabled, "the queue did not build without a network")
        start.tap()

        let card = app.buttons["study.card"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "the study screen never appeared")

        let easy = app.buttons["study.rate.easy"]
        let done = app.staticTexts["done.title"]
        for _ in 0..<60 {
            if done.exists { break }
            guard card.exists else { break }
            card.tap()
            guard easy.waitForExistence(timeout: 5) else { break }
            easy.tap()
        }

        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout),
                      "the session could not be finished offline")
    }

    // MARK: - Adding a card

    /// The card's second line: add a card and see it in the deck.
    ///
    /// Asserts the deck's own count rather than "did we navigate back". The first
    /// version waited for Home's start button and was flaky when run after
    /// another test — and it was checking the wrong thing anyway: returning to
    /// Home says nothing about whether the card was saved.
    /// #98 — the bug that was actually there.
    ///
    /// A learning card's timer expiring while the app sits in the background is the
    /// every-day version of "the store changed and Home did not notice": you put
    /// the phone down, a card falls due, you pick it up, and the screen still shows
    /// the count from before. `.task` re-fires when a tab switch brings Home back
    /// but **not** on foreground, and `RepeatApp` runs §4.2's sync on exactly that
    /// event — so the same gap also swallowed every card a sync pulled.
    ///
    /// Reproducible without a spreadsheet, a network or a stub, which is why this
    /// is the case the test pins.
    func testACardThatFallsDueWhileBackgroundedIsCountedOnReturn() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch",
                          "-seedSoonDueOnLaunch"])

        let count = app.staticTexts["home.dueCount"]
        XCTAssertTrue(count.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertEqual(count.label, "10", "the soon-due card is not due yet")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 9)
        app.activate()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertEqual(count.label, "11",
                       "a card fell due while the app was away and Home never noticed")
    }

    /// #98 — Home's own number, not the deck's.
    ///
    /// `testAddingACardPutsItInTheDeck` below walks the same path and passes,
    /// because it reads the deck row's subtitle: that is a `@Query` and refreshes
    /// itself. The hero count is `@State`, rebuilt only at a handful of remembered
    /// moments, and a card added on the Add tab is not one of them — so the two
    /// numbers on one screen disagree.
    func testACardAddedOnTheAddTabRaisesHomesOwnCount() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let count = app.staticTexts["home.dueCount"]
        XCTAssertTrue(count.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertEqual(count.label, "10", "the sample deck seeds ten cards")

        app.buttons["Додати"].tap()

        let front = app.textViews["add.front"].exists
            ? app.textViews["add.front"]
            : app.textFields["add.front"]
        XCTAssertTrue(front.waitForExistence(timeout: Self.timeout), "the Add tab never appeared")
        front.tap()
        front.typeText("ubiquitous")

        let back = app.textViews["add.back"].exists
            ? app.textViews["add.back"]
            : app.textFields["add.back"]
        back.tap()
        back.typeText("повсюдний")

        let save = app.buttons["add.saveAndContinue"]
        XCTAssertTrue(save.waitForExistence(timeout: Self.timeout), "no save button")
        save.tap()
        app.buttons["Готово"].tap()

        app.buttons["Колоди"].tap()

        // The card is in the deck — the existing test proves that much. The claim
        // here is that Home *says so*.
        XCTAssertTrue(count.waitForExistence(timeout: Self.timeout), "Home never came back")
        XCTAssertEqual(count.label, "11",
                       "Home still shows \(count.label) after a card was added — "
                       + "the hero is stale while the deck row below it is not")
    }

    func testAddingACardPutsItInTheDeck() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-openAddTabOnLaunch"])

        let front = app.textViews["add.front"].exists
            ? app.textViews["add.front"]
            : app.textFields["add.front"]
        XCTAssertTrue(front.waitForExistence(timeout: Self.timeout), "the Add tab never appeared")

        front.tap()
        front.typeText("reluctant")

        let back = app.textViews["add.back"].exists
            ? app.textViews["add.back"]
            : app.textFields["add.back"]
        XCTAssertTrue(back.waitForExistence(timeout: Self.timeout), "no answer field")
        back.tap()
        back.typeText("неохочий")

        // The keyboard accessory's button, not the one in the form. The form's
        // "Зберегти й закрити" sits *under* the keyboard by design — the screen
        // exists to make adding a card take seconds, so the reachable action
        // while typing is "save and add another". Two earlier versions of this
        // test tapped the covered one: `waitForExistence` is true for an element
        // behind the keyboard, and the tap then does nothing, silently.
        let save = app.buttons["add.saveAndContinue"]
        XCTAssertTrue(save.waitForExistence(timeout: Self.timeout), "no save button")
        XCTAssertTrue(save.isHittable, "the save button the keyboard leaves reachable is covered")
        save.tap()

        // Leave the Add tab so Home can be read.
        app.buttons["Готово"].tap()

        // The sample deck seeds ten cards; the new one makes eleven. That is the
        // claim — the note reached the deck — and it holds wherever the app
        // happens to navigate afterwards.
        // The deck's own subtitle. Ukrainian puts 11 in the `many` category, so
        // eleven cards read "11 карток" — the plural #38 fixed.
        let count = app.staticTexts["11 карток"]
        XCTAssertTrue(count.waitForExistence(timeout: Self.timeout),
                      "the deck still does not show the added card")
    }
}
