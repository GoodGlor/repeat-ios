import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #39 — §2 and §8 state three numbers. This measures them instead of assuming.
///
/// These run in the simulator, which is faster than a phone at CPU and slower at
/// nothing that matters here, so a *pass* is weaker evidence than a device run
/// and a *fail* is strong. Any miss is recorded in the handoff and filed as its
/// own card, per the acceptance line.
final class PerformanceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self, SyncConflict.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// The seed generator the card asks for. Cards are spread across several
    /// decks and split between due reviews and new, because a queue build that
    /// only ever sees one shape is not the queue build that ships.
    @discardableResult
    private func seed(cards count: Int, decks deckCount: Int = 4, now: Date = .now) throws -> [Deck] {
        var decks: [Deck] = []
        for index in 0..<deckCount {
            let deck = Deck(sheetTitle: "Deck \(index)", sheetId: index, sortOrder: index)
            context.insert(deck)
            decks.append(deck)
        }
        for index in 0..<count {
            let deck = decks[index % deckCount]
            let note = Note(id: Self.uuid(index), deck: deck,
                            front: "front \(index)", back: "back \(index)",
                            sheetRow: index)
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            // Two thirds are due reviews, the rest new — roughly the shape of a
            // real collection that has been running a while.
            if index % 3 != 0 {
                card.state = .review
                card.reps = 3
                card.stability = 20
                card.difficulty = 6
                card.lastReview = now.addingTimeInterval(-10 * 86_400)
                card.due = now.addingTimeInterval(-Double(index % 5) * 86_400)
            }
            context.insert(card)
        }
        try context.save()
        return decks
    }

    private static func uuid(_ seed: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!
    }

    // MARK: - §8: queue build for 10k cards < 300 ms

    func testQueueBuildForTenThousandCards() throws {
        let now = Date()
        let decks = try seed(cards: 10_000, now: now)
        var generator = SystemRandomNumberGenerator()

        // Warm the relationship faults the way a real launch would: the plan is
        // built after the decks have already been fetched and shown on Home.
        _ = decks.map(\.notes.count)

        let started = Date()
        let plan = QueueBuilder.plan(decks: decks, now: now, using: &generator)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(plan.dueReviewCount, 0, "the fixture produced no due cards")
        print("MEASURED queue build, 10k cards: \(String(format: "%.3f", elapsed))s (budget 0.300s)")

        // #84 brought this from 2.79 s to ~0.20 s by selecting cards with a
        // `#Predicate` instead of walking Deck → Note → Card. The ceiling is now
        // §8's actual budget, as that card's acceptance line requires.
        //
        // That leaves about 1.5× of headroom, which is real but not generous — a
        // loaded machine could plausibly cross it. If this starts failing, the
        // first move is to check whether something put a relationship access back
        // on the path, **not** to raise the number: 0.20 against 0.30 is the whole
        // margin, and raising it is how the 2.8 s went unnoticed for forty cards.
        XCTAssertLessThan(elapsed, 0.300,
                          "queue build took \(String(format: "%.3f", elapsed))s against "
                          + "§8's 300 ms budget")
    }

    /// New cards are ordered by `(sheetRow, note id, direction)` even when every
    /// row index is the same.
    ///
    /// This is the assumption that fails quietly: a deck whose rows repeat still
    /// *produces* a queue, just not the documented one, and no other test would
    /// notice. It is also not hypothetical — the first version of #84's fix sorted
    /// on `sheetRow` alone and re-sorted a wider window in memory, and this test
    /// failed it on the first run: SQLite returned an arbitrary 36 of the 60 rows
    /// and the ten that should have come first were not among them. The fix was to
    /// sort completely in SQL rather than to widen the window.
    func testNewCardOrderSurvivesDuplicatedSheetRows() throws {
        let deck = Deck(sheetTitle: "Dupes", sheetId: 0, newCardsPerDay: 10)
        context.insert(deck)
        for index in 0..<60 {
            let note = Note(id: Self.uuid(index), deck: deck,
                            front: "f\(index)", back: "b\(index)", sheetRow: 0)
            context.insert(note)
            context.insert(Card(note: note, direction: .forward))
        }
        try context.save()

        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: [deck], now: Date(), using: &generator)

        // Every row index is 0, so the order is decided entirely by the note id.
        // The seeded uuids are zero-padded, so id order is index order.
        let expected = (0..<10).map { Card.id(noteId: Self.uuid($0), direction: .forward) }
        XCTAssertEqual(plan.newCardCount, 10)
        XCTAssertEqual(plan.cardIds, expected)
    }

    /// The same measurement without the warm-up, which is what a cold launch
    /// actually pays.
    ///
    /// Before #84 this mattered — the plan walked relationships, so a warmed graph
    /// was measurably cheaper. It now selects by query and the two numbers are the
    /// same to the millisecond, which is itself the evidence that no relationship
    /// traversal is left on the path. Still recorded rather than asserted: §8 does
    /// not say which of the two it means.
    func testQueueBuildFromColdIsRecorded() throws {
        let now = Date()
        let decks = try seed(cards: 10_000, now: now)
        var generator = SystemRandomNumberGenerator()

        let started = Date()
        _ = QueueBuilder.plan(decks: decks, now: now, using: &generator)
        let elapsed = Date().timeIntervalSince(started)

        print("MEASURED queue build from cold, 10k cards: \(String(format: "%.3f", elapsed))s")
    }

    // MARK: - §8: study transitions < 100 ms

    /// A transition is: rate the current card, write its `_log` row, and have the
    /// next card ready. Measured through `StudySession`, which is what the view
    /// calls — timing a bare scheduler call would measure nothing the reader
    /// waits for.
    @MainActor
    func testStudyTransitionsStayUnderOneHundredMilliseconds() throws {
        let now = Date()
        let decks = try seed(cards: 2_000, now: now)
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: decks, now: now, using: &generator)
        let session = StudySession(context: context, plan: plan, decks: decks)

        var worst: TimeInterval = 0
        var total: TimeInterval = 0
        let samples = 50
        for _ in 0..<samples {
            guard session.current != nil else { break }
            let started = Date()
            session.reveal()
            session.rate(.good)
            let elapsed = Date().timeIntervalSince(started)
            worst = max(worst, elapsed)
            total += elapsed
        }

        let mean = total / Double(samples)
        print("MEASURED study transition: mean \(String(format: "%.1f", mean * 1000)) ms, "
              + "worst \(String(format: "%.1f", worst * 1000)) ms (budget 100 ms)")
        XCTAssertLessThan(worst, 0.100,
                          "slowest transition was \(String(format: "%.1f", worst * 1000)) ms")
    }

    // MARK: - §8: sync of 5k rows < 10 s

    /// Drives a real 5k-row pull through `SheetPull` and the scripted backend, so
    /// request building, parsing and the SwiftData merge are all measured — but
    /// **not** the network.
    ///
    /// Recorded rather than asserted, deliberately. §8's 10 s budget is for a
    /// whole round trip over Wi-Fi, and the half this can see says nothing about
    /// the half it cannot. The write path has still never run against the real
    /// spreadsheet, so claiming the budget met would be inventing evidence.
    func testPullingFiveThousandRowsIsRecorded() async throws {
        var rows: [[String]] = [SheetSyncHarness.header]
        for index in 0..<5_000 {
            rows.append([Self.uuid(index).uuidString, "front \(index)", "back \(index)",
                         "", "", "FALSE", "FALSE"])
        }
        let stub = SheetStub(rows: ["Verbs": rows])
        let (ctx, _) = try SheetSyncHarness.makeContext()
        let pull = try SheetSyncHarness.makePull(stub)

        let started = Date()
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(),
                                        in: ctx, now: .now)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.created, 5_000)
        print("MEASURED pull + merge of 5k rows: \(String(format: "%.2f", elapsed))s "
              + "(network excluded; §8's 10 s budget covers the whole round trip)")
    }
}
