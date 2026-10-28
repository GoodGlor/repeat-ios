import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// #25 — the three acceptance criteria, and the `_meta` precedence they depend on.
final class SettingsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "settings-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return suite
    }

    // MARK: - Acceptance: changing desired retention changes the next intervals

    func testChangingDesiredRetentionChangesTheNextIntervals() throws {
        let app = AppSettings(defaults: defaults())

        // A card with real history — a brand-new card's first steps are fixed by
        // the learning steps and would not move whatever the retention.
        var card = CardSchedulingSnapshot()
        card.state = .review
        card.stability = 20
        card.difficulty = 5
        card.reps = 6
        card.lastReview = now.addingTimeInterval(-10 * 86_400)

        app.desiredRetention = 0.80
        let relaxed = try Scheduler(config: app.schedulerConfig)
            .preview(for: card, now: now)[.good]?.interval

        app.desiredRetention = 0.95
        let strict = try Scheduler(config: app.schedulerConfig)
            .preview(for: card, now: now)[.good]?.interval

        let relaxedInterval = try XCTUnwrap(relaxed)
        let strictInterval = try XCTUnwrap(strict)
        XCTAssertLessThan(strictInterval, relaxedInterval,
                          "wanting to remember more must mean seeing the card sooner")
    }

    /// §5.1 gives `_meta` the last word so optimizer output can be pasted into the
    /// spreadsheet without a rebuild.
    func testTheSheetOverridesTheSlider() {
        let store = defaults()
        let app = AppSettings(defaults: store)
        app.desiredRetention = 0.85
        XCTAssertEqual(app.effectiveRetention, 0.85)
        XCTAssertFalse(app.retentionIsSetBySheet)

        SchedulingOverrides(retention: 0.92, weights: nil).save(defaults: store)
        app.refreshOverrides()

        XCTAssertEqual(app.effectiveRetention, 0.92)
        XCTAssertTrue(app.retentionIsSetBySheet, "the slider must show as overridden, not broken")
        XCTAssertEqual(app.schedulerConfig.desiredRetention, 0.92)
    }

    func testAWeightOverrideOfTheWrongLengthIsIgnored() {
        let store = defaults()
        // 20 floats: `FSRSAlgorithmVersion.detect` would read this as FSRS-5 and
        // silently downgrade every future interval.
        SchedulingOverrides(retention: nil, weights: Array(repeating: 0.5, count: 20))
            .save(defaults: store)
        let app = AppSettings(defaults: store)

        XCTAssertEqual(app.schedulerConfig.weights.count, SchedulerConfig.fsrs6WeightCount)
        XCTAssertEqual(app.schedulerConfig.weights, SchedulerConfig().weights)
    }

    /// The overrides blob every device already holds has no `problems` key. A
    /// synthesized decoder would throw on it, and `load` would answer with empty
    /// overrides — the Sheet's retention and weights gone until the next sync.
    func testAnOverridesBlobWrittenBeforeProblemsExistedStillDecodes() throws {
        let store = defaults()
        let old = try JSONEncoder().encode(["retention": 0.92])
        store.set(old, forKey: SchedulingOverrides.key)

        let loaded = SchedulingOverrides.load(defaults: store)
        XCTAssertEqual(loaded.retention, 0.92)
        XCTAssertEqual(loaded.problems, [])
    }

    /// §5.1: a refused `_meta` value reaches Home, and survives a relaunch, and
    /// is cleared by the next sync that applies cleanly.
    func testRefusedMetaValuesArePersistedWithTheOverrides() {
        let store = defaults()
        SchedulingOverrides(retention: nil, weights: nil,
                            problems: ["fsrs_params: 20 numbers"]).save(defaults: store)
        let app = AppSettings(defaults: store)
        XCTAssertEqual(app.overrides.problems, ["fsrs_params: 20 numbers"])

        SchedulingOverrides(retention: 0.9, weights: nil).save(defaults: store)
        app.refreshOverrides()
        XCTAssertEqual(app.overrides.problems, [])
    }

    func testTheNewCardCapReachesTheQueueBuilder() {
        let app = AppSettings(defaults: defaults())
        app.globalNewCardCap = 7
        XCTAssertEqual(app.queueConfig.globalNewCardCap, 7)
    }

    // MARK: - The per-deck allowance, on the Settings screen

    /// The value that actually decides how many new cards a day arrive is the
    /// deck's, not the global ceiling — so Settings lists the decks. The order has
    /// to be Home's, or the same three decks read as a different three lists.
    func testSettingsListsLiveDecksInHomesOrder() {
        let verbs = Deck(sheetTitle: "Дієслова", sheetId: 1, sortOrder: 0)
        let phrases = Deck(sheetTitle: "Фрази", sheetId: 2, sortOrder: 1)
        // Decks arriving from a new tab all start at sortOrder 0, so ties are
        // ordinary rather than exotic; the title breaks them.
        let alphabet = Deck(sheetTitle: "Абетка", sheetId: 3, sortOrder: 1)
        let removed = Deck(sheetTitle: "Старе", sheetId: 4, sortOrder: 0)
        removed.deletedAt = now

        let rows = SettingsView.deckRows([phrases, removed, alphabet, verbs])

        XCTAssertEqual(rows.map(\.sheetTitle), ["Дієслова", "Абетка", "Фрази"])
    }

    /// A deleted tab's deck is kept for 30 days so it can be recovered (§4.3). It
    /// has no queue, so a stepper for it would set a number nothing reads.
    func testADeletedDecksRowIsNotOffered() {
        let deck = Deck(sheetTitle: "Дієслова", sheetId: 1)
        deck.deletedAt = now
        XCTAssertTrue(SettingsView.deckRows([deck]).isEmpty)
    }

    /// A missing key must not read as 0 — the typed `UserDefaults` accessors
    /// return zero for absent keys, which would replace every default silently.
    func testDefaultsSurviveAnEmptyStore() {
        let app = AppSettings(defaults: defaults())
        XCTAssertEqual(app.desiredRetention, 0.90)
        XCTAssertEqual(app.globalNewCardCap, 30)
        XCTAssertEqual(app.leechThreshold, 8)
        XCTAssertEqual(app.reminderMinutes, 21 * 60)
        XCTAssertFalse(app.autofillEnabled)
    }

    func testReminderTimeIsStoredAsMinutesSoItSurvivesATimezoneChange() {
        let app = AppSettings(defaults: defaults())
        app.reminderMinutes = 7 * 60 + 30
        XCTAssertEqual(app.reminderTime.hour, 7)
        XCTAssertEqual(app.reminderTime.minute, 30)
        XCTAssertEqual(SettingsView.minutes(from: SettingsView.date(fromMinutes: 1290)), 1290)
    }

    // MARK: - Acceptance: re-download everything preserves every card's due date

    func testRedownloadPreservesEveryCardsSchedulingExactly() async throws {
        let noteIds = (0..<4).map { _ in UUID() }
        let rows = noteIds.enumerated().map { index, id in
            SheetSyncHarness.row(id, front: "f\(index)", back: "b\(index)",
                                 reverse: index == 0)
        }
        let stub = SheetStub(rows: ["Verbs": [SheetSyncHarness.header] + rows])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        context.insert(Deck(sheetTitle: "Verbs", sheetId: 0))
        try context.save()

        let client = try SheetSyncHarness.makeClient(stub)
        let discovery = try await SheetDiscovery(client: client).run(in: context, now: now)
        _ = try await SheetPull(client: client).run(discovery: discovery, in: context, now: now)

        // Give every card distinct, non-default scheduling.
        let before: [String: CardSchedulingSnapshot] = {
            var map: [String: CardSchedulingSnapshot] = [:]
            let cards = (try? context.fetch(FetchDescriptor<Card>())) ?? []
            for (index, card) in cards.sorted(by: { $0.id < $1.id }).enumerated() {
                card.state = .review
                card.due = self.now.addingTimeInterval(Double(index + 1) * 86_400)
                card.stability = 11.5 + Double(index)
                card.difficulty = 4.25 + Double(index) / 10
                card.reps = 3 + index
                card.lapses = index
                card.lastReview = self.now.addingTimeInterval(-Double(index) * 3600)
                card.learningStepIndex = index % 2
                map[card.id] = card.snapshot
            }
            return map
        }()
        try context.save()
        XCTAssertEqual(before.count, 5, "four notes, one of them reversed")

        let outcome = try await SheetRedownload(client: client).run(in: context, now: now)

        XCTAssertEqual(outcome.notesRemoved, 4)
        XCTAssertEqual(outcome.pull.created, 4, "every note came back")
        XCTAssertEqual(outcome.schedulingRestored, 5)
        XCTAssertEqual(outcome.schedulingDropped, 0)

        let after = try ModelContext(container).fetch(FetchDescriptor<Card>())
        XCTAssertEqual(after.count, 5)
        for card in after {
            let original = try XCTUnwrap(before[card.id], "card \(card.id) came back with a new id")
            XCTAssertEqual(card.due, original.due, "due date must survive exactly")
            XCTAssertEqual(card.snapshot, original)
        }
    }

    /// A recovery tool that destroys work is not one: anything typed since the
    /// last sync is pushed before the wipe.
    func testRedownloadPushesLocalWorkBeforeWipingIt() async throws {
        let stub = SheetStub(rows: ["Verbs": [SheetSyncHarness.header]])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()

        try AddCardComposer.save(
            .init(front: "не втратити", back: "do not lose"), to: deck, in: context, now: now)

        let outcome = try await SheetRedownload(client: try SheetSyncHarness.makeClient(stub))
            .run(in: context, now: now)

        XCTAssertEqual(outcome.pushedFirst.appended, 1)
        let appended = try XCTUnwrap(stub.appends.first?.values.first)
        XCTAssertTrue(appended.contains("не втратити"), "row was \(appended)")
    }

    func testSchedulingForARowThatIsGoneIsReportedRatherThanSilentlyLost() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            SheetSyncHarness.header, SheetSyncHarness.row(id, front: "a", back: "b"),
        ]])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        context.insert(Deck(sheetTitle: "Verbs", sheetId: 0))
        try context.save()

        let client = try SheetSyncHarness.makeClient(stub)
        let discovery = try await SheetDiscovery(client: client).run(in: context, now: now)
        _ = try await SheetPull(client: client).run(discovery: discovery, in: context, now: now)

        // The owner deletes the row between the pull and the re-download.
        stub.rows["Verbs"] = [SheetSyncHarness.header]

        let outcome = try await SheetRedownload(client: client).run(in: context, now: now)

        XCTAssertEqual(outcome.schedulingRestored, 0)
        XCTAssertEqual(outcome.schedulingDropped, 1)
    }

    // MARK: - Acceptance: both API keys live only in the Keychain

    func testNeitherAPIKeyIsWrittenToUserDefaults() throws {
        let name = "settings-keys-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }

        let app = AppSettings(defaults: store)
        app.autofillEnabled = true
        app.autofillModel = "claude-sonnet-5"

        let persisted = store.dictionaryRepresentation()
        for (key, value) in persisted {
            let text = String(describing: value)
            XCTAssertFalse(text.contains("sk-ant"), "\(key) holds an Anthropic key")
            XCTAssertFalse(text.contains("PRIVATE KEY"), "\(key) holds a private key")
            XCTAssertFalse(text.contains("service_account"), "\(key) holds a service account")
        }

        // The model id is not a secret and is deliberately in defaults.
        XCTAssertEqual(store.string(forKey: "settings.autofillModel"), "claude-sonnet-5")
    }

    func testTheAnthropicKeyRoundTripsThroughTheKeychainAndMasks() throws {
        try? AnthropicKeyStore.delete()
        addTeardownBlock { try? AnthropicKeyStore.delete() }

        XCTAssertNil(try AnthropicKeyStore.load())
        try AnthropicKeyStore.save("  sk-ant-api03-abcdefghijklmnop  ")
        XCTAssertEqual(try AnthropicKeyStore.load(), "sk-ant-api03-abcdefghijklmnop")
        XCTAssertEqual(AnthropicKeyStore.masked("sk-ant-api03-abcdefghijklmnop"), "sk-ant-…mnop")

        // Saving an empty key removes it rather than storing whitespace.
        try AnthropicKeyStore.save("   ")
        XCTAssertNil(try AnthropicKeyStore.load())
    }

    /// The two keys have different lifetimes; deleting one must never touch the
    /// other.
    func testTheTwoKeyStoresAreIndependent() throws {
        addTeardownBlock { try? AnthropicKeyStore.delete() }
        try AnthropicKeyStore.save("sk-ant-api03-abcdefghijklmnop")
        try CredentialStore.delete()
        XCTAssertNotNil(try AnthropicKeyStore.load())
        XCTAssertNotEqual(AnthropicKeyStore.service, CredentialStore.service)
    }

    // MARK: - Isolation (the pull-to-refresh crash, 2026-09-04)

    /// Settings runs a re-download on the **main** context, from the main actor.
    /// Every step — discovery, push, pull — takes that context, so every step has
    /// to stay on the actor that owns it.
    @MainActor
    func testARedownloadStaysOnTheActorThatOwnsTheContext() async throws {
        let stub = SheetStub(rows: ["Verbs": [
            SheetSyncHarness.header, SheetSyncHarness.row(UUID(), front: "a", back: "b"),
        ]])
        let container = try ModelStore.container(inMemory: true)
        let context = container.mainContext
        context.insert(Deck(sheetTitle: "Verbs", sheetId: 0))
        try context.save()
        let start = Date()

        let outcome = try await SheetRedownload(client: try SheetSyncHarness.makeClient(stub))
            .run(in: context, now: now)

        XCTAssertEqual(outcome.pull.created, 1, "the re-download did not run")
        let uses = try OffQueue.uses(since: start)
        XCTAssertTrue(uses.isEmpty, "the main context was used off the main queue:\n"
                      + uses.joined(separator: "\n"))
    }
}
