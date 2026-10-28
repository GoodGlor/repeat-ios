import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #36 — §8's first recovery path. The phone holds the only copy of scheduling
/// state, so the claims worth testing are the exactness of a restore and its
/// safety when the Sheet has moved on underneath it.
final class BackupTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

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
        suiteName = "BackupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - #112: the one thing a rebuild could not put back

    private var frozenDay: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testABackupCarriesFrozenDaysAndARestorePutsThemBack() throws {
        context.insert(StreakFreeze(day: frozenDay, spentAt: .now))
        try context.save()

        let backup = try BackupRunner.makeBackup(in: context, now: .now)
        XCTAssertEqual(backup.version, 2)
        XCTAssertEqual(backup.frozenDays, [frozenDay])

        // Lose it, the way wiping the store would.
        try context.delete(model: StreakFreeze.self)
        try context.save()
        XCTAssertTrue(Freeze.rows(in: context).isEmpty)

        _ = try BackupRunner.restore(backup, in: context)
        XCTAssertEqual(Freeze.days(in: context), [frozenDay],
                       "a rebuild from `_log` cannot recover a freeze, so the backup must")
    }

    /// The same choice `RestoreReport.untouched` already makes for cards added
    /// since: a restore rewinds what it has a record of and destroys nothing it
    /// does not.
    func testARestoreLeavesAFreezeSpentSinceTheBackupAlone() throws {
        context.insert(StreakFreeze(day: frozenDay, spentAt: .now))
        try context.save()
        let backup = try BackupRunner.makeBackup(in: context, now: .now)

        let later = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 3, to: frozenDay))
        context.insert(StreakFreeze(day: later, spentAt: .now))
        try context.save()

        _ = try BackupRunner.restore(backup, in: context)
        XCTAssertEqual(Freeze.days(in: context), [frozenDay, later])
    }

    /// Every backup already on the owner's phone was written before freezes
    /// existed. `decoded` guards `version <= currentVersion`, and `frozenDays` is
    /// defaulted, so an old file opens and simply has none — a backup that would
    /// not open is no backup at all.
    func testABackupWrittenBeforeFreezesExistedStillOpens() throws {
        let json = Data(#"{"version":1,"createdAt":0,"entries":[]}"#.utf8)
        let backup = try SchedulingBackup.decoded(from: json)
        XCTAssertEqual(backup.version, 1)
        XCTAssertTrue(backup.frozenDays.isEmpty)
    }

    // MARK: - Fixtures

    /// `Card.id` is derived from the note's UUID, so a fixture cannot choose it
    /// directly. Seeding the UUID keeps the ids stable and sortable across a run.
    @discardableResult
    private func makeCard(seed: Int, due: Date, stability: Double = 12.5,
                          reps: Int = 4, lapses: Int = 1) throws -> Card {
        let note = Note(id: Self.uuid(seed), deck: try deck(),
                        front: "front-\(seed)", back: "back-\(seed)")
        context.insert(note)
        let card = Card(note: note, direction: .forward)
        card.state = .review
        card.due = due
        card.stability = stability
        card.difficulty = 6.25
        card.elapsedDays = 3
        card.scheduledDays = 13
        card.reps = reps
        card.lapses = lapses
        card.lastReview = due.addingTimeInterval(-13 * 86_400)
        card.learningStepIndex = 0
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

    // MARK: - Exactness

    /// The acceptance line: "restoring a backup reproduces every card's due date
    /// exactly". Sub-second precision is the part that breaks silently — an
    /// `.iso8601` date strategy anywhere in the chain would round `due` and every
    /// assertion here would still read as "about right".
    func testRestoreReproducesDueDatesExactly() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let card = try makeCard(seed: 1, due: due)
        try context.save()

        let backup = try BackupRunner.makeBackup(in: context, now: .now)

        card.due = due.addingTimeInterval(99_999)
        card.stability = 0.1
        card.reps = 0
        try context.save()

        let report = try BackupRunner.restore(backup, in: context)

        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(card.due, due)
        XCTAssertEqual(card.due.timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 0)
        XCTAssertEqual(card.stability, 12.5)
        XCTAssertEqual(card.reps, 4)
    }

    /// The same, but through the file — the encode/decode round trip is where a
    /// date strategy would actually be introduced.
    func testDueDateSurvivesTheFileRoundTrip() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000.123456)
        try makeCard(seed: 1, due: due)
        try context.save()

        let url = try BackupRunner.run(in: context, directory: directory, defaults: defaults)
        let reread = try BackupStore.read(url)

        XCTAssertEqual(reread.entries.first?.scheduling.due, due)
    }

    func testEverySchedulingFieldRoundTrips() throws {
        let card = try makeCard(seed: 1, due: Date(timeIntervalSince1970: 1_700_000_000))
        card.isSuspended = true
        card.learningStepIndex = 1
        card.state = .relearning
        try context.save()
        let expected = card.snapshot

        let url = try BackupRunner.run(in: context, directory: directory, defaults: defaults)
        card.restore(from: CardSchedulingSnapshot())
        try BackupRunner.restore(try BackupStore.read(url), in: context)

        XCTAssertEqual(card.snapshot, expected)
    }

    /// Two backups of an unchanged store must be byte identical, or "nothing
    /// changed" is unanswerable by comparison.
    func testEncodingIsDeterministic() throws {
        try makeCard(seed: 4, due: .now)
        try makeCard(seed: 1, due: .now)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try BackupRunner.makeBackup(in: context, now: now)
        let second = try BackupRunner.makeBackup(in: context, now: now)

        XCTAssertEqual(try first.encoded(), try second.encoded())
        XCTAssertEqual(first.entries.map(\.id), first.entries.map(\.id).sorted(),
                       "entries must be sorted by id")
        XCTAssertEqual(first.entries.count, 2)
    }

    // MARK: - Safety when the Sheet has moved on

    func testACardDeletedSinceTheBackupIsSkippedNotResurrected() throws {
        try makeCard(seed: 1, due: .now)
        let doomed = try makeCard(seed: 2, due: .now)
        try context.save()
        let backup = try BackupRunner.makeBackup(in: context)

        context.delete(doomed)
        try context.save()

        let report = try BackupRunner.restore(backup, in: context)

        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 1)
    }

    /// A card pulled from the Sheet after the backup was taken has scheduling of
    /// its own. Restoring must not reset it — it was never in the snapshot.
    func testACardAddedSinceTheBackupIsLeftAlone() throws {
        try makeCard(seed: 1, due: .now)
        try context.save()
        let backup = try BackupRunner.makeBackup(in: context)

        let newer = try makeCard(seed: 3, due: Date(timeIntervalSince1970: 2_000_000_000))
        newer.reps = 9
        try context.save()

        let report = try BackupRunner.restore(backup, in: context)

        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.untouched, 1)
        XCTAssertEqual(newer.reps, 9)
        XCTAssertEqual(newer.due, Date(timeIntervalSince1970: 2_000_000_000))
    }

    /// Ids are stable across a pull, so an edited card still matches. And a
    /// restore must not touch note content — otherwise it would silently undo an
    /// edit that came from the Sheet.
    func testAnEditedCardStillMatchesAndItsTextIsUntouched() throws {
        let card = try makeCard(seed: 1, due: Date(timeIntervalSince1970: 1_700_000_000))
        try context.save()
        let backup = try BackupRunner.makeBackup(in: context)

        card.note.front = "змінено в Таблиці"
        card.due = Date(timeIntervalSince1970: 1_900_000_000)
        try context.save()

        try BackupRunner.restore(backup, in: context)

        XCTAssertEqual(card.due, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(card.note.front, "змінено в Таблиці")
    }

    // MARK: - Retention

    func testOnlyTheNewestSevenAreKept() throws {
        try makeCard(seed: 1, due: .now)
        try context.save()
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for day in 0..<10 {
            let now = calendar.date(byAdding: .day, value: day, to: start)!
            try BackupRunner.run(in: context, directory: directory,
                                 defaults: defaults, now: now, calendar: calendar)
        }

        let remaining = BackupStore.list(in: directory, calendar: calendar)
        XCTAssertEqual(remaining.count, BackupStore.keepCount)
        // Newest first, and it is day 9 that survived rather than day 0.
        let newest = BackupStore.date(fromFilename: remaining[0].lastPathComponent, calendar: calendar)
        XCTAssertEqual(newest, calendar.startOfDay(for: calendar.date(byAdding: .day, value: 9, to: start)!))
    }

    /// A second backup on the same day overwrites rather than eating a slot —
    /// otherwise a heavy day of manual backups would erase the whole week.
    func testASecondBackupOnTheSameDayDoesNotConsumeASlot() throws {
        try makeCard(seed: 1, due: .now)
        try context.save()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try BackupRunner.run(in: context, directory: directory, defaults: defaults, now: now)
        try BackupRunner.run(in: context, directory: directory, defaults: defaults,
                             now: now.addingTimeInterval(3600))

        XCTAssertEqual(BackupStore.list(in: directory).count, 1)
    }

    // MARK: - Scheduling the run

    func testRunIfNeededRunsOncePerDay() throws {
        try makeCard(seed: 1, due: .now)
        try context.save()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNotNil(try BackupRunner.runIfNeeded(in: context, directory: directory,
                                                    defaults: defaults, now: now, calendar: calendar))
        XCTAssertNil(try BackupRunner.runIfNeeded(in: context, directory: directory,
                                                 defaults: defaults,
                                                 now: now.addingTimeInterval(3600),
                                                 calendar: calendar))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertNotNil(try BackupRunner.runIfNeeded(in: context, directory: directory,
                                                    defaults: defaults, now: tomorrow,
                                                    calendar: calendar))
    }

    // MARK: - D4's precondition

    /// The snapshot is only off-device because iOS puts Documents in the device
    /// backup. Excluding it would quietly turn D4's "two independent recovery
    /// paths" back into one.
    func testBackupsAreNotExcludedFromDeviceBackup() throws {
        try makeCard(seed: 1, due: .now)
        try context.save()

        let url = try BackupRunner.run(in: context, directory: directory, defaults: defaults)

        XCTAssertTrue(BackupStore.isIncludedInDeviceBackup(url))
    }

    func testTheRealDirectoryIsDocuments() {
        XCTAssertEqual(BackupStore.directory.lastPathComponent, "Documents")
    }

    // MARK: - Format

    func testFilenamesRoundTripThroughTheirDate() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        let name = BackupStore.filename(for: date, calendar: calendar)

        XCTAssertEqual(name, "_backup-2026-09-02.json")
        XCTAssertEqual(BackupStore.date(fromFilename: name, calendar: calendar), date)
    }

    /// The app's copy is hardcoded Ukrainian while `.formatted()` follows the
    /// device, so this row read "2 September 2026" under a Ukrainian header until
    /// the locale was pinned. Only a screenshot showed it; this keeps it shown.
    func testTheBackupDateIsRenderedInUkrainian() {
        let url = URL(fileURLWithPath: "/tmp/_backup-2026-09-02.json")
        let title = BackupSettingsView.title(for: url, locale: Locale(identifier: "uk"))

        // Not an equality check: Foundation separates the year from "р." with a
        // non-breaking space, so a literal comparison fails on characters that
        // are invisible in both the failure message and the screenshot.
        XCTAssertTrue(title.contains("вересня"), title)
        XCTAssertTrue(title.contains("2026"), title)
        XCTAssertFalse(title.contains("September"), title)
    }

    func testAnUnparseableNameFallsBackToTheFilename() {
        let url = URL(fileURLWithPath: "/tmp/whatever.json")
        XCTAssertEqual(BackupSettingsView.title(for: url, locale: Locale(identifier: "uk")), "whatever.json")
    }

    func testUnrelatedFilesAreIgnored() throws {
        for name in ["notes.json", "_backup-nope.json", "_backup-2026-09-02.txt", ".DS_Store"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        XCTAssertTrue(BackupStore.list(in: directory).isEmpty)
    }

    func testAFutureFormatIsRefusedRatherThanPartlyApplied() throws {
        var backup = SchedulingBackup(createdAt: .now, entries: [])
        backup.version = SchedulingBackup.currentVersion + 1
        let url = directory.appendingPathComponent("_backup-2030-01-01.json")
        try backup.encoded().write(to: url)

        XCTAssertThrowsError(try BackupStore.read(url))
    }

    // MARK: - Cost

    /// Backing up must not cross `card.note`: that relationship costs ~1.2 s for
    /// 10k cards, and nothing in a snapshot needs it.
    func testTenThousandCardsBackUpWithinBudget() throws {
        let deck = try deck()
        for index in 0..<10_000 {
            let note = Note(id: Self.uuid(index), deck: deck, front: "f", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            card.state = .review
            card.lastReview = .now
            context.insert(card)
        }
        try context.save()

        let started = Date()
        let backup = try BackupRunner.makeBackup(in: context)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(backup.cardCount, 10_000)
        XCTAssertLessThan(elapsed, 1.0, "backup took \(elapsed)s — is it faulting card.note?")
    }
}
