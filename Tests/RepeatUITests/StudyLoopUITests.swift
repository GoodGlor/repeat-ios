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
    // MARK: - The number that decides the day

    /// The per-deck allowance is what `QueueBuilder` reads; the app-wide setting
    /// is only a ceiling over it. It lived behind a swipe on a Home row, where
    /// someone raising the ceiling to 30 and still getting 15 a day had no reason
    /// to look for it, so Settings now lists the decks — and this drives that list
    /// the way they would: change it, close the screen, come back.
    func testADecksDailyAllowanceCanBeSetFromSettingsAndSticks() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-openConnectionOnLaunch"])

        func revealNewCards() {
            let header = app.staticTexts["Нові картки на день"]
            XCTAssertTrue(header.waitForExistence(timeout: Self.timeout))
            var tries = 0
            while !header.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(header.isHittable, "could not scroll the section into view")
        }
        // The value rides on the stepper rather than on a text of its own: SwiftUI
        // folds the `LabeledContent` into the control's own accessibility element,
        // which is also what VoiceOver reads ("Англійська — дієслова, 15").
        func allowance() -> String { "\(app.steppers.element(boundBy: 0).value ?? "")" }

        revealNewCards()
        XCTAssertEqual(allowance(), "15", "the seeded deck starts at Deck's default")

        let stepper = app.steppers.element(boundBy: 0)
        stepper.buttons.element(boundBy: 1).tap()
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(allowance(), "17")

        app.buttons["Готово"].tap()
        app.buttons["Налаштування"].firstMatch.tap()
        revealNewCards()
        XCTAssertEqual(allowance(), "17", "a value that only lived in the view would be back at 15")
    }

    /// #110: the streak reminder's time picker sits under the daily-reminder
    /// toggle and exists only while that toggle is on — one switch governs both
    /// evening notifications. The toggle is set by launch argument rather than
    /// tapped, because turning it on asks for notification permission and a
    /// system alert would stand between the test and the screen.
    func testTheStreakReminderTimeShowsOnlyWhileRemindersAreOn() {
        func openReminders(enabled: Bool) -> XCUIApplication {
            let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-openConnectionOnLaunch",
                              // A plist literal: `YES` would arrive as a String,
                              // and `AppSettings` reads the key `as? Bool`.
                              "-settings.reminderEnabled", enabled ? "<true/>" : "<false/>"])
            XCTAssertTrue(app.buttons["Готово"].waitForExistence(timeout: Self.timeout))
            // The section is far down a lazy list: its rows do not exist until
            // scrolled near, so wait for the sheet and then scroll for the toggle.
            // A full swipe can carry it up under the navigation bar, where it
            // exists but is not hittable, so ease back down if that happens.
            let toggle = app.switches["Щоденне нагадування"]
            var tries = 0
            while !toggle.exists && tries < 12 { app.swipeUp(); tries += 1 }
            tries = 0
            while !toggle.isHittable && tries < 3 { app.swipeDown(velocity: .slow); tries += 1 }
            XCTAssertTrue(toggle.isHittable, "could not scroll the reminder section into view")
            XCTAssertEqual("\(toggle.value ?? "")", enabled ? "1" : "0", "the launch argument did not reach the toggle")
            return app
        }

        // A compact `DatePicker` is not reliably a `datePickers` element across
        // iOS versions, so match the label on any element type.
        func streakTime(_ app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)["Час нагадування про серію"].firstMatch
        }

        let off = openReminders(enabled: false)
        attach(off, "settings-reminders-off")
        XCTAssertFalse(streakTime(off).exists, "the streak time is shown with reminders off")
        off.terminate()

        let on = openReminders(enabled: true)
        attach(on, "settings-reminders-on")
        XCTAssertTrue(streakTime(on).exists, "the streak time is missing with reminders on")
    }

    /// Reported from the phone: change the allowance, close the app, and it is
    /// back at 15. The existing test only reopened the *sheet*, which never
    /// leaves the one `ModelContext` — so it proved the model was mutated and
    /// nothing about the store.
    func testTheAllowanceSurvivesRelaunch() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-openConnectionOnLaunch"])

        func revealNewCards() {
            let header = app.staticTexts["Нові картки на день"]
            XCTAssertTrue(header.waitForExistence(timeout: Self.timeout))
            var tries = 0
            while !header.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(header.isHittable, "could not scroll the section into view")
        }
        func allowance() -> String { "\(app.steppers.element(boundBy: 0).value ?? "")" }

        revealNewCards()
        XCTAssertEqual(allowance(), "15")
        app.steppers.element(boundBy: 0).buttons.element(boundBy: 1).tap()
        app.steppers.element(boundBy: 0).buttons.element(boundBy: 1).tap()
        XCTAssertEqual(allowance(), "17")

        // Kill it. No reset this time: the store on disk is the whole point.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(uk)", "-AppleLocale", "uk_UA", "-openConnectionOnLaunch"]
        app.launch()

        revealNewCards()
        XCTAssertEqual(allowance(), "17", "the allowance did not survive a relaunch")
    }

    /// The same field, reached the way it was reachable before Settings listed the
    /// decks. This path had the defect first — the Settings list only made it easy
    /// enough to find that someone hit it.
    func testTheAllowanceSurvivesRelaunchFromTheDeckScreenToo() {
        let app = launch(["-resetStoreOnLaunch", "-openDeckSettingsOnLaunch"])
        let stepper = app.steppers.element(boundBy: 0)
        XCTAssertTrue(stepper.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual("\(stepper.value ?? "")", "15")
        stepper.buttons.element(boundBy: 1).tap()
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual("\(app.steppers.element(boundBy: 0).value ?? "")", "17")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(uk)", "-AppleLocale", "uk_UA", "-openDeckSettingsOnLaunch"]
        app.launch()

        let again = app.steppers.element(boundBy: 0)
        XCTAssertTrue(again.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual("\(again.value ?? "")", "17", "the swipe-in deck screen must persist it too")
    }

    // MARK: - #121: browsing a deck and fixing a card

    /// The card's whole point: change a card's wording without opening the
    /// spreadsheet. Before this the only editor was §5.4's **Rewrite**, which is
    /// reserved for leeches, so an ordinary typo had no way out.
    ///
    /// Entered through the swipe rather than a launch argument, because the entry
    /// point is the part of this feature most likely to be quietly broken by a
    /// later change to the deck row.
    func testADecksCardsCanBeBrowsedSearchedAndEdited() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let deckRow = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(deckRow.waitForExistence(timeout: Self.timeout))
        deckRow.swipeLeft()

        let browse = app.buttons["home.deck.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: Self.timeout),
                      "the deck row has no way through to its cards")
        browse.tap()

        XCTAssertTrue(app.descendants(matching: .any)["deck.cards"].waitForExistence(timeout: Self.timeout))
        let thorough = app.descendants(matching: .any)["deck.card.thorough"]
        XCTAssertTrue(thorough.waitForExistence(timeout: Self.timeout),
                      "the deck's own cards are not listed")

        // #121: VoiceOver reads the row's accessibility label, and this is that
        // label — front, back, then the state hint, in that order. A fresh sample
        // deck is all new cards. (Not asserted: that the texts inside are not
        // separate elements. XCUITest lists a SwiftUI button's texts as children
        // even when VoiceOver reads the button as one, so that check cannot fail
        // for the right reason.)
        XCTAssertEqual(thorough.label, "thorough, ретельний, нова")
        XCTAssertEqual(thorough.elementType, .button, "VoiceOver would not announce the row as tappable")

        // The bar has to be there at all: Home hides its own, and that hiding
        // reaches this screen unless it says otherwise. No bar means no way back.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: Self.timeout),
                      "the pushed screen has no navigation bar, so no way back either")

        // Which element type a search field reports as has moved between iOS
        // releases, so this asks for the one and falls back to the other rather
        // than pinning a version's answer.
        var search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 5) { search = app.textFields.firstMatch }
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout), "no search field")
        search.tap()
        search.typeText("brittle")

        let brittle = app.descendants(matching: .any)["deck.card.brittle"]
        XCTAssertTrue(brittle.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(thorough.exists, "search did not narrow the list")

        brittle.tap()
        let front = app.descendants(matching: .any)["edit.front"]
        XCTAssertTrue(front.waitForExistence(timeout: Self.timeout), "the editor did not open")
        front.tap()
        // Cleared by deleting rather than by selecting: "Select All" is a menu
        // item addressed by copy, and this file addresses nothing by copy.
        front.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        front.typeText("brittleness")
        app.buttons["edit.save"].tap()

        // Still matches the search term, so it should be here under its new name.
        XCTAssertTrue(app.descendants(matching: .any)["deck.card.brittleness"]
                        .waitForExistence(timeout: Self.timeout),
                      "the edit did not reach the list")
    }

    /// #121: Apple's accessibility audit over a deck's card list — the checks
    /// VoiceOver and Dynamic Type users would otherwise find by hand: missing
    /// labels, contrast, hit regions, clipped text.
    func testADecksCardListPassesTheAccessibilityAudit() throws {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])
        let deckRow = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(deckRow.waitForExistence(timeout: Self.timeout))
        deckRow.swipeLeft()
        app.buttons["home.deck.browse"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["deck.card.thorough"].waitForExistence(timeout: Self.timeout))
        attach(app, "deck-cards")
        try app.performAccessibilityAudit()
    }

    // MARK: - Pull to refresh

    /// The owner's crash of 2026-09-04: pull down on Home and the app died, three
    /// times out of three, each with a different signal. A sync that **lands** is
    /// what made it reliable there — `lastSyncedAt` changes, Home rebuilds its plan
    /// while the previous rebuild is still reading the same models off the main
    /// actor — so this test needs one. `-cannedSheetOnLaunch` answers the Sheets
    /// API from memory: the sample deck's tab, plus one row that appears only
    /// after the launch sync has been and gone, the way the owner's edits do.
    func testPullToRefreshLandsASyncAndTheAppSurvivesIt() {
        let app = launch(["-cannedSheetOnLaunch", "-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let count = app.staticTexts["home.dueCount"]
        XCTAssertTrue(count.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertEqual(count.label, "10", "the sample deck seeds ten cards")

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: Self.timeout), "Home's list never appeared")
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let bottom = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        top.press(forDuration: 0.2, thenDragTo: bottom)

        let landed = expectation(for: NSPredicate(format: "label == '11'"), evaluatedWith: count)
        wait(for: [landed], timeout: Self.timeout)
        XCTAssertEqual(app.state, .runningForeground, "the app is gone — this is the crash")
    }

    // MARK: - The daily goal (M9)

    /// Complete the day, then add a card. #89's ring would drop to 10/11; the
    /// goal stays closed and the button offers the extra card instead.
    ///
    /// Screenshots are attached at each state — no ring, 100 %, and 100 % with a
    /// card waiting — for the card's screenshot acceptance.
    func testTheGoalStaysClosedWhenACardArrivesAfterTheDayIsDone() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch"])

        let start = app.buttons["home.startSession"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.timeout), "Home never appeared")
        XCTAssertFalse(app.otherElements["home.goal"].exists, "no ring before the first grade")
        attach(app, "goal-0-fresh")
        start.tap()

        let card = app.buttons["study.card"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "the study screen never appeared")
        let easy = app.buttons["study.rate.easy"]
        let done = app.staticTexts["done.title"]
        for _ in 0..<60 {
            if done.exists { break }
            guard card.exists else { break }
            card.tap()
            if easy.waitForExistence(timeout: 5) { easy.tap() }
        }
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout), "the session never finished")
        app.buttons["До колод"].tap()

        var ring = app.otherElements["home.goal"]
        if !ring.waitForExistence(timeout: 3) {
            ring = app.descendants(matching: .any)["home.goal"]
        }
        XCTAssertTrue(ring.waitForExistence(timeout: Self.timeout), "the ring never appeared")
        XCTAssertEqual(ring.value as? String, "100")
        attach(app, "goal-100-done")

        // A card arrives — the Add tab, the path testAddingACardPutsItInTheDeck walks.
        app.buttons["Додати"].tap()
        let front = app.textViews["add.front"].exists
            ? app.textViews["add.front"]
            : app.textFields["add.front"]
        XCTAssertTrue(front.waitForExistence(timeout: Self.timeout), "the Add tab never appeared")
        front.tap()
        front.typeText("arrive")

        let back = app.textViews["add.back"].exists
            ? app.textViews["add.back"]
            : app.textFields["add.back"]
        back.tap()
        back.typeText("прибувати")

        let save = app.buttons["add.saveAndContinue"]
        XCTAssertTrue(save.waitForExistence(timeout: Self.timeout), "no save button")
        XCTAssertTrue(save.isHittable, "the save button the keyboard leaves reachable is covered")
        save.tap()
        app.buttons["Готово"].tap()
        app.buttons["Колоди"].tap()

        XCTAssertTrue(start.waitForExistence(timeout: Self.timeout), "Home never came back")
        XCTAssertEqual(app.staticTexts["home.dueCount"].label, "1", "the new card is due")
        XCTAssertEqual(ring.value as? String, "100", "the goal reopened when a card arrived")
        XCTAssertTrue(start.isEnabled, "a closed goal with a card waiting is still startable")
        attach(app, "goal-100-more-cards")
    }

    /// A session finished between 23:00 and 03:59 also earns the owl, and one
    /// finished between 04:00 and 07:59 the early bird (`Achievements.nightOwlFrom`,
    /// `nightOwlUntil`, `earlyBirdHours`). The fixtures run on the wall clock,
    /// so any assertion that counts fresh badges allows for that one extra. It
    /// reads the clock at assertion time, so a run that crosses 23:00, 04:00 or
    /// 08:00 mid-session can still mismatch — accepted: the alternative is a
    /// launch argument that fixes the fixtures' hour, which is a bigger change
    /// than the risk.
    private var nightOrMorningBonus: Int {
        let hour = Calendar.current.component(.hour, from: Date())
        return (hour >= 23 || hour < 8) ? 1 : 0
    }

    /// Which hour badge the window earns — the early bird between 04:00 and
    /// 07:59, the owl otherwise — or `nil` outside it. Catalogue order puts the
    /// hour badge ahead of `all-decks-green`, so inside the window it is the one
    /// that takes a tile.
    private var hourBadgeIdentifier: String? {
        guard nightOrMorningBonus == 1 else { return nil }
        let hour = Calendar.current.component(.hour, from: Date())
        return (4..<8).contains(hour) ? "done.badge.early-bird" : "done.badge.night-owl"
    }

    // MARK: - #153: the deck's tag, chosen in its settings, scopes every session

    /// `-seedTagsOnLaunch` gives the sample deck two verbs (linger, with a
    /// reverse card, and dwindle), five adjectives and one untagged note: ten
    /// new cards, three of them verbs.
    private static let verbs = ["linger", "dwindle", "затримуватися", "меншати"]

    /// Swipe the deck, open its settings, choose a tag, close them.
    private func chooseTag(_ tag: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "the sample deck's row never appeared")
        row.swipeLeft()
        let settings = app.buttons["home.deck.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: Self.timeout))
        settings.tap()
        let filter = app.buttons["deckSettings.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: Self.timeout), "Deck settings has no tag menu")
        filter.tap()
        for choice in ["Усі картки", "adjectives", "verbs", "Без тегу"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5), "\(choice) is not offered")
        }
        app.buttons[tag].tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", tag).wait(for: filter))
        app.buttons["Готово"].tap()
    }

    /// Rates Easy until the Done screen, returning the question of every card.
    private func studyToTheEnd(_ app: XCUIApplication) -> [String] {
        let card = app.buttons["study.card"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "the study screen never appeared")
        let easy = app.buttons["study.rate.easy"]
        let done = app.staticTexts["done.title"]
        var shown: [String] = []
        for _ in 0..<30 {
            if done.exists { break }
            guard card.exists else { break }
            shown.append(card.label)
            card.tap()
            guard easy.waitForExistence(timeout: 5) else { break }
            easy.tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout), "the session never reached the Done screen")
        return shown
    }

    /// The owner's case: a tag chosen in the deck's settings changes Home's
    /// number and what "Почати повторення" studies, and the deck row says so.
    func testATagChosenInDeckSettingsScopesHomeAndItsSession() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-seedTagsOnLaunch"])
        let due = app.descendants(matching: .any)["home.dueCount"]
        XCTAssertTrue(due.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(due.label, "10", "the whole sample deck first")

        chooseTag("verbs", in: app)
        XCTAssertTrue(NSPredicate(format: "label == %@", "3").wait(for: due), "Home's number did not follow the tag: \(due.label)")
        let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(row.label.contains("verbs"), "the deck row does not name its tag: \(row.label)")
        attach(app, "home-tagged")

        app.buttons["home.startSession"].tap()
        let shown = studyToTheEnd(app)
        XCTAssertEqual(shown.count, 3, "\(shown)")
        for label in shown { XCTAssertTrue(Self.verbs.contains { label.contains($0) }, "\(label) is not a verb") }

        // The choice outlives a relaunch. `-seedSampleDataOnLaunch` is only the
        // onboarding suppressor here: the store is not empty, so it seeds nothing.
        app.terminate()
        let again = launch(["-seedSampleDataOnLaunch"])
        let againRow = again.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(againRow.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(againRow.label.contains("verbs"), "the tag did not survive a relaunch: \(againRow.label)")
    }

    /// A tap on the deck row studies that deck under its tag, with nothing in
    /// between.
    func testTappingATaggedDeckStudiesOnlyItsTag() {
        let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-seedTagsOnLaunch"])
        chooseTag("verbs", in: app)
        let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "verbs").wait(for: row))
        row.tap()
        let shown = studyToTheEnd(app)
        XCTAssertEqual(shown.count, 3, "\(shown)")
        for label in shown { XCTAssertTrue(Self.verbs.contains { label.contains($0) }, "\(label) is not a verb") }
    }

    /// Deck settings with the menu, in light, dark and at AX5.
    func testDeckSettingsWithTheTagMenuInDarkAndAtTheLargestSize() {
        let variants: [(String, [String])] = [
            ("deck-settings-light", []),
            ("deck-settings-dark", ["-settings.appearance", "dark"]),
            ("deck-settings-ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        for (name, extra) in variants {
            let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-seedTagsOnLaunch",
                              "-openDeckSettingsOnLaunch"] + extra)
            let filter = app.buttons["deckSettings.filter"]
            XCTAssertTrue(filter.waitForExistence(timeout: Self.timeout), "\(name): no tag menu")
            XCTAssertTrue(filter.label.hasPrefix("Картки"), "\(name): VoiceOver reads \(filter.label)")
            attach(app, name)
            app.terminate()
        }
    }

    // MARK: - #149: a picture on a card

    /// The first sample card has a picture (as a sync would leave it); the
    /// second has none. VoiceOver says which: "з картинкою" on the card.
    /// Screenshots in light, dark and at AX5, before and after the reveal.
    func testACardShowsItsPictureOnTheQuestionSide() {
        let variants: [(String, [String])] = [
            ("picture-light", []),
            ("picture-dark", ["-settings.appearance", "dark"]),
            ("picture-ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        for (name, extra) in variants {
            let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-seedPicturesOnLaunch",
                              "-startSessionOnLaunch"] + extra)
            let card = app.buttons["study.card"]
            XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "\(name): the study screen never appeared")
            XCTAssertTrue(card.label.hasPrefix("reluctant"), "\(name): the first card is not the pictured one: \(card.label)")
            XCTAssertEqual("\(card.value ?? "")", "з картинкою", "\(name): the card does not say it has a picture")
            attach(app, name)

            card.tap()
            let easy = app.buttons["study.rate.easy"]
            XCTAssertTrue(easy.waitForExistence(timeout: 5))
            if !easy.isHittable { app.swipeUp() }
            XCTAssertTrue(easy.isHittable, "\(name): the picture pushed the rating buttons out of reach")
            attach(app, name + "-revealed")

            if name == "picture-light" {
                // "reluctant" has a reverse card: the same note, so the same
                // picture. Past both, the next note has none.
                easy.tap()
                for _ in 0..<2 where card.label.hasPrefix("reluctant") {
                    XCTAssertEqual("\(card.value ?? "")", "з картинкою", "both directions of the note show it")
                    card.tap()
                    XCTAssertTrue(easy.waitForExistence(timeout: 5))
                    easy.tap()
                }
                XCTAssertTrue(NSPredicate(format: "NOT (label BEGINSWITH %@)", "reluctant").wait(for: card))
                XCTAssertEqual("\(card.value ?? "")", "", "the next card has no picture, and says nothing")
            }
            app.terminate()
        }
    }

    // MARK: - #155: pictures in the card list and on the opened card

    /// "reluctant" has a picture (`-seedPicturesOnLaunch`), "thorough" none.
    /// Swipe → Картки: the row says it has one; tap it: the picture is on top.
    func testTheCardListShowsPicturesAndTheOpenedCardShowsItWhole() {
        let variants: [(String, [String])] = [
            ("list-picture-light", []),
            ("list-picture-dark", ["-settings.appearance", "dark"]),
            ("list-picture-ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        for (name, extra) in variants {
            let app = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch", "-seedPicturesOnLaunch"] + extra)
            let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
            XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout), name)
            // At AX5 the row is below the hero, and a lazy list has not made it yet.
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
            XCTAssertTrue(row.isHittable, "\(name): the deck row never scrolled into reach")
            row.swipeLeft()
            let browse = app.buttons["home.deck.browse"]
            XCTAssertTrue(browse.waitForExistence(timeout: Self.timeout), name)
            browse.tap()

            let pictured = app.descendants(matching: .any)["deck.card.reluctant"]
            XCTAssertTrue(app.descendants(matching: .any)["deck.cards"].waitForExistence(timeout: Self.timeout), name)
            // Fifth by name; at AX5 the rows are tall and it is below the fold.
            for _ in 0..<8 where !(pictured.exists && pictured.isHittable) { app.swipeUp() }
            XCTAssertTrue(pictured.waitForExistence(timeout: Self.timeout), name)
            XCTAssertTrue(NSPredicate(format: "label ENDSWITH %@", "з картинкою").wait(for: pictured),
                          "\(name): the row does not say it has a picture: \(pictured.label)")
            let plain = app.descendants(matching: .any)["deck.card.thorough"]
            if plain.exists {
                XCTAssertFalse(plain.label.contains("з картинкою"), "\(name): a card without a picture claims one")
            }
            attach(app, name)

            pictured.tap()
            XCTAssertTrue(app.descendants(matching: .any)["edit.picture"].waitForExistence(timeout: Self.timeout),
                          "\(name): the opened card does not show its picture")
            attach(app, name + "-opened")
            app.terminate()
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// §5.2: the year and the records, read off the screen with the history the
    /// backlog seed earns — ten reviews a day for fourteen days, none today. That
    /// is a 14-day longest streak, a best day of 10 and, because any fourteen
    /// consecutive days hold exactly one full Monday-to-Sunday week, a best week
    /// of 70 whatever weekday the test runs on.
    func testStatsShowsTheRecordsTheHistoryEarned() {
        let app = launch(["-resetStoreOnLaunch", "-seedBacklogOnLaunch"])
        XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout), "Home never appeared")
        app.buttons["Статистика"].tap()

        let heatmap = app.descendants(matching: .any)["stats.heatmap"]
        XCTAssertTrue(heatmap.waitForExistence(timeout: Self.timeout), "the year never drew")

        XCTAssertEqual(app.descendants(matching: .any)["stats.record.streak"].value as? String, "14 днів")
        let day = app.descendants(matching: .any)["stats.record.day"].value as? String ?? ""
        XCTAssertTrue(day.hasPrefix("10 карток"), day)
        let week = app.descendants(matching: .any)["stats.record.week"].value as? String ?? ""
        XCTAssertTrue(week.hasPrefix("70 карток"), week)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "stats-records"
        shot.lifetime = .keepAlways
        add(shot)

        // No history, no year. An empty grid under "Ще немає даних" would be a
        // scoreboard for someone who has not started — the empty-ring lesson.
        app.terminate()
        let fresh = launch(["-resetStoreOnLaunch"])
        XCTAssertTrue(fresh.buttons["Статистика"].waitForExistence(timeout: Self.timeout))
        fresh.buttons["Статистика"].tap()
        XCTAssertTrue(fresh.staticTexts["Ще немає даних"].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(fresh.descendants(matching: .any)["stats.heatmap"].exists)
        let empty = XCTAttachment(screenshot: fresh.screenshot())
        empty.name = "stats-empty"
        empty.lifetime = .keepAlways
        add(empty)
    }

    /// §5.2, three ways. A history whose record run is an older one: today's
    /// session overtakes it and the Done screen says so. The backlog seed's
    /// unbroken fortnight: today only *extends* the streak record, so the line
    /// names the best day instead — the first version said "new longest streak"
    /// every evening. No history at all: the first session sets every record
    /// and names none.
    func testTheDoneScreenNamesARecordOnlyWhenOneWasOvertaken() {
        let app = launch(["-resetStoreOnLaunch", "-seedRecordHistoryOnLaunch",
                          "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(app.staticTexts["done.title"].waitForExistence(timeout: Self.timeout),
                      "the session never reached the Done screen")
        let record = app.descendants(matching: .any)["done.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "a 4-day run overtook a 3-day one and nothing said so")
        XCTAssertTrue(record.label.contains("Нова найдовша серія"), record.label)
        XCTAssertTrue(record.label.contains("4 дні"), record.label)
        let named = XCTAttachment(screenshot: app.screenshot())
        named.name = "done-record"
        named.lifetime = .keepAlways
        add(named)

        app.terminate()
        let extended = launch(["-resetStoreOnLaunch", "-seedBacklogOnLaunch",
                               "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(extended.staticTexts["done.title"].waitForExistence(timeout: Self.timeout))
        // Day 15 of the same run is not a new streak record — but ~130 reviews
        // today do overtake a best day of 10, so the line falls through to the
        // day record. That pins the silence *and* the streak-first ordering.
        let extendedRecord = extended.descendants(matching: .any)["done.record"]
        XCTAssertTrue(extendedRecord.waitForExistence(timeout: 5), "today's session beat a best day of 10 and nothing said so")
        XCTAssertFalse(extendedRecord.label.contains("Нова найдовша серія"),
                       "day 15 of the same run is not a new record: \(extendedRecord.label)")
        XCTAssertTrue(extendedRecord.label.contains("Новий найкращий день"), extendedRecord.label)
        // #108: this is the branch's one screen with more than three fresh badges
        // (first session, streak 7, 100 reviews, plus three more), so the "+N"
        // pill is pinned here — "+4" between 23:00 and 08:00, when the session
        // also earns the owl or the early bird. Change the seed and this number
        // changes with it.
        XCTAssertEqual(extended.descendants(matching: .any)["done.badges.more"].label,
                       "+\(3 + nightOrMorningBonus)")
        let namedDay = XCTAttachment(screenshot: extended.screenshot())
        namedDay.name = "done-record-day"
        namedDay.lifetime = .keepAlways
        add(namedDay)

        extended.terminate()
        let first = launch(["-resetStoreOnLaunch", "-seedSampleDataOnLaunch",
                            "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(first.staticTexts["done.title"].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(first.descendants(matching: .any)["done.record"].exists,
                       "the first session ever has nothing to beat")
        let quiet = XCTAttachment(screenshot: first.screenshot())
        quiet.name = "done-no-record"
        quiet.lifetime = .keepAlways
        add(quiet)
    }

    /// §5.3: a fresh deck is all new; a mature one is mostly known. The bar
    /// itself is drawn, not read — the row's VoiceOver label carries the three
    /// numbers, and that is what this reads.
    func testDeckRowsSayHowMuchOfEachDeckIsKnown() {
        let app = launch(["-resetStoreOnLaunch", "-seedMasteryOnLaunch"])
        XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout), "Home never appeared")

        func row(_ title: String) -> XCUIElement {
            let button = app.buttons["home.deck.\(title)"]
            return button.exists ? button : app.descendants(matching: .any)["home.deck.\(title)"]
        }

        let fresh = row("Англійська — дієслова")
        XCTAssertTrue(fresh.waitForExistence(timeout: Self.timeout), "the sample deck's row never appeared")
        XCTAssertTrue(fresh.label.contains("відомо 0, вивчається 0, нових 10"), fresh.label)

        let mature = row("Англійська — прикметники")
        XCTAssertTrue(mature.waitForExistence(timeout: Self.timeout), "the mature deck's row never appeared")
        XCTAssertTrue(mature.label.contains("відомо 6, вивчається 3, нових 2"), mature.label)

        attach(app, "home-mastery")
    }

    /// §5.3: the four words that crossed this month are listed, the two that
    /// crossed forty days ago are not, and the header counts four. The section
    /// sits below the records, so the test scrolls until the last row is on
    /// screen before reading anything.
    func testStatsListsTheWordsLearnedThisMonth() {
        let app = launch(["-resetStoreOnLaunch", "-seedMasteryOnLaunch"])
        XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout), "Home never appeared")
        app.buttons["Статистика"].tap()

        let last = app.descendants(matching: .any)["stats.learned.gentle"]
        var swipes = 0
        while !last.exists && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(last.exists, "the learned-this-month section never scrolled into view")
        if !last.isHittable { app.swipeUp() }

        XCTAssertEqual(app.descendants(matching: .any)["stats.learned.count"].label, "4")
        for word in ["harbour", "meadow", "stubborn", "gentle"] {
            XCTAssertTrue(app.descendants(matching: .any)["stats.learned.\(word)"].exists, "\(word) crossed this month")
        }
        for word in ["candle", "river"] {
            XCTAssertFalse(app.descendants(matching: .any)["stats.learned.\(word)"].exists,
                           "\(word) became known forty days ago")
        }
        attach(app, "stats-learned")
    }

    /// §5.4's grid: three earned in colour with their day, nine locked in
    /// outline with the condition — read off the tiles' own sentences.
    func testStatsShowsTheBadgeGrid() {
        let app = launch(["-resetStoreOnLaunch", "-seedBacklogOnLaunch", "-seedBadgesOnLaunch"])
        XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout))
        app.buttons["Статистика"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stats.heatmap"].waitForExistence(timeout: Self.timeout))

        let first = app.descendants(matching: .any)["badge.first-session"]
        for _ in 0..<8 where !first.exists { app.swipeUp() }
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the grid never scrolled into view")
        if !first.isHittable { app.swipeUp() }
        XCTAssertTrue(first.label.hasPrefix("Перша сесія, здобуто"), first.label)
        let words = app.descendants(matching: .any)["badge.words-100"]
        for _ in 0..<4 where !words.exists { app.swipeUp() }
        XCTAssertEqual(words.label, "100 слів вивчено, 100 вивчених слів")
        XCTAssertEqual(app.descendants(matching: .any)["stats.badges.count"].label, "3 з 12")
        attach(app, "stats-badges")
    }

    /// #109: a notification's deep link lands on Stats, through the same routing
    /// a widget tap uses (`-openURLOnLaunch` feeds `open(_:)` directly — see
    /// `RootTabView` for why `simctl openurl` cannot).
    ///
    /// `-seedSampleDataOnLaunch` alone leaves `hasHistory` false — Stats shows
    /// its empty state, not the badge grid — so this needs the backlog seed
    /// `testStatsShowsTheBadgeGrid` uses instead. But that seed runs from
    /// `HomeView.task` (#98: tied to the Decks tab being on screen), and
    /// `-openURLOnLaunch` switches away from Decks in `RootTabView`'s own
    /// `.task` on the same launch — the two race, and the seed loses. So this
    /// seeds on an ordinary launch first, confirms the grid renders there
    /// (proof `context.save()` landed, not just that a static button exists),
    /// then relaunches with the link — the same store-survives-a-relaunch
    /// trick `testTheLedgerIsWrittenWhen…` uses. No suppressor argument is
    /// needed on the second launch: `-openURLOnLaunch` itself ends in
    /// `OnLaunch`, which is what `RootTabView.initialOnboarding` checks for.
    func testTheStatsLinkOpensTheStatsTab() {
        let seed = launch(["-resetStoreOnLaunch", "-seedBacklogOnLaunch"])
        XCTAssertTrue(seed.buttons["home.startSession"].waitForExistence(timeout: Self.timeout))
        seed.buttons["Статистика"].tap()
        let seededBadges = seed.descendants(matching: .any)["stats.badges"]
        for _ in 0..<8 where !seededBadges.exists { seed.swipeUp() }
        XCTAssertTrue(seededBadges.waitForExistence(timeout: Self.timeout))
        seed.terminate()

        let app = launch(["-openURLOnLaunch", "repeat://stats"])
        let badges = app.descendants(matching: .any)["stats.badges"]
        for _ in 0..<8 where !badges.exists { app.swipeUp() }
        XCTAssertTrue(badges.waitForExistence(timeout: Self.timeout),
                      "the link should select the Stats tab")
        XCTAssertTrue(app.tabBars.buttons["Статистика"].isSelected)
    }

    // MARK: - §5.6: the Done screen celebrates, three lines at most

    /// #112/#113 raised `Celebration.lineLimit` to five, and the Done screen's
    /// reason for a limit at all is that both buttons stay on it at the largest
    /// accessibility size. Nobody had looked at five. This fills every line —
    /// freeze, goal, level, record, badges — and checks it at the default size
    /// and at AX5.
    func testTheDoneScreenHoldsAllFiveLinesAtTheLargestSize() {
        for large in [false, true] {
            var arguments = ["-resetStoreOnLaunch", "-seedFullCelebrationOnLaunch",
                             "-startSessionOnLaunch", "-finishSessionOnLaunch"]
            if large {
                arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            let app = launch(arguments)
            XCTAssertTrue(app.staticTexts["done.title"].waitForExistence(timeout: Self.timeout))
            let lines = ["done.freeze", "done.goal", "done.level", "done.record", "done.badges"]
            XCTAssertTrue(app.descendants(matching: .any)["done.badges"].waitForExistence(timeout: 5))
            for line in lines {
                XCTAssertTrue(app.descendants(matching: .any)[line].exists, "\(line) is missing — the fixture no longer fills five lines")
            }
            attach(app, large ? "done-five-lines-ax5-top" : "done-five-lines")
            XCTAssertTrue(app.buttons["До колод"].isHittable, "the celebration pushed the button off the screen")
            XCTAssertTrue(app.buttons["Додати нові картки"].isHittable)

            if large {
                // Scroll to the last line: it must be reachable whole, with both
                // buttons still pinned on the screen beside it.
                // `isHittable` is true for an element *under* the pinned buttons,
                // so compare frames: scrolled to the end, the badges must clear them.
                let badges = app.descendants(matching: .any)["done.badges"]
                for _ in 0..<8 { app.swipeUp() }
                XCTAssertLessThanOrEqual(badges.frame.maxY, app.buttons["До колод"].frame.minY,
                                         "at AX5 the badges line stays under the buttons even scrolled to the end")
                XCTAssertTrue(app.buttons["До колод"].isHittable, "the button did not stay put while the lines scrolled")
                attach(app, "done-five-lines-ax5-bottom")
            }
            app.terminate()
        }
    }

    /// The record-history seed plus a finished session: the day's goal closes,
    /// the streak record is overtaken, and three badges are new — the first
    /// session ever recorded, a perfect ten, and nothing left in any deck. Then
    /// the same screen at the largest accessibility size, where tiles must not
    /// clip and both buttons must still be on it.
    func testTheDoneScreenCelebratesTheGoalTheRecordAndTheBadges() {
        let app = launch(["-resetStoreOnLaunch", "-seedRecordHistoryOnLaunch",
                          "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(app.staticTexts["done.title"].waitForExistence(timeout: Self.timeout))
        let goal = app.descendants(matching: .any)["done.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "the plan was finished and the goal did not close")
        XCTAssertTrue(app.descendants(matching: .any)["done.record"].label.contains("Нова найдовша серія"))
        let first = app.descendants(matching: .any)["done.badge.first-session"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the first session ever was not celebrated")
        XCTAssertTrue(app.descendants(matching: .any)["done.badge.perfect-session"].exists, "ten Easy ratings are a perfect session")
        // In the window the hour badge takes the third tile and green folds into
        // the pill; outside it, green is the third tile.
        let thirdTile = hourBadgeIdentifier ?? "done.badge.all-decks-green"
        XCTAssertTrue(app.descendants(matching: .any)[thirdTile].exists,
                      "\(thirdTile) is the third tile at this hour")
        XCTAssertTrue(app.descendants(matching: .any)["done.badges"].exists, "the badges line has no container")
        let more = app.descendants(matching: .any)["done.badges.more"]
        if nightOrMorningBonus == 0 {
            XCTAssertFalse(more.exists, "three badges fit; nothing to count")
        } else {
            XCTAssertEqual(more.label, "+1", "the owl or the early bird is the fourth badge at this hour")
        }
        XCTAssertTrue(first.label.hasPrefix("Перша сесія, здобуто"), first.label)
        attach(app, "done-celebration")

        // Shown once: the same session's Done screen does not celebrate twice.
        // (The ledger is written by this very tap — see
        // `testTheLedgerIsWrittenWhenTheDoneScreenIsLeftNotWhenItAppears`; a
        // relaunch that finishes another full session may still name a *new*
        // badge — that is Task 4's grid to prove — so only the quiet second
        // screen is asserted here.)
        app.buttons["До колод"].tap()
        XCTAssertTrue(app.buttons["home.startSession"].waitForExistence(timeout: Self.timeout))

        app.terminate()
        let large = XCUIApplication()
        large.launchArguments = ["-AppleLanguages", "(uk)", "-AppleLocale", "uk_UA",
                                 "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                 "-resetStoreOnLaunch", "-seedRecordHistoryOnLaunch",
                                 "-startSessionOnLaunch", "-finishSessionOnLaunch"]
        large.launch()
        XCTAssertTrue(large.staticTexts["done.title"].waitForExistence(timeout: Self.timeout))
        let largeFirst = large.descendants(matching: .any)["done.badge.first-session"]
        XCTAssertTrue(largeFirst.waitForExistence(timeout: 5))
        XCTAssertTrue(large.buttons["До колод"].isHittable, "at AX5 the celebration pushed the button off the screen")
        // At AX5 the screen is taller than the phone, so the summary scrolls and
        // the two buttons are pinned below it. Bring the tiles up: every one of
        // them must be whole and on the screen *together with* both buttons —
        // scrolling must never be the price of reaching them.
        var swipes = 0
        while !largeFirst.isHittable && swipes < 6 { large.swipeUp(); swipes += 1 }
        // The same three tiles the phone-sized screen showed, so the third one
        // follows the hour for the same reason.
        for badge in ["done.badge.first-session", "done.badge.perfect-session", thirdTile] {
            XCTAssertTrue(large.descendants(matching: .any)[badge].isHittable,
                          "\(badge) is not wholly on the screen at AX5")
        }
        XCTAssertTrue(large.buttons["До колод"].isHittable, "the button did not stay put while the tiles scrolled")
        XCTAssertTrue(large.buttons["Додати нові картки"].isHittable)
        attach(large, "done-celebration-ax5")
    }

    /// One new badge and nothing else. The backlog seed's *history* without its
    /// overdue cards (`-seedHistoryOnLaunch`): fourteen days of twenty, none
    /// today — so first session, streak 7 and 100 reviews are already earned,
    /// and the launch marks them shown. A session on the ten-card sample deck
    /// alone: the mastery deck still owes today (no goal line); today cannot
    /// beat a best day of twenty and extending a run does not move its start,
    /// so no record; ten Easy ratings are the one new thing — a perfect session,
    /// which the launch deliberately leaves unshown.
    func testTheDoneScreenCanCelebrateOneBadgeAlone() {
        let app = launch(["-resetStoreOnLaunch", "-seedHistoryOnLaunch", "-seedMasteryOnLaunch",
                          "-markHistoryBadgesShownOnLaunch"])
        let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "the sample deck's row never appeared")
        row.tap()
        finishSessionByHand(app)
        XCTAssertFalse(app.descendants(matching: .any)["done.goal"].exists, "the other deck still owes today")
        XCTAssertFalse(app.descendants(matching: .any)["done.record"].exists, "today cannot beat a best day of twenty")
        XCTAssertTrue(app.descendants(matching: .any)["done.badge.perfect-session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["done.badge.first-session"].exists, "already shown before the session")
        attach(app, "done-one-badge")
    }

    /// Nothing applies: the same deck-scoped session, after the perfect session
    /// has been shown too. The Done screen is the plain one — and, at AX1, still
    /// the *centred* one: #89's screen is not taken away from a size that fits
    /// it, so the second half of this test finishes the same fixture again with
    /// the content size category raised and reads the layout off the screen.
    func testTheDoneScreenStaysQuietWhenNothingIsNew() {
        let fixture = ["-resetStoreOnLaunch", "-seedHistoryOnLaunch", "-seedMasteryOnLaunch",
                       "-markHistoryBadgesShownOnLaunch", "-markPerfectSessionShownOnLaunch"]
        let app = launch(fixture)
        let row = app.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        row.tap()
        finishSessionByHand(app)
        XCTAssertFalse(app.descendants(matching: .any)["done.goal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["done.record"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["done.badge.perfect-session"].exists,
                       "the perfect session was shown before this launch")
        XCTAssertFalse(app.descendants(matching: .any)["done.badges"].exists, "no badge is new, no tiles")
        attach(app, "done-quiet")

        // AX1, the size the old `isAccessibilitySize` branch started scrolling
        // at. A quiet screen still fits there, so `ViewThatFits` must keep it
        // centred — the shot is the assertion the tree cannot make.
        app.terminate()
        let large = XCUIApplication()
        large.launchArguments = ["-AppleLanguages", "(uk)", "-AppleLocale", "uk_UA",
                                 "-UIPreferredContentSizeCategoryName",
                                 "UICTContentSizeCategoryAccessibilityM"] + fixture
        large.launch()
        let largeRow = large.descendants(matching: .any)["home.deck.Англійська — дієслова"]
        XCTAssertTrue(largeRow.waitForExistence(timeout: Self.timeout))
        largeRow.tap()
        finishSessionByHand(large)
        XCTAssertTrue(large.staticTexts["done.title"].exists)
        XCTAssertTrue(large.buttons["До колод"].isHittable, "at AX1 the quiet screen lost its first button")
        XCTAssertTrue(large.buttons["Додати нові картки"].isHittable, "at AX1 the quiet screen lost its second button")
        attach(large, "done-quiet-ax1")
    }

    /// §5.5 meets §5.4: undo stays reachable on the Done screen, so the ledger is
    /// written when the screen is *left* by a button, never when it appears. Two
    /// fixtures, one dimension each: leave by the button and the badge is earned
    /// in Stats; quit on the screen and it is not.
    ///
    /// The relaunches carry `-seedSampleDataOnLaunch` and nothing else. It is not
    /// a seed here — `seedIfEmpty` is a no-op on the store the first launch left
    /// behind — it is the suppressor: onboarding is skipped for any argument
    /// ending in `OnLaunch`, and a relaunch with none at all would open it on top
    /// of Stats.
    func testTheLedgerIsWrittenWhenTheDoneScreenIsLeftNotWhenItAppears() {
        let left = launch(["-resetStoreOnLaunch", "-seedRecordHistoryOnLaunch",
                           "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(left.descendants(matching: .any)["done.badge.first-session"].waitForExistence(timeout: Self.timeout))
        left.buttons["До колод"].tap()
        XCTAssertTrue(left.buttons["home.startSession"].waitForExistence(timeout: Self.timeout))
        left.terminate()
        let afterLeaving = launch(["-seedSampleDataOnLaunch"])   // no reset: the ledger and the store survive
        XCTAssertTrue(afterLeaving.buttons["Статистика"].waitForExistence(timeout: Self.timeout))
        afterLeaving.buttons["Статистика"].tap()
        let earned = afterLeaving.descendants(matching: .any)["badge.first-session"]
        for _ in 0..<8 where !earned.exists { afterLeaving.swipeUp() }
        XCTAssertTrue(earned.waitForExistence(timeout: 5))
        XCTAssertTrue(earned.label.hasPrefix("Перша сесія, здобуто"), earned.label)
        afterLeaving.terminate()

        let quit = launch(["-resetStoreOnLaunch", "-seedRecordHistoryOnLaunch",
                           "-startSessionOnLaunch", "-finishSessionOnLaunch"])
        XCTAssertTrue(quit.descendants(matching: .any)["done.badge.first-session"].waitForExistence(timeout: Self.timeout))
        quit.terminate()                                    // on the Done screen, no button
        let afterQuitting = launch(["-seedSampleDataOnLaunch"])
        XCTAssertTrue(afterQuitting.buttons["Статистика"].waitForExistence(timeout: Self.timeout))
        afterQuitting.buttons["Статистика"].tap()
        let locked = afterQuitting.descendants(matching: .any)["badge.first-session"]
        for _ in 0..<8 where !locked.exists { afterQuitting.swipeUp() }
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        XCTAssertEqual(locked.label, "Перша сесія, завершіть першу сесію", "appearing is not showing")
    }

    /// The ten-card sample deck, rated Easy until the Done screen — the loop
    /// `testAWholeSessionCanBeCompleted` uses, for a session started by a row tap.
    private func finishSessionByHand(_ app: XCUIApplication) {
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
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout), "the session never reached the Done screen")
    }
}

private extension NSPredicate {
    /// Waits for an element's attributes to settle on a value, where
    /// `waitForExistence` would pass on the stale value already there.
    func wait(for element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: self, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
