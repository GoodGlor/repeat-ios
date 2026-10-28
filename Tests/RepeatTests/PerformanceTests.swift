import XCTest
import SwiftUI
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
            StreakFreeze.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// The seed generator the card asks for. Cards are spread across several
    /// decks and split between due reviews and new, because a queue build that
    /// only ever sees one shape is not the queue build that ships.
    @discardableResult
    private func seed(cards count: Int, decks deckCount: Int = 4, now: Date = .now,
                      known: (Int) -> Bool = { _ in false }) throws -> [Deck] {
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
                // 20 is one under `Mastery.knownStability`; a caller that wants
                // known cards on the path says which (#107).
                card.stability = known(index) ? 30 : 20
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

    // MARK: - #106: mastery over 10k cards reads columns, not relationships

    /// `HomeSummary.make` already materialises every card of every deck; the
    /// bar adds three column reads per card to that. Measured on the cards
    /// after the walk, because the walk is Home's existing cost, not this
    /// feature's. If this ever climbs, look for `card.note` on the path.
    func testMasteryCountsForTenThousandCardsAreCheap() throws {
        let now = Date()
        let decks = try seed(cards: 10_000, now: now)
        let cards = decks.flatMap { $0.notes.flatMap(\.cards) }
        XCTAssertEqual(cards.count, 10_000, "the fixture did not materialise every card")

        // Warm the same fault `HomeSummary.make` already pays before it ever
        // reaches a mastery count: its `deckOfCard` pass reads `card.id` for
        // every card while indexing the plan. Without this line the walk above
        // returns faults, and the *first* column read anywhere below would be
        // the one to unfault all 10k rows — timing this feature for a cost that
        // is really #84's relationship-walk cost, already paid by the caller.
        _ = cards.map(\.id)

        let started = Date()
        let counts = Mastery.Counts.make(cards: cards)
        let elapsed = Date().timeIntervalSince(started)

        // The seed's review cards sit at stability 20 — one under the threshold.
        XCTAssertEqual(counts, Mastery.Counts(known: 0, learning: 6_666, new: 3_334))
        print("MEASURED mastery counts, 10k cards: \(String(format: "%.3f", elapsed))s (budget 0.300s)")
        XCTAssertLessThan(elapsed, 0.300,
                          "mastery counts took \(String(format: "%.3f", elapsed))s — "
                          + "something on the path is faulting a relationship")
    }

    // MARK: - #116: a Home refresh at 10k cards, measured on the real view

    /// `HomeView.body` read its summary in thirteen places, and `summary` was a
    /// computed property — thirteen `HomeSummary.make` calls a pass. The unit
    /// tests time one call on a warm context, which is exactly what hid this:
    /// hosting the real view over the 10k fixture measured **8.4 s** for its
    /// first showing. Building the summary once per pass took that to 6.9 s;
    /// the rest was the `deck.notes → note.cards` walk itself, cold on every
    /// pass because each fetch of the parent (the `@Query`'s included) re-faults
    /// the relationships — 2.4 s a walk. `make` and `Leech.all` now select cards
    /// by query, as `QueueBuilder` has since #84, and the showing measures 1.0 s.
    ///
    /// The window is what a user waits for: the first body pass, the `.task`
    /// that rebuilds the plan, and the pass that rebuild triggers.
    ///
    /// Since #107 the pass also builds the badge facts, and the test sweeps
    /// for off-queue context use.
    @MainActor
    func testFirstHomeShowingForTenThousandCardsStaysCheap() throws {
        let sweepStart = Date()
        try seed(cards: 10_000)
        let host = UIHostingController(rootView: HomeView().modelContainer(container))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let started = Date()
        host.view.layoutIfNeeded()
        let elapsed = Date().timeIntervalSince(started)

        // The showing has to have happened for the timing to mean anything: an
        // unrendered host has no subviews.
        XCTAssertFalse(host.view.subviews.isEmpty, "Home never rendered — the timing above is empty")
        print("MEASURED first Home showing, 10k cards: \(String(format: "%.3f", elapsed))s (budget 1.500s)")
        XCTAssertLessThan(elapsed, 1.500,
                          "the first Home showing took \(String(format: "%.3f", elapsed))s — "
                          + "is something on the path walking `deck.notes → note.cards` again?")
        // #107: evaluation runs inside `rebuildPlan()`, on the main actor. The
        // sweep is the card's acceptance line, taken at the real call site.
        XCTAssertEqual(try OffQueue.uses(since: sweepStart), [])
    }

    // MARK: - #121: a deck's card list opens by query, not by walking

    /// The card asks for "under 0.3 s", and the number is really a claim about
    /// *how* the notes are selected. `deck.notes → note.cards` measured **2.4 s**
    /// on this same fixture in #116, so a screen that walked would not be close.
    ///
    /// This measures the fetch `DeckCardsView.init` issues. The showing is
    /// measured separately below, because the two can fail for different reasons
    /// and a single number would hide which.
    func testADecksCardListSelectsByQueryForTenThousandCards() throws {
        let decks = try seed(cards: 10_000)
        let title = try XCTUnwrap(decks.first).sheetTitle

        let started = Date()
        let notes = try context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { note in
                note.deletedAt == nil
                    && note.deck.deletedAt == nil
                    && note.deck.sheetTitle == title
            },
            sortBy: [SortDescriptor(\Note.front)]
        ))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(notes.count, 2_500, "ten thousand notes across four decks")
        print("MEASURED deck card selection, 10k cards: \(String(format: "%.3f", elapsed))s (budget 0.300s)")
        XCTAssertLessThan(elapsed, 0.300,
                          "selecting one deck's notes took \(String(format: "%.3f", elapsed))s — "
                          + "is the predicate still doing the work, or has a walk crept back in?")
    }

    /// And the screen itself, the way `testFirstHomeShowingForTenThousandCards`
    /// `StaysCheap` measures Home.
    ///
    /// The list is lazy, so this is the test that would catch it if that stopped
    /// being true — a `List` that built all ten thousand rows would compute ten
    /// thousand hints, and each hint touches `note.cards`.
    @MainActor
    func testADecksCardListShowingForTenThousandCardsStaysCheap() throws {
        let sweepStart = Date()
        let decks = try seed(cards: 10_000)
        let deck = try XCTUnwrap(decks.first)

        let host = UIHostingController(
            rootView: NavigationStack { DeckCardsView(deck: deck) }.modelContainer(container)
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let started = Date()
        host.view.layoutIfNeeded()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(host.view.subviews.isEmpty, "the list never rendered — the timing above is empty")
        print("MEASURED deck card list showing, 10k cards: \(String(format: "%.3f", elapsed))s (budget 1.500s)")
        XCTAssertLessThan(elapsed, 1.500,
                          "showing one deck's cards took \(String(format: "%.3f", elapsed))s — "
                          + "is the list still lazy, or is every row computing a hint?")
        XCTAssertEqual(try OffQueue.uses(since: sweepStart), [])
    }

    // MARK: - #107: the badge facts at 10k cards come from queries

    /// `Achievements.Facts.make` runs on every `rebuildPlan()`. Seeded so the
    /// known-word path has work to do (gotcha 54): every fourth review card is
    /// known, which is 1 667 known cards over 1 667 notes.
    func testAchievementFactsForTenThousandCardsAreCheap() throws {
        let now = Date()
        try seed(cards: 10_000, now: now, known: { $0 % 4 == 1 })
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        let started = Date()
        let facts = Achievements.Facts.make(in: context, logs: logs, owedToday: 6_666, now: now)
        let elapsed = Date().timeIntervalSince(started)

        // index % 3 != 0 && index % 4 == 1 over 0..<10_000.
        XCTAssertEqual(facts.knownWords, 1_667)
        XCTAssertEqual(facts.liveDecks, 4)
        XCTAssertEqual(facts.dueAnywhere, 6_666, "every review card in the seed is due, known or not")
        print("MEASURED achievement facts, 10k cards: \(String(format: "%.3f", elapsed))s (budget 0.300s)")
        XCTAssertLessThan(elapsed, 0.300,
                          "building the facts took \(String(format: "%.3f", elapsed))s — "
                          + "is something on the path walking a relationship per row?")
    }

    // MARK: - #144: a deck opened, and a session over one tag

    /// All ten thousand cards in **one** deck, the worst shape for both halves:
    /// every note's tags are read, and a rare tag's new cards sit spread through
    /// the whole deck, so the new-card window has to page far to fill.
    ///
    /// The first version read the tags on the main queue and measured 0.62 s to
    /// open and 0.65 s for the tag plan — 0.40 s of each was materialising ten
    /// thousand notes. That is why the read moved off the main queue.
    func testOpeningADeckAndPlanningOneTagForTenThousandCards() async throws {
        let now = Date()
        let deck = try XCTUnwrap(try seed(cards: 10_000, decks: 1, now: now).first)
        let notes = try context.fetch(FetchDescriptor<Note>())
        for (index, note) in notes.enumerated() {
            note.tags = index % 50 == 0 ? ["rare", "t\(index % 7)"] : ["t\(index % 7)"]
        }
        try context.save()
        var generator = SystemRandomNumberGenerator()

        // The whole deck's plan: a deck never filtered pays nothing for tags.
        let opened = Date()
        let whole = QueueBuilder.plan(decks: [deck], filters: [:], now: now, using: &generator)
        let openElapsed = Date().timeIntervalSince(opened)

        // The background read. Recorded, not held to the 0.3 s: it is off the
        // main queue, and what waits for it is the picker, not the screen.
        let reading = Date()
        let index = await DeckFilter.TagIndex.load(deckTitled: deck.sheetTitle, from: container)
        let indexElapsed = Date().timeIntervalSince(reading)

        let tagged = Date()
        let rare = QueueBuilder.plan(decks: [deck], filters: [deck.sheetTitle: .tag("rare")], tagIndexes: [deck.sheetTitle: index],
                                     now: now, using: &generator)
        let tagElapsed = Date().timeIntervalSince(tagged)

        // And a common tag, 1 429 notes (every seventh). Both go through the
        // SQL list; a tag over `sqlNoteLimit` takes the in-memory path, whose
        // answer `DeckFilterTests` holds equal to this one.
        let wide = Date()
        let common = QueueBuilder.plan(decks: [deck], filters: [deck.sheetTitle: .tag("t0")], tagIndexes: [deck.sheetTitle: index],
                                       now: now, using: &generator)
        let wideElapsed = Date().timeIntervalSince(wide)
        XCTAssertGreaterThan(common.count, 0)
        print("MEASURED common-tag plan (1 429 notes), 10k cards: \(String(format: "%.3f", wideElapsed))s (budget 0.300s)")
        XCTAssertLessThan(wideElapsed, 0.300, "the common-tag plan took \(String(format: "%.3f", wideElapsed))s")

        XCTAssertEqual(index.options.count, 9, "everything, rare and t0…t6")
        XCTAssertGreaterThan(whole.count, 0)
        XCTAssertGreaterThan(rare.dueReviewCount, 0)
        XCTAssertGreaterThan(rare.newCardCount, 0, "the rare tag's new cards were never reached")
        print("MEASURED deck open, 10k cards: \(String(format: "%.3f", openElapsed))s (budget 0.300s)")
        print("MEASURED tag index read (background), 10k cards: \(String(format: "%.3f", indexElapsed))s")
        print("MEASURED tag plan, 10k cards: \(String(format: "%.3f", tagElapsed))s (budget 0.300s)")
        XCTAssertLessThan(openElapsed, 0.300, "opening the deck took \(String(format: "%.3f", openElapsed))s")
        XCTAssertLessThan(tagElapsed, 0.300, "the tag plan took \(String(format: "%.3f", tagElapsed))s")
    }

    /// #153: Home's plan over four decks of 2 500 with one of them tagged in its
    /// settings. The first build reads that deck's tags (the note fetch); every
    /// later one — the rebuilds on appear, foreground and after a session — finds
    /// them in `TagIndexCache` and must stay inside §8's 0.3 s.
    func testHomesPlanWithOneDeckTaggedInItsSettings() throws {
        let now = Date()
        let decks = try seed(cards: 10_000, now: now)
        let tagged = decks[0].sheetTitle
        for (index, note) in try context.fetch(FetchDescriptor<Note>()).enumerated() {
            note.tags = ["t\(index % 5)"]
        }
        try context.save()
        TagIndexCache.shared.invalidate()
        DeckFilter.remember(.tag("t0"), forDeckTitled: tagged)
        defer {
            UserDefaults.standard.removeObject(forKey: "deckFilter." + tagged)
            TagIndexCache.shared.invalidate()
        }
        _ = decks.map(\.notes.count)
        var generator = SystemRandomNumberGenerator()

        let cold = Date()
        let first = QueueBuilder.plan(decks: decks, now: now, using: &generator)
        let coldElapsed = Date().timeIntervalSince(cold)
        let warm = Date()
        let again = QueueBuilder.plan(decks: decks, now: now, using: &generator)
        let warmElapsed = Date().timeIntervalSince(warm)

        XCTAssertEqual(first.filters, [tagged: .tag("t0")])
        XCTAssertEqual(Set(first.cardIds), Set(again.cardIds))
        print("MEASURED Home plan, one deck tagged, 10k cards: cold \(String(format: "%.3f", coldElapsed))s, "
              + "warm \(String(format: "%.3f", warmElapsed))s (budget 0.300s)")
        XCTAssertLessThan(warmElapsed, 0.300, "Home's plan with a tagged deck took \(String(format: "%.3f", warmElapsed))s")
    }
}
