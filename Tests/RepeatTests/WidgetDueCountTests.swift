import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #26 — the widget's number, and the link that starts a session.
final class WidgetDueCountTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("due-\(UUID().uuidString).json")
        addTeardownBlock { [file] in try? FileManager.default.removeItem(at: file!) }
    }

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    private func addCards(_ context: ModelContext, to deck: Deck, count: Int, due: Date) {
        for index in 0..<count {
            let note = Note(deck: deck, front: "f\(index)", back: "b")
            context.insert(note)
            let card = Card(note: note, direction: .forward)
            // A reviewed card carries the evidence of its review. Setting `state`
            // without `lastReview` and `reps` describes a card the app cannot
            // produce — `rate()` writes all three from one snapshot — and #84's
            // queue reads `lastReview` as the queryable stand-in for "not new".
            // `QueueBuilderTests` has always built its fixtures this way.
            card.state = .review
            card.due = due
            card.reps = 3
            card.lastReview = due.addingTimeInterval(-86_400)
            context.insert(card)
        }
    }

    /// A defaults suite of its own. `DailyGoalCache` is `UserDefaults.standard`
    /// by default, and a target another test in this process happened to cache
    /// would silently change what these publish.
    private func emptyGoalCache() throws -> DailyGoalCache {
        let name = "widget-goal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return DailyGoalCache(defaults: defaults)
    }

    // MARK: - Acceptance: the widget count matches Home

    /// Home shows the *capped* plan, not a raw count of overdue cards. A widget
    /// promising 300 when the button delivers 30 would be lying.
    func testThePublishedCountIsHomesCappedPlanNotTheRawBacklog() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 120, due: now.addingTimeInterval(-3600))
        try context.save()

        var config = QueueConfig()
        config.globalNewCardCap = 5
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: [deck], now: now, config: config, using: &generator)

        try DueCount(due: plan.count, day: Calendar.current.startOfDay(for: now),
                     generatedAt: now).write(to: file)

        let read = try XCTUnwrap(DueCount.read(from: file))
        XCTAssertEqual(read.due, plan.count)
        XCTAssertEqual(read.due, 120, "these are all reviews, not new cards, so none are capped away")
    }

    func testPublishingFromTheStoreAgreesWithTheQueueBuilder() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 7, due: now.addingTimeInterval(-60))
        try context.save()

        var generator = SystemRandomNumberGenerator()
        let expected = QueueBuilder.plan(
            decks: try context.fetch(FetchDescriptor<Deck>()), now: now, using: &generator
        ).count

        DueCountPublisher.publish(from: context, now: now, reloadWidgets: false)

        // Written to the real App Group path; skipped where the entitlement is
        // unavailable rather than failing for the wrong reason.
        try XCTSkipIf(AppGroup.dueCountURL == nil, "App Group entitlement unavailable")
        let published = try XCTUnwrap(DueCount.read())
        XCTAssertEqual(published.due, expected)
        XCTAssertEqual(expected, 7)
    }

    /// After a session everything is answered, so the widget must say zero — the
    /// "including right after a session" half of the acceptance.
    func testTheCountFallsToZeroOnceEverythingIsAnswered() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 3, due: now.addingTimeInterval(-60))
        try context.save()

        for card in deck.notes.flatMap(\.cards) {
            card.due = now.addingTimeInterval(4 * 86_400)
        }
        try context.save()

        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(
            decks: try context.fetch(FetchDescriptor<Deck>()), now: now, using: &generator)
        XCTAssertEqual(plan.count, 0)
    }

    /// §7.1's rule is that there is **one** definition of the day's numbers. Home
    /// publishes what it is already showing; the sync actor and the background
    /// refresh publish what Home *would* show. If those two derivations disagree,
    /// the ring and the streak jump the moment the app is opened — and the day the
    /// app is never opened is precisely the day the widget matters.
    func testTheContextPathPublishesTheGoalAndTheStreakToo() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 9, due: now.addingTimeInterval(-60))
        // A run ending today: today, yesterday, and the two days before.
        for daysAgo in 0...3 {
            let date = try XCTUnwrap(
                Calendar.current.date(byAdding: .day, value: -daysAgo, to: now))
            context.insert(try ReviewLog(
                cardId: "seen-\(daysAgo)", direction: .forward, rating: 3,
                reviewedAt: date, elapsedDays: 1, scheduledDays: 1,
                stateBefore: .review, prevState: CardSchedulingSnapshot()))
        }
        try context.save()

        DueCountPublisher.publish(from: context, now: now, reloadWidgets: false,
                                  to: file, goalCache: try emptyGoalCache())

        let published = try XCTUnwrap(DueCount.read(from: file))
        XCTAssertEqual(published.streak, 4, "four consecutive days, ending today")
        XCTAssertEqual(published.goalDone, 1, "one distinct card graded today")
        XCTAssertEqual(published.goalTarget, published.goalDone + published.due,
                       "no cached target for this day, so the target is what today looks like")
        XCTAssertEqual(published.due, 9)
    }


    /// §5.1: the target is what today looked like the **first** time it was built,
    /// not what it looks like now. Re-deriving it on every publish would grow the
    /// ring's denominator each time a card came due, and the ring would crawl
    /// backwards while the owner was working.
    func testAPublishHonoursTheTargetHomeAlreadyCached() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 9, due: now.addingTimeInterval(-60))
        try context.save()
        let cache = try emptyGoalCache()
        cache.store(40, on: now)

        DueCountPublisher.publish(from: context, now: now, reloadWidgets: false,
                                  to: file, goalCache: cache)

        let published = try XCTUnwrap(DueCount.read(from: file))
        XCTAssertEqual(published.goalTarget, 40, "the cached 40 wins over a fresh 0 + 9")
        XCTAssertEqual(published.due, 9)
    }

    /// The publisher **reads** the cache and never writes it. §5.1 makes the
    /// target what today looked like the first time *Home* built it; a background
    /// publish that stored its own would change the number Home then shows, which
    /// is a behaviour change #111 was not asked to make.
    func testPublishingNeverWritesTheGoalCache() throws {
        let (context, deck) = try makeStore()
        addCards(context, to: deck, count: 9, due: now.addingTimeInterval(-60))
        try context.save()
        let cache = try emptyGoalCache()

        DueCountPublisher.publish(from: context, now: now, reloadWidgets: false,
                                  to: file, goalCache: cache)

        XCTAssertNil(cache.target(on: now), "the publisher must not set today's target")
    }

    // MARK: - Staleness

    /// A count computed for another day is not a small error — it is the wrong
    /// number. The widget shows nothing rather than yesterday's total.
    func testACountFromAnotherDayIsNotShown() throws {
        let yesterday = Calendar.current.startOfDay(for: now.addingTimeInterval(-86_400))
        let stale = DueCount(due: 42, day: yesterday, generatedAt: now.addingTimeInterval(-86_400))

        XCTAssertFalse(stale.isFresh(on: now))
        XCTAssertTrue(DueCount(due: 42, day: Calendar.current.startOfDay(for: now),
                               generatedAt: now).isFresh(on: now))
    }

    // MARK: - #111: the goal and the streak travel in the same file

    /// gotcha 69, the shape that nearly shipped in #112: a **synthesized** `Codable`
    /// initialiser ignores a property's default and throws `keyNotFound` for the
    /// missing key. `DueCount.read` swallows that with `try?`, so a file written
    /// before this card — which exists on every install that has ever run the
    /// widget — would read as `nil` and the widget would say "—" until the app
    /// next published.
    func testAFileWrittenBeforeTheGoalExistedStillReads() throws {
        let formatter = ISO8601DateFormatter()
        let day = Calendar.current.startOfDay(for: now)
        let legacy = """
        {"due":7,"day":"\(formatter.string(from: day))",\
        "generatedAt":"\(formatter.string(from: now))"}
        """
        try Data(legacy.utf8).write(to: file)

        let read = try XCTUnwrap(DueCount.read(from: file),
                                 "a pre-#111 file must still decode")
        XCTAssertEqual(read.due, 7)
        XCTAssertEqual(read.goalTarget, 0)
        XCTAssertEqual(read.goalDone, 0)
        XCTAssertEqual(read.streak, 0)
    }

    func testTheGoalAndStreakSurviveTheRoundTrip() throws {
        let count = DueCount(due: 12, day: Calendar.current.startOfDay(for: now),
                             goalTarget: 30, goalDone: 18, streak: 9, generatedAt: now)
        try count.write(to: file)
        XCTAssertEqual(DueCount.read(from: file), count)
    }

    /// The ring's fraction, with the two edges that would draw a lie: no goal at
    /// all, and a catch-up day that graded more than the morning promised.
    func testTheRingIsEmptyWithoutAGoalAndNeverOverdraws() {
        let day = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(DueCount(due: 0, day: day, goalTarget: 0, goalDone: 0).goalProgress, 0)
        XCTAssertEqual(DueCount(due: 0, day: day, goalTarget: 20, goalDone: 5).goalProgress, 0.25)
        XCTAssertEqual(DueCount(due: 0, day: day, goalTarget: 20, goalDone: 25).goalProgress, 1)
    }

    func testTheFileSurvivesARoundTripAcrossProcesses() throws {
        let count = DueCount(due: 14, day: Calendar.current.startOfDay(for: now), generatedAt: now)
        try count.write(to: file)
        XCTAssertEqual(DueCount.read(from: file), count)
    }

    func testAMissingOrCorruptFileReadsAsNothing() throws {
        XCTAssertNil(DueCount.read(from: file))
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(DueCount.read(from: file))
    }

    // MARK: - Acceptance: the link starts a review with no intermediate screen

    func testTheStudyLinkIsRecognised() throws {
        XCTAssertEqual(DeepLink.destination(for: try XCTUnwrap(URL(string: "repeat://study"))), .study)
        XCTAssertEqual(DeepLink.destination(for: try XCTUnwrap(URL(string: DeepLink.study))), .study)
        XCTAssertEqual(DeepLink.destination(for: try XCTUnwrap(URL(string: "repeat://add"))), .add)
    }

    /// `repeat://study` parses with `study` as the **host**, not the path. A
    /// matcher that only looked at `path` would silently never fire, and the
    /// widget would open the app to Home instead of a session.
    func testTheDestinationComesFromTheHostNotThePath() throws {
        let url = try XCTUnwrap(URL(string: "repeat://study"))
        XCTAssertEqual(url.host(), "study")
        XCTAssertEqual(url.path, "", "the path is empty — matching on it would never fire")
        XCTAssertEqual(DeepLink.destination(for: url), .study)
    }

    func testForeignAndUnknownURLsAreIgnored() throws {
        XCTAssertNil(DeepLink.destination(for: try XCTUnwrap(URL(string: "https://example.com/study"))))
        XCTAssertNil(DeepLink.destination(for: try XCTUnwrap(URL(string: "repeat://settings"))))
    }

    /// The scheme the router matches has to be the one `Info.plist` registers, or
    /// the link never arrives at all.
    func testTheSchemeMatchesTheOneTheAppRegisters() throws {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains(DeepLink.scheme), "registered schemes: \(schemes)")
    }
}
