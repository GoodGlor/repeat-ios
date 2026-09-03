import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// Card #13 acceptance, app half (§4.3 step 1).
final class DeckReconcilerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelStore.container(inMemory: true))
    }

    private func sheet(_ title: String, gid: Int, index: Int = 0) -> SheetProperties {
        SheetProperties(sheetId: gid, title: title, index: index)
    }

    @discardableResult
    private func addStudiedCard(_ ctx: ModelContext, to deck: Deck) -> Card {
        let note = Note(deck: deck, front: "f", back: "b", sheetRow: 0)
        ctx.insert(note)
        let card = ctx.syncCards(for: note, now: now)[0]
        card.state = .review
        card.stability = 17.5
        card.reps = 9
        card.due = now.addingTimeInterval(17 * 86_400)
        return card
    }

    func testNewTabsBecomeDecks() throws {
        let ctx = try makeContext()
        let outcome = try DeckReconciler.reconcile(
            properties: [sheet("Verbs", gid: 0), sheet("Nouns", gid: 7, index: 1)], in: ctx, now: now)

        XCTAssertEqual(outcome.created, ["Verbs", "Nouns"])
        let decks = try ctx.fetch(FetchDescriptor<Deck>()).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(decks.map(\.sheetTitle), ["Verbs", "Nouns"])
        XCTAssertEqual(decks.map(\.sheetId), [0, 7])
    }

    func testReservedTabsNeverBecomeDecks() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(
            properties: [sheet("Verbs", gid: 0), sheet("_log", gid: 1), sheet("_meta", gid: 2)],
            in: ctx, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).map(\.sheetTitle), ["Verbs"])
    }

    /// The acceptance line. Matching by title would read as delete-plus-create,
    /// and a whole deck's scheduling history would vanish on a cosmetic edit.
    func testRenamingATabKeepsTheDeckAndItsSchedulingState() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(properties: [sheet("Verbs", gid: 42)], in: ctx, now: now)
        let deck = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Deck>()).first)
        let card = addStudiedCard(ctx, to: deck)
        try ctx.save()

        let outcome = try DeckReconciler.reconcile(
            properties: [sheet("English verbs", gid: 42)], in: ctx, now: now)

        XCTAssertEqual(outcome.renamed.map(\.to), ["English verbs"])
        XCTAssertTrue(outcome.created.isEmpty, "a rename is not a new deck")
        XCTAssertTrue(outcome.softDeleted.isEmpty)

        let decks = try ctx.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.count, 1)
        XCTAssertEqual(decks[0].sheetTitle, "English verbs")
        XCTAssertEqual(card.stability, 17.5, "scheduling survived the rename")
        XCTAssertEqual(card.reps, 9)
        XCTAssertEqual(card.state, .review)
    }

    /// `sheetTitle` is unique, so a straight rename pass would collide half way
    /// through when two tabs swap names.
    func testTwoTabsSwappingNamesDoesNotCollide() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(
            properties: [sheet("A", gid: 1), sheet("B", gid: 2)], in: ctx, now: now)
        try ctx.save()

        try DeckReconciler.reconcile(
            properties: [sheet("B", gid: 1), sheet("A", gid: 2)], in: ctx, now: now)
        XCTAssertNoThrow(try ctx.save())

        let byGid = Dictionary(uniqueKeysWithValues:
            try ctx.fetch(FetchDescriptor<Deck>()).map { ($0.sheetId, $0.sheetTitle) })
        XCTAssertEqual(byGid[1], "B")
        XCTAssertEqual(byGid[2], "A")
    }

    func testARemovedTabSoftDeletesAndSuspendsItsCards() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(
            properties: [sheet("Verbs", gid: 1), sheet("Nouns", gid: 2)], in: ctx, now: now)
        let nouns = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Deck>()).first { $0.sheetId == 2 })
        let card = addStudiedCard(ctx, to: nouns)
        try ctx.save()

        let outcome = try DeckReconciler.reconcile(properties: [sheet("Verbs", gid: 1)], in: ctx, now: now)

        XCTAssertEqual(outcome.softDeleted, ["Nouns"])
        XCTAssertEqual(nouns.deletedAt, now)
        XCTAssertTrue(card.isSuspended)
        XCTAssertEqual(card.stability, 17.5, "kept for 30 days, so recovery is possible (§4.3)")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).count, 2, "soft, not hard")
    }

    func testATabThatComesBackIsTheSameDeckWithItsHistory() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(properties: [sheet("Verbs", gid: 1)], in: ctx, now: now)
        let deck = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Deck>()).first)
        let card = addStudiedCard(ctx, to: deck)
        try ctx.save()

        try DeckReconciler.reconcile(properties: [], in: ctx, now: now)
        XCTAssertNotNil(deck.deletedAt)

        let outcome = try DeckReconciler.reconcile(properties: [sheet("Verbs", gid: 1)], in: ctx, now: now)
        XCTAssertEqual(outcome.restored, ["Verbs"])
        XCTAssertNil(deck.deletedAt)
        XCTAssertEqual(card.stability, 17.5)
    }

    func testCardsArePurgedOnlyAfterTheRecoveryWindow() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(properties: [sheet("Verbs", gid: 1)], in: ctx, now: now)
        try DeckReconciler.reconcile(properties: [], in: ctx, now: now)
        try ctx.save()

        try DeckReconciler.purgeExpired(in: ctx, now: now.addingTimeInterval(29 * 86_400))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).count, 1, "still recoverable at 29 days")

        try DeckReconciler.purgeExpired(in: ctx, now: now.addingTimeInterval(31 * 86_400))
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).count, 0)
    }

    func testTabOrderDrivesDeckOrder() throws {
        let ctx = try makeContext()
        try DeckReconciler.reconcile(
            properties: [sheet("A", gid: 1, index: 2), sheet("B", gid: 2, index: 0)], in: ctx, now: now)
        let decks = try ctx.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.first { $0.sheetId == 1 }?.sortOrder, 2)
        XCTAssertEqual(decks.first { $0.sheetId == 2 }?.sortOrder, 0)
    }
}

