import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #41 — D4's second recovery path, and the one that survives losing the phone.
///
/// The load-bearing claim is that replaying `_log` through FSRS reproduces
/// scheduling *exactly*, so most of these compare a replayed snapshot against one
/// produced by the ordinary rating path rather than against a hardcoded number.
/// A test that asserted literals would keep passing if both sides drifted.
@MainActor
final class LogReplayTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self, SyncConflict.self,
            StreakFreeze.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCard(seed: Int) throws -> Card {
        let deck = try deck()
        let note = Note(id: Self.uuid(seed), deck: deck, front: "f\(seed)", back: "b\(seed)")
        context.insert(note)
        let card = Card(note: note, direction: .forward, due: Self.start)
        context.insert(card)
        return card
    }

    static func uuid(_ seed: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!
    }

    private var cachedDeck: Deck?
    private func deck() throws -> Deck {
        if let cachedDeck { return cachedDeck }
        let deck = Deck(sheetTitle: "Дієслова", sheetId: 1)
        context.insert(deck)
        cachedDeck = deck
        return deck
    }

    private static func sheetRow(cardId: String, rating: Int, at date: Date) -> [String] {
        [cardId, "forward", String(rating), SheetPush.timestamp.string(from: date),
         "0", "0", "new"]
    }

    private static func sheet(_ rows: [[String]]) -> [[String]] {
        [LogPush.header] + rows
    }

    // MARK: - The core claim

    /// Acceptance: "on a device with intact state, rebuilding produces
    /// byte-identical scheduling to what was already there".
    ///
    /// Built by actually rating the card through `ModelContext.rate`, then
    /// replaying the log those ratings produced. If the replay and the live path
    /// ever diverge, this fails — which no comparison against a fixed expected
    /// value could promise.
    func testReplayReproducesWhatRatingProduced() throws {
        let card = try makeCard(seed: 1)
        let scheduler = Scheduler()
        let grades: [Grade] = [.good, .again, .good, .easy, .hard, .good]

        var rows: [[String]] = []
        for (step, grade) in grades.enumerated() {
            let at = Self.start.addingTimeInterval(Double(step + 1) * 86_400)
            try context.rate(card, grade, with: scheduler, now: at)
            rows.append(Self.sheetRow(cardId: card.id, rating: grade.rawValue, at: at))
        }
        try context.save()
        let live = card.snapshot

        let parse = LogReplay.parse(Self.sheet(rows))
        let replayed = LogReplay.replay(parse.rows, scheduler: scheduler)

        XCTAssertEqual(replayed[card.id], live)
    }

    /// #112: a rebuild replays `_log`, and `_log` has no row for a day on which
    /// nothing happened — so a rebuild can neither recreate a freeze nor be
    /// allowed to destroy one. `RebuildScheduling.apply` iterates `Card`s only,
    /// which makes this true today by accident; the test makes it true on
    /// purpose.
    func testARebuildFromTheLogLeavesFreezesAlone() async throws {
        let card = try makeCard(seed: 1)
        let scheduler = Scheduler()
        let at = Self.start.addingTimeInterval(86_400)
        try context.rate(card, .good, with: scheduler, now: at)

        let frozen = Calendar.current.startOfDay(for: Self.start)
        context.insert(StreakFreeze(day: frozen, spentAt: Self.start))
        try context.save()

        let rows = [Self.sheetRow(cardId: card.id, rating: Grade.good.rawValue, at: at)]
        let report = try await RebuildScheduling.apply(
            LogReplay.parse(Self.sheet(rows)), in: context,
            config: SchedulerConfig(), backupDirectory: directory, now: Self.start
        )

        XCTAssertEqual(report.cardsRebuilt, 1, "the rebuild has to have actually run")
        XCTAssertEqual(Freeze.days(in: context), [frozen],
                       "the rebuild ate a freeze it could never put back")
    }

    /// #122: the Easy/Good separation lives in `Scheduler.apply`, which is the
    /// same door replay goes through — so a rebuilt card has to land on the
    /// adjusted date rather than the one FSRS would have produced on its own. If
    /// the fix had gone into the study screen instead, this is the test that
    /// would have caught it.
    ///
    /// The ratings happen at the card's own due dates, minutes apart, because
    /// that is the only way to reach the collapse at all: leave a day between
    /// ratings and stability rises enough that Good and Easy separate unaided.
    func testReplayReproducesTheAdjustedEasyGraduation() throws {
        let card = try makeCard(seed: 1)
        let scheduler = Scheduler()

        var rows: [[String]] = []
        var at = Self.start
        for grade in [Grade.again, .good] {
            try context.rate(card, grade, with: scheduler, now: at)
            rows.append(Self.sheetRow(cardId: card.id, rating: grade.rawValue, at: at))
            at = card.due
        }

        // The collapse, caught in the act: Good sits on `nextInterval`'s one-day
        // floor, and before #122 Easy sat on the very same date.
        let graduating = try scheduler.preview(for: card.snapshot, now: at)
        let good = try XCTUnwrap(graduating[.good])
        let easy = try XCTUnwrap(graduating[.easy])
        XCTAssertEqual(good.due.timeIntervalSince(at), 86_400, "Good is on the one-day floor")
        XCTAssertEqual(easy.due.timeIntervalSince(good.due), 86_400, "and Easy is a day past it")

        try context.rate(card, .easy, with: scheduler, now: at)
        rows.append(Self.sheetRow(cardId: card.id, rating: Grade.easy.rawValue, at: at))
        try context.save()
        let live = card.snapshot
        XCTAssertEqual(live.scheduledDays, 2, "the adjusted figure is what `_log` carries")

        let replayed = LogReplay.replay(LogReplay.parse(Self.sheet(rows)).rows, scheduler: scheduler)

        XCTAssertEqual(replayed[card.id], live)
    }

    /// Acceptance: "after wiping the local DB, rebuilding from `_log` reproduces
    /// every card's due date, stability, difficulty, reps and lapses".
    func testRebuildFromNothingReproducesEveryField() async throws {
        let card = try makeCard(seed: 1)
        let scheduler = Scheduler()
        var rows: [[String]] = []
        for (step, grade) in ([.good, .again, .good, .good] as [Grade]).enumerated() {
            let at = Self.start.addingTimeInterval(Double(step + 1) * 86_400)
            try context.rate(card, grade, with: scheduler, now: at)
            rows.append(Self.sheetRow(cardId: card.id, rating: grade.rawValue, at: at))
        }
        try context.save()
        let expected = card.snapshot

        // The wipe: scheduling back to a brand new card, log untouched.
        card.restore(from: CardSchedulingSnapshot())
        try context.save()
        XCTAssertNotEqual(card.snapshot, expected)

        let report = try await RebuildScheduling.apply(
            LogReplay.parse(Self.sheet(rows)), in: context,
            config: SchedulerConfig(), backupDirectory: directory, now: Self.start
        )

        XCTAssertEqual(report.cardsRebuilt, 1)
        XCTAssertEqual(card.snapshot, expected)
        XCTAssertEqual(card.due, expected.due)
        XCTAssertEqual(card.stability, expected.stability)
        XCTAssertEqual(card.difficulty, expected.difficulty)
        XCTAssertEqual(card.reps, expected.reps)
        XCTAssertEqual(card.lapses, expected.lapses)
    }

    /// Acceptance: "replay is deterministic — running it twice gives the same
    /// result". This is only true because fuzz is off on the pinned revision.
    func testReplayingTwiceGivesTheSameResult() throws {
        let card = try makeCard(seed: 1)
        let rows = (1...8).map { step in
            Self.sheetRow(cardId: card.id, rating: (step % 4) + 1,
                          at: Self.start.addingTimeInterval(Double(step) * 86_400))
        }
        let parse = LogReplay.parse(Self.sheet(rows))

        let first = LogReplay.replay(parse.rows, scheduler: Scheduler())
        let second = LogReplay.replay(parse.rows, scheduler: Scheduler())

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first[card.id]?.encoded(), try second[card.id]?.encoded())
    }

    /// Two reviews inside the same second are a real possibility, and sorting on
    /// the timestamp alone would leave their order to whatever the sort felt
    /// like. `again` then `easy` is not the same card as `easy` then `again`.
    func testRowsSharingASecondKeepTheirSheetOrder() throws {
        let card = try makeCard(seed: 1)
        let at = Self.start
        let forwards = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: Grade.again.rawValue, at: at),
            Self.sheetRow(cardId: card.id, rating: Grade.easy.rawValue, at: at),
        ])
        let backwards = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: Grade.easy.rawValue, at: at),
            Self.sheetRow(cardId: card.id, rating: Grade.again.rawValue, at: at),
        ])

        let a = LogReplay.replay(LogReplay.parse(forwards).rows, scheduler: Scheduler())
        let b = LogReplay.replay(LogReplay.parse(backwards).rows, scheduler: Scheduler())

        XCTAssertNotEqual(a[card.id], b[card.id], "sheet order must decide ties")
    }

    /// Rows arriving out of order — a chunked push interrupted and resumed — must
    /// still replay chronologically.
    func testRowsAreReplayedInTimeOrderNotSheetOrder() throws {
        let card = try makeCard(seed: 1)
        let early = Self.start.addingTimeInterval(86_400)
        let late = Self.start.addingTimeInterval(5 * 86_400)

        let ordered = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: early),
            Self.sheetRow(cardId: card.id, rating: 4, at: late),
        ])
        let shuffled = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 4, at: late),
            Self.sheetRow(cardId: card.id, rating: 3, at: early),
        ])

        XCTAssertEqual(LogReplay.replay(LogReplay.parse(ordered).rows, scheduler: Scheduler()),
                       LogReplay.replay(LogReplay.parse(shuffled).rows, scheduler: Scheduler()))
    }

    // MARK: - Undo markers

    /// Acceptance: "undo rows (`rating=0`) do not count as reviews".
    ///
    /// A marker is written only when the review it takes back had already
    /// reached the Sheet (§5.5), so that review's row is still there. The replay
    /// has to cancel it, not merely step over the marker — the earlier form of
    /// this test compared against a log that *kept* the undone Good, and so
    /// pinned the wrong answer.
    func testAnUndoMarkerCancelsTheReviewItTookBack() throws {
        let card = try makeCard(seed: 1)
        let withUndo = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start),
            Self.sheetRow(cardId: card.id, rating: 0, at: Self.start.addingTimeInterval(60)),
            Self.sheetRow(cardId: card.id, rating: 4, at: Self.start.addingTimeInterval(86_400)),
        ])
        let asItReallyHappened = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 4, at: Self.start.addingTimeInterval(86_400)),
        ])

        let parse = LogReplay.parse(withUndo)
        XCTAssertEqual(parse.undoMarkers, 1)
        XCTAssertEqual(parse.reviewCount, 2)
        XCTAssertEqual(parse.rows.first?.grade, .good)

        let replayed = LogReplay.replay(parse.rows, scheduler: Scheduler())
        XCTAssertEqual(replayed,
                       LogReplay.replay(LogReplay.parse(asItReallyHappened).rows, scheduler: Scheduler()))
        XCTAssertEqual(replayed[card.id]?.reps, 1, "the undone Good must not count")
    }

    /// The same, measured against the live path rather than a second replay:
    /// rate, push, undo, rate again — the two must agree to the byte.
    func testReplayMatchesTheLivePathThroughAnUploadedUndo() throws {
        let card = try makeCard(seed: 2)
        let scheduler = Scheduler()
        let deck = try deck()
        let plan = QueuePlan(cardIds: [card.id], dueReviewCount: 1, newCardCount: 0,
                             secondsPerCard: 20, studyDay: Self.start)
        let session = StudySession(context: context, scheduler: scheduler, plan: plan, decks: [deck])

        session.reveal(now: Self.start)
        session.rate(.good, now: Self.start)
        let uploaded = try XCTUnwrap(session.undoableLog)
        uploaded.uploaded = true                       // it reached the Sheet
        XCTAssertTrue(session.undo(now: Self.start.addingTimeInterval(60)))
        session.reveal(now: Self.start.addingTimeInterval(120))
        session.rate(.hard, now: Self.start.addingTimeInterval(120))
        try context.save()
        let live = card.snapshot

        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
            .sorted { $0.reviewedAt < $1.reviewedAt }
        XCTAssertEqual(logs.map(\.rating), [3, 0, 2])
        let sheet = Self.sheet(logs.map {
            Self.sheetRow(cardId: $0.cardId, rating: $0.rating, at: $0.reviewedAt)
        })
        let replayed = LogReplay.replay(LogReplay.parse(sheet).rows, scheduler: scheduler)
        XCTAssertEqual(replayed[card.id], live)
    }

    /// Undone and never rated again: the card has no review standing, so it is
    /// reset to new exactly like a card the log never mentions.
    func testACardWhoseOnlyReviewWasUndoneIsReset() throws {
        let card = try makeCard(seed: 3)
        let parse = LogReplay.parse(Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start),
            Self.sheetRow(cardId: card.id, rating: 0, at: Self.start.addingTimeInterval(60)),
        ]))
        XCTAssertNil(LogReplay.replay(parse.rows, scheduler: Scheduler())[card.id])
    }

    /// A marker with nothing to cancel — its review's row was lost — is inert.
    func testAStrayUndoMarkerChangesNothing() throws {
        let card = try makeCard(seed: 4)
        let stray = LogReplay.parse(Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 0, at: Self.start),
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start.addingTimeInterval(60)),
        ]))
        let clean = LogReplay.parse(Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start.addingTimeInterval(60)),
        ]))
        XCTAssertEqual(LogReplay.replay(stray.rows, scheduler: Scheduler()),
                       LogReplay.replay(clean.rows, scheduler: Scheduler()))
    }

    // MARK: - Parsing

    func testAReorderedSheetIsReadByItsHeader() throws {
        let card = try makeCard(seed: 1)
        let values = [
            ["reviewed_at", "rating", "card_id"],
            [SheetPush.timestamp.string(from: Self.start), "3", card.id],
        ]
        let parse = LogReplay.parse(values)

        XCTAssertEqual(parse.rows.count, 1)
        XCTAssertEqual(parse.rows.first?.cardId, card.id)
        XCTAssertEqual(parse.rows.first?.grade, .good)
    }

    /// A sheet with its header row deleted still replays, positionally.
    func testAHeaderlessSheetFallsBackToColumnOrder() throws {
        let card = try makeCard(seed: 1)
        let parse = LogReplay.parse([Self.sheetRow(cardId: card.id, rating: 3, at: Self.start)])

        XCTAssertEqual(parse.rows.count, 1)
        XCTAssertEqual(parse.rows.first?.grade, .good)
    }

    func testBadRowsAreCountedNotDropped() throws {
        let card = try makeCard(seed: 1)
        let values = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start),
            ["", "forward", "3", SheetPush.timestamp.string(from: Self.start), "", "", ""],
            [card.id, "forward", "не число", SheetPush.timestamp.string(from: Self.start), "", "", ""],
            [card.id, "forward", "9", SheetPush.timestamp.string(from: Self.start), "", "", ""],
            [card.id, "forward", "3", "вчора", "", "", ""],
        ])

        let parse = LogReplay.parse(values)

        XCTAssertEqual(parse.reviewCount, 1)
        XCTAssertEqual(parse.malformed, 4)
    }

    func testBlankRowsAreNotMalformed() throws {
        let card = try makeCard(seed: 1)
        let values = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start),
            ["", "", "", "", "", "", ""],
            [],
        ])
        let parse = LogReplay.parse(values)

        XCTAssertEqual(parse.reviewCount, 1)
        XCTAssertEqual(parse.malformed, 0)
    }

    func testAnEmptySheetParsesToNothing() {
        XCTAssertEqual(LogReplay.parse([]), LogReplay.Parse())
        XCTAssertEqual(LogReplay.parse([LogPush.header]).reviewCount, 0)
    }

    // MARK: - Applying over a store

    func testACardWithNoLogRowsReturnsToNew() async throws {
        let logged = try makeCard(seed: 1)
        let untouched = try makeCard(seed: 2)
        untouched.state = .review
        untouched.reps = 7
        untouched.stability = 30
        let keptDue = untouched.due
        try context.save()

        let rows = Self.sheet([Self.sheetRow(cardId: logged.id, rating: 3, at: Self.start)])
        let report = try await RebuildScheduling.apply(
            LogReplay.parse(rows), in: context, config: SchedulerConfig(),
            backupDirectory: directory, now: Self.start
        )

        XCTAssertEqual(report.cardsRebuilt, 1)
        XCTAssertEqual(report.cardsReset, 1)
        XCTAssertEqual(untouched.state, .new)
        XCTAssertEqual(untouched.reps, 0)
        XCTAssertEqual(untouched.stability, 0)
        XCTAssertNil(untouched.lastReview)
        // Kept, not reset to `now` — otherwise two rebuilds would disagree.
        XCTAssertEqual(untouched.due, keptDue)
    }

    /// Running the whole thing twice must land in the same place, models and all.
    func testRebuildingTwiceLeavesTheSameStore() async throws {
        let card = try makeCard(seed: 1)
        let rows = Self.sheet((1...5).map { step in
            Self.sheetRow(cardId: card.id, rating: (step % 4) + 1,
                          at: Self.start.addingTimeInterval(Double(step) * 86_400))
        })
        let parse = LogReplay.parse(rows)

        try await RebuildScheduling.apply(parse, in: context, config: SchedulerConfig(),
                                          backupDirectory: directory, now: Self.start)
        let first = card.snapshot
        try await RebuildScheduling.apply(parse, in: context, config: SchedulerConfig(),
                                          backupDirectory: directory, now: Self.start)

        XCTAssertEqual(card.snapshot, first)
    }

    func testLogRowsForUnknownCardsAreReportedNotDropped() async throws {
        let card = try makeCard(seed: 1)
        try context.save()
        let rows = Self.sheet([
            Self.sheetRow(cardId: card.id, rating: 3, at: Self.start),
            Self.sheetRow(cardId: "00000000-0000-0000-0000-000000000099#fwd", rating: 3, at: Self.start),
        ])

        let report = try await RebuildScheduling.apply(
            LogReplay.parse(rows), in: context, config: SchedulerConfig(),
            backupDirectory: directory, now: Self.start
        )

        XCTAssertEqual(report.cardsRebuilt, 1)
        XCTAssertEqual(report.unknownCards, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 1)
    }

    /// Suspension is a local decision (§5.4) and is not in `_log`. A rebuild that
    /// quietly unsuspended every leech would undo work the owner did on purpose.
    func testSuspensionSurvivesARebuild() async throws {
        let card = try makeCard(seed: 1)
        card.isSuspended = true
        try context.save()

        try await RebuildScheduling.apply(
            LogReplay.parse(Self.sheet([Self.sheetRow(cardId: card.id, rating: 3, at: Self.start)])),
            in: context, config: SchedulerConfig(), backupDirectory: directory, now: Self.start
        )

        XCTAssertTrue(card.isSuspended)
    }

    /// A rebuild is destructive by design; the snapshot is what makes it
    /// reversible, so it must exist before anything is written.
    func testASnapshotIsTakenBeforeAnythingIsReplaced() async throws {
        let card = try makeCard(seed: 1)
        card.state = .review
        card.reps = 5
        card.due = Self.start.addingTimeInterval(99_999)
        try context.save()
        let before = card.snapshot

        let report = try await RebuildScheduling.apply(
            LogReplay.parse([]), in: context, config: SchedulerConfig(),
            backupDirectory: directory, now: Self.start
        )

        let url = try XCTUnwrap(report.backup)
        let saved = try BackupStore.read(url)
        XCTAssertEqual(saved.entries.first?.scheduling, before,
                       "the snapshot must hold the state from before the rebuild")
        // And the rebuild really did replace it.
        XCTAssertEqual(card.state, .new)
    }

    /// The backup is "the only thing that makes it reversible", so a backup that
    /// cannot be written must stop the rebuild before anything is replaced —
    /// not be swallowed by `try?` on the way to replacing every card's schedule.
    func testARebuildWhoseBackupFailsTouchesNothing() async throws {
        let card = try makeCard(seed: 1)
        card.state = .review
        card.reps = 5
        try context.save()
        let before = card.snapshot

        // A *file* where the backup directory should be: nothing can be written under it.
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)

        do {
            _ = try await RebuildScheduling.apply(
                LogReplay.parse([]), in: context, config: SchedulerConfig(),
                backupDirectory: blocked, now: Self.start)
            XCTFail("a rebuild without a backup must not run")
        } catch {
            XCTAssertEqual(card.snapshot, before, "nothing was replaced")
        }
    }

    /// An empty `_log` resets everything. That is correct — and exactly why the
    /// dialog has to say so rather than quoting a count of zero.
    func testAnEmptyLogIsCalledOutInTheConfirmation() {
        let empty = LogReplay.Parse()
        XCTAssertTrue(BackupSettingsView.confirmation(for: empty).contains("немає жодного повторення"))

        var some = LogReplay.Parse()
        some.rows = [.init(cardId: "a", grade: .good, reviewedAt: Self.start)]
        some.malformed = 2
        let text = BackupSettingsView.confirmation(for: some)
        XCTAssertTrue(text.contains("1"), text)
        XCTAssertTrue(text.contains("2"), text)
    }

    // MARK: - Cost

    /// Acceptance: "a 5k-row `_log` rebuilds without blocking the UI". The
    /// blocking part is structural — the replay runs off the main actor — so what
    /// is measurable here is that the work itself is not pathological.
    func testFiveThousandRowsReplayQuickly() throws {
        var rows: [LogReplay.Row] = []
        for card in 0..<250 {
            for step in 0..<20 {
                rows.append(.init(cardId: "card-\(card)",
                                  grade: Grade(rawValue: (step % 4) + 1)!,
                                  reviewedAt: Self.start.addingTimeInterval(Double(step) * 86_400)))
            }
        }
        XCTAssertEqual(rows.count, 5_000)

        let started = Date()
        let result = LogReplay.replay(rows, scheduler: Scheduler())
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.count, 250)
        XCTAssertLessThan(elapsed, 2.0, "5k-row replay took \(elapsed)s")
    }
}
