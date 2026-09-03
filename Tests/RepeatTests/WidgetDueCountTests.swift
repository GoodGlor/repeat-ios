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