/// `_meta` reaching the scheduler (§5.1) — the third acceptance line.
final class MetaApplicationTests: XCTestCase {

    func testValidParamsFromMetaReachTheScheduler() throws {
        let weights = SchedulerConfig().weights
        let raw = "[" + weights.map { String($0) }.joined(separator: ",") + "]"
        let parsed = try SchedulerConfig.weights(fromMeta: MetaSheet.parse(
            rows: [["fsrs_params", raw]]).rawFSRSParams ?? "")

        XCTAssertEqual(parsed.count, 21)
        XCTAssertEqual(Scheduler(config: SchedulerConfig(weights: parsed)).algorithmVersion, .v6)
    }

    func testRetentionFromMetaReachesTheScheduler() throws {
        let meta = MetaSheet.parse(rows: [["desired_retention", "0.85"]])
        let retention = try SchedulerConfig.retention(fromMeta: try XCTUnwrap(meta.rawDesiredRetention))
        XCTAssertEqual(SchedulerConfig(desiredRetention: retention).desiredRetention, 0.85)
    }

    /// A wrong-length paste must be refused, not applied — FSRS reads its version
    /// from the weight count, so 20 numbers would silently downgrade scheduling.
    func testAWrongLengthParamsValueIsRefused() {
        let meta = MetaSheet.parse(rows: [["fsrs_params", "[0.1, 0.2, 0.3]"]])
        XCTAssertThrowsError(try SchedulerConfig.weights(fromMeta: meta.rawFSRSParams ?? "")) {
            XCTAssertEqual($0 as? SchedulerConfig.ParameterError, .wrongWeightCount(found: 3))
        }
    }
}
