import XCTest
import SwiftData
import UserNotifications
import Scheduling
@testable import Repeat

/// #109 — one notification for a badge nobody was looking at, never while they are.
@MainActor
final class AchievementNotificationTests: XCTestCase {
    private var context: ModelContext!
    private var ledger: AchievementLedger!
    private var scheduler: FakeScheduler!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private static let noon = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
    private let uk = Locale(identifier: "uk_UA")

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = ModelContext(try ModelStore.container(inMemory: true))
        ledger = AchievementLedger(defaults: UserDefaults(suiteName: "achievements.\(UUID().uuidString)")!)
        scheduler = FakeScheduler()
        // Process-wide, like the Done screen it mirrors: a test that leaves
        // badges registered would silence every test after it.
        OnScreenBadges.clear()
    }

    override func tearDown() {
        OnScreenBadges.clear()
        super.tearDown()
    }

    /// One reviewed card, so `firstSession` is unlocked and nothing else is.
    private func seedOneReview() throws {
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1)
        context.insert(deck)
        let note = Note(deck: deck, front: "harbour", back: "—", reverse: false, sheetRow: 0)
        context.insert(note)
        let cards = context.syncCards(for: note, now: Self.noon)
        try context.rate(cards[0], .good, with: Scheduler(), now: Self.noon.addingTimeInterval(-3_600))
        try context.save()
    }

    // MARK: - Copy

    func testEveryBadgeHasANotificationTitleAndTheStreaksNameTheirUnit() {
        for badge in Achievements.Badge.allCases {
            XCTAssertFalse(badge.notificationTitle().isEmpty, badge.rawValue)
        }
        XCTAssertEqual(Achievements.Badge.streak30.notificationTitle(locale: uk), "Серія 30 днів")
        XCTAssertEqual(Achievements.Badge.reviews100.notificationTitle(locale: uk), "100 повторень")
    }

    func testTheBodyNamesTheFirstBadgeAndCountsTheRest() {
        XCTAssertEqual(AchievementNotification.body(for: [.streak7], locale: uk), "Серія 7 днів")
        XCTAssertEqual(AchievementNotification.body(for: [.streak7, .earlyBird, .nightOwl], locale: uk),
                       "Серія 7 днів та ще 2")
        XCTAssertEqual(AchievementNotification.body(for: [], locale: uk), "")
    }

    // MARK: - Posting

    func testAnUnlockWhileInactivePostsOnceWithTheBadgesTitle() async throws {
        let posted = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)

        XCTAssertEqual(posted, [.streak30])
        let pending = await scheduler.pendingRequests()
        XCTAssertEqual(pending.count, 1)
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.identifier, AchievementNotification.identifier)
        XCTAssertEqual(request.content.title, "Досягнення")
        XCTAssertEqual(request.content.body, "Серія 30 днів")
        XCTAssertEqual(request.content.userInfo[NotificationRouter.userInfoKey] as? String, DeepLink.stats)
        XCTAssertNil(request.trigger, "delivered now: it is already true")
        XCTAssertEqual(ledger.shownOn["streak-30"], Self.noon, "shown by the notification, on that date")
    }

    func testAnUnlockWhileActivePostsNothingAndWritesNothing() async {
        let posted = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: true, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)
        XCTAssertEqual(posted, [])
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty, "the Done screen is the celebration while the app is up")
        XCTAssertTrue(ledger.shown.isEmpty)
    }

    func testTheSameUnlockTwicePostsOnce() async throws {
        try seedOneReview()
        let first = await AchievementNotification.refresh(
            in: context, sceneIsActive: false, enabled: true, ledger: ledger,
            now: Self.noon, calendar: Self.calendar, using: scheduler)
        let second = await AchievementNotification.refresh(
            in: context, sceneIsActive: false, enabled: true, ledger: ledger,
            now: Self.noon.addingTimeInterval(86_400), calendar: Self.calendar, using: scheduler)

        XCTAssertEqual(first, [.firstSession])
        XCTAssertEqual(second, [], "the ledger remembers; evaluation finds nothing fresh")
        let pending = await scheduler.pendingRequests()
        XCTAssertEqual(pending.count, 1)
        // `pending.count` alone cannot tell "posted once" from "posted twice,
        // the second replacing the first by identifier" — replacement is
        // exactly what a real second post would do. `addCount` is the one
        // delivery attempt this test's name actually promises.
        XCTAssertEqual(scheduler.addCount, 1, "one delivery attempt, not a second that merely replaced the first")
    }

    func testNotificationsOffPostsNothingAndLeavesTheBadgeFresh() async throws {
        try seedOneReview()
        let posted = await AchievementNotification.refresh(
            in: context, sceneIsActive: false, enabled: false, ledger: ledger,
            now: Self.noon, calendar: Self.calendar, using: scheduler)
        XCTAssertEqual(posted, [])
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(ledger.shown.isEmpty, "still fresh for the next Done screen")
    }

    func testARefusedRequestLeavesTheLedgerAlone() async {
        scheduler.addError = URLError(.cancelled)
        let posted = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)
        XCTAssertEqual(posted, [])
        XCTAssertTrue(ledger.shown.isEmpty, "nothing was shown, so nothing is written")
    }

    // MARK: - A badge the Done screen is holding open

    /// The suspended-process case: the Done screen is up (behind a lock, so the
    /// scene is not active) and has not written the ledger yet, because
    /// shake-to-undo is still reachable there. The background refresh must not
    /// celebrate — or spend — a badge its owner is looking at.
    func testABadgeTheDoneScreenIsShowingIsNeitherAnnouncedNorWritten() async {
        OnScreenBadges.show([.streak30])

        let posted = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)

        XCTAssertEqual(posted, [], "the Done screen is already celebrating it")
        let pending = await scheduler.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(scheduler.addCount, 0, "nothing was even offered to the centre")
        XCTAssertTrue(ledger.shown.isEmpty, "undo is still live: the badge stays fresh")
    }

    /// The same call announces once the screen has gone — which is also the
    /// state a relaunched process starts in, since the set is in-memory.
    func testTheSameBadgeIsAnnouncedOnceTheDoneScreenHasGone() async throws {
        OnScreenBadges.show([.streak30])
        _ = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)

        OnScreenBadges.clear()
        let posted = await AchievementNotification.post(
            fresh: [.streak30], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)

        XCTAssertEqual(posted, [.streak30])
        XCTAssertEqual(scheduler.addCount, 1)
        let pending = await scheduler.pendingRequests()
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.content.body, Achievements.Badge.streak30.notificationTitle())
        XCTAssertEqual(ledger.shownOn["streak-30"], Self.noon)
    }

    /// A badge on screen and one that is not: only the second is announced, and
    /// only the second is spent. The copy must not name the suppressed one.
    func testOnlyTheFreshBadgesNoScreenIsShowingAreAnnounced() async throws {
        OnScreenBadges.show([.streak30])

        let posted = await AchievementNotification.post(
            fresh: [.streak30, .earlyBird], sceneIsActive: false, enabled: true,
            ledger: ledger, now: Self.noon, using: scheduler)

        XCTAssertEqual(posted, [.earlyBird])
        let pending = await scheduler.pendingRequests()
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.content.body, Achievements.Badge.earlyBird.notificationTitle(),
                       "one badge, so no 'та ще' count — and not the one on screen")
        XCTAssertEqual(ledger.shownOn["early-bird"], Self.noon)
        XCTAssertNil(ledger.shownOn["streak-30"], "still on screen, still undoable, still fresh")
    }

    func testTheFactsArePureFetchesAndCounts() async throws {
        try seedOneReview()
        let since = Date()
        _ = await AchievementNotification.refresh(
            in: context, sceneIsActive: false, enabled: true, ledger: ledger,
            now: Self.noon, calendar: Self.calendar, using: scheduler)
        XCTAssertEqual(try OffQueue.uses(since: since), [])
    }
}
