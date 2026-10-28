import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #121 — the hint on each row of a deck's card list.
@MainActor
final class DeckCardsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self, SyncConflict.self,
            StreakFreeze.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    // MARK: - Fixtures

    private func note(_ seed: Int = 1) -> Note {
        let deck = Deck(sheetTitle: "Дієслова", sheetId: 1)
        context.insert(deck)
        let note = Note(id: UUID(), deck: deck, front: "front \(seed)", back: "back \(seed)")
        context.insert(note)
        return note
    }

    @discardableResult
    private func card(
        _ note: Note,
        _ direction: Direction = .forward,
        state: SchedulingState = .new,
        due: Date? = nil,
        stability: Double = 0,
        reviewed: Bool = false,
        suspended: Bool = false
    ) -> Card {
        let card = Card(note: note, direction: direction, due: due ?? now)
        card.state = state
        card.stability = stability
        card.lastReview = reviewed ? now.addingTimeInterval(-86_400) : nil
        card.isSuspended = suspended
        context.insert(card)
        return card
    }

    private func hint(_ cards: [Card]) -> DeckCards.Hint {
        DeckCards.hint(for: cards, now: now)
    }

    // MARK: - One card

    func testAnUntouchedCardIsNew() {
        let note = note()
        XCTAssertEqual(hint([card(note)]), .new)
    }

    func testACardWhoseTimeHasComeIsDue() {
        let note = note()
        let due = card(note, state: .review, due: now.addingTimeInterval(-3600),
                       stability: 5, reviewed: true)
        XCTAssertEqual(hint([due]), .due)
    }

    func testAReviewCardStillWaitingIsNotDue() {
        let note = note()
        let later = card(note, state: .review, due: now.addingTimeInterval(3 * 86_400),
                         stability: 5, reviewed: true)
        XCTAssertEqual(hint([later]), .learning, "reviewed, not yet known, and not yet waiting")
    }

    /// The threshold is `Mastery.knownStability`, not a second definition — the
    /// Stats screen and this list have to agree about the same word.
    func testACardPastTheKnownThresholdIsKnown() {
        let note = note()
        let known = card(note, state: .review, due: now.addingTimeInterval(30 * 86_400),
                         stability: Mastery.knownStability, reviewed: true)
        XCTAssertEqual(hint([known]), .known)
    }

    func testACardJustUnderTheThresholdIsStillLearning() {
        let note = note()
        let nearly = card(note, state: .review, due: now.addingTimeInterval(30 * 86_400),
                          stability: Mastery.knownStability - 0.01, reviewed: true)
        XCTAssertEqual(hint([nearly]), .learning)
    }

    /// A new card's `due` is its creation date, which is always in the past. If
    /// "due" were just `due <= now`, every new card in the deck would claim to
    /// be waiting for a review it has never had.
    func testANewCardIsNotCalledDueJustBecauseItsDueDateHasPassed() {
        let note = note()
        let fresh = card(note, state: .new, due: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(hint([fresh]), .new)
    }

    // MARK: - Two cards that disagree

    func testSuspendedOnlyWhenEveryCardIs() {
        let note = note()
        let asleep = card(note, .forward, suspended: true)
        let awake = card(note, .reverse, state: .review, due: now.addingTimeInterval(-60),
                         stability: 5, reviewed: true)

        XCTAssertEqual(hint([asleep]), .suspended)
        XCTAssertEqual(hint([asleep, awake]), .due, "one live card is enough to have something to do")
    }

    func testDueOutranksEverythingElse() {
        let note = note()
        let known = card(note, .forward, state: .review, due: now.addingTimeInterval(90 * 86_400),
                         stability: 60, reviewed: true)
        let due = card(note, .reverse, state: .learning, due: now.addingTimeInterval(-60), reviewed: true)
        XCTAssertEqual(hint([known, due]), .due)
        XCTAssertEqual(hint([due, known]), .due, "and the answer does not depend on the order")
    }

    /// A note half learned still has something to learn, so it reads as the
    /// half that does — not as the half that is finished.
    func testTheLeastLearnedCardSpeaksForTheNote() {
        let note = note()
        let known = card(note, .forward, state: .review, due: now.addingTimeInterval(90 * 86_400),
                         stability: 60, reviewed: true)
        let fresh = card(note, .reverse, state: .new, due: now.addingTimeInterval(90 * 86_400))
        XCTAssertEqual(hint([known, fresh]), .new)
    }

    // MARK: - Degenerate

    func testANoteWithNoCardsDoesNotCrashTheList() {
        XCTAssertEqual(hint([]), .new)
    }

    func testEveryHintHasCopy() {
        for hint in DeckCards.Hint.allCases {
            XCTAssertFalse(hint.label.isEmpty, "\(hint) has no label")
        }
    }
}
