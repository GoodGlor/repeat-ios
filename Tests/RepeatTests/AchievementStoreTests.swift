import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// `Achievements.Facts.make` against a real store, and the three things the
/// card's acceptance asks to be proved on the store rather than on hand-built
/// facts: an undo un-unlocks, a rebuild from `_log` reproduces the set, and
/// the numbers come from queries rather than walks.
@MainActor
final class AchievementStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// 15 January 2027, 12:00 Kyiv.
    private static let noon = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelStore.container(inMemory: true)
        context = ModelContext(container)
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func deck(_ title: String = "Verbs", deleted: Bool = false) -> Deck {
        let deck = Deck(sheetTitle: title, sheetId: title.hashValue & 0xFFFF)
        if deleted { deck.deletedAt = Self.noon }
        context.insert(deck)
        return deck
    }

    /// One note in `deck`, its cards made the way sync makes them.
    @discardableResult
    private func note(_ front: String, in deck: Deck, reverse: Bool = false, deleted: Bool = false) -> [Card] {
        let note = Note(deck: deck, front: front, back: "—", reverse: reverse, sheetRow: 0)
        if deleted { note.deletedAt = Self.noon }
        context.insert(note)
        return context.syncCards(for: note, now: Self.noon)
    }

    private func know(_ cards: [Card], state: SchedulingState = .review, stability: Double = 30) {
        for card in cards {
            card.state = state
            card.stability = stability
            card.lastReview = Self.noon.addingTimeInterval(-86_400)
            card.due = Self.noon.addingTimeInterval(20 * 86_400)
        }
    }

    private func facts(now: Date = noon) throws -> Achievements.Facts {
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
        return Achievements.Facts.make(in: context, logs: logs, owedToday: 0,
                                       now: now, calendar: Self.calendar)
    }

    private static func sheetRow(cardId: String, rating: Int, at date: Date) -> [String] {
        [cardId, "forward", String(rating), SheetPush.timestamp.string(from: date), "0", "0", "new"]
    }

    // MARK: - The numbers come from the store

    func testKnownWordsCountsNotesNotCards() throws {
        let deck = deck()
        know(note("harbour", in: deck, reverse: true))   // two known cards, one word
        know(note("meadow", in: deck))                   // one known card
        know(note("pebble", in: deck), stability: 10)    // learning, not known
        know(note("gentle", in: deck), state: .relearning, stability: 40)   // forgotten: learning however stable
        note("lantern", in: deck)                        // new
        try context.save()

        XCTAssertEqual(try facts().knownWords, 2)
    }

    func testKnownWordsIgnoreSoftDeletedNotesAndDecks() throws {
        let live = deck("Live")
        know(note("harbour", in: live))
        know(note("gone", in: live, deleted: true))
        let removed = deck("Removed", deleted: true)
        know(note("orchard", in: removed))
        try context.save()

        let facts = try facts()
        XCTAssertEqual(facts.knownWords, 1)
        XCTAssertEqual(facts.liveDecks, 1)
    }

    func testDueAnywhereIsTheQueueBuildersDefinition() throws {
        let deck = deck()
        let due = note("due", in: deck)
        know(due); due[0].due = Self.noon.addingTimeInterval(-60)
        let suspended = note("suspended", in: deck)
        know(suspended); suspended[0].due = Self.noon.addingTimeInterval(-60); suspended[0].isSuspended = true
        note("new", in: deck)[0].due = Self.noon.addingTimeInterval(-60)   // new cards are not "due"
        let later = note("later", in: deck)
        know(later)
        // `deck` is the local above, so the fixture is called on self.
        let removed = self.deck("Removed", deleted: true)
        let orphan = note("orphan", in: removed)
        know(orphan); orphan[0].due = Self.noon.addingTimeInterval(-60)   // due, but its deck is gone
        try context.save()

        XCTAssertEqual(try facts().dueAnywhere, 1)
    }

    func testReviewsAreRealOnesInOrderAndMarkersAreDropped() throws {
        let deck = deck()
        let cards = note("harbour", in: deck)
        let scheduler = Scheduler()
        let first = Self.noon.addingTimeInterval(-3_600)
        try context.rate(cards[0], .good, with: scheduler, now: first)
        try context.rate(cards[0], .again, with: scheduler, now: first.addingTimeInterval(60))
        let marker = try ReviewLog(cardId: cards[0].id, direction: .forward, rating: 0, reviewedAt: Self.noon,
                                   elapsedDays: 0, scheduledDays: 0, stateBefore: .review,
                                   prevState: CardSchedulingSnapshot())
        context.insert(marker)
        try context.save()

        let facts = try facts()
        XCTAssertEqual(facts.reviews.map(\.rating), [Grade.good.rawValue, Grade.again.rawValue])
        XCTAssertEqual(facts.reviews.map(\.at), [first, first.addingTimeInterval(60)])
        XCTAssertEqual(facts.records.longestStreak, 1)
    }

    // MARK: - Acceptance: undo un-unlocks, ledger untouched

    func testAnUndoBelowTheLineTakesTheBadgeBackAndLeavesTheLedgerAlone() throws {
        let deck = deck()
        let cards = note("harbour", in: deck)
        let scheduler = Scheduler()
        var last: ReviewLog?
        for step in 0..<100 {
            last = try context.rate(cards[0], .good, with: scheduler,
                                    now: Self.noon.addingTimeInterval(Double(step - 100) * 60))
        }
        try context.save()
        let defaults = UserDefaults(suiteName: "AchievementStoreTests.\(UUID().uuidString)")!
        let ledger = AchievementLedger(defaults: defaults)

        let before = Achievements.evaluate(facts: try facts(), ledger: ledger)
        XCTAssertTrue(before.unlocked.contains(.reviews100))
        ledger.markShown(before.fresh)   // what the Done screen will do (#108)

        // An in-session undo of a rating not yet uploaded deletes its row —
        // `StudySession.undo`, the `else` branch.
        context.delete(try XCTUnwrap(last))
        try context.save()

        let after = Achievements.evaluate(facts: try facts(), ledger: ledger)
        XCTAssertFalse(after.unlocked.contains(.reviews100), "99 reviews is not a hundred")
        XCTAssertFalse(after.fresh.contains(.reviews100))
        XCTAssertTrue(ledger.shown.contains("reviews-100"), "the ledger is not corrected — it records what was shown")
    }

    // MARK: - Acceptance: a rebuild from _log reproduces the set

    func testRebuildingFromTheLogReproducesTheUnlockedSet() async throws {
        let deck = deck()
        let cards = note("harbour", in: deck)
        let scheduler = Scheduler()
        var rows: [[String]] = []
        // Twelve daily reviews ending at noon on the 15th: first session, a
        // streak of 12 (so streak-7), and nothing due after the last one.
        for step in 0..<12 {
            let at = Self.noon.addingTimeInterval(Double(step - 11) * 86_400)
            try context.rate(cards[0], .good, with: scheduler, now: at)
            rows.append(Self.sheetRow(cardId: cards[0].id, rating: Grade.good.rawValue, at: at))
        }
        try context.save()
        let live = Achievements.unlocked(try facts())
        XCTAssertEqual(live, [.firstSession, .streak7, .allDecksGreen])

        // The wipe: scheduling back to a brand new card that is overdue, log
        // untouched. Green is gone — the card is due.
        cards[0].restore(from: CardSchedulingSnapshot())
        cards[0].lastReview = Self.noon.addingTimeInterval(-86_400)
        cards[0].state = .review
        cards[0].due = Self.noon.addingTimeInterval(-60)
        try context.save()
        XCTAssertEqual(Achievements.unlocked(try facts()), [.firstSession, .streak7])

        try await RebuildScheduling.apply(
            LogReplay.parse([LogPush.header] + rows), in: context,
            config: SchedulerConfig(), backupDirectory: directory, now: Self.noon
        )

        XCTAssertEqual(Achievements.unlocked(try facts()), live)
    }

    // MARK: - Acceptance: on its own queue

    func testBuildingFactsTouchesTheContextOnlyOnItsOwnQueue() throws {
        let deck = deck()
        know(note("harbour", in: deck))
        try context.save()
        let start = Date()

        _ = try facts()

        XCTAssertEqual(try OffQueue.uses(since: start), [])
    }
}
