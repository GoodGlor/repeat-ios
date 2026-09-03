import AppIntents
import Foundation
import SwiftData

/// The container the intents work in.
///
/// An intent declared in the app target runs *in the app's process*, which may
/// have been launched in the background just to serve it. Opening a second
/// `ModelContainer` on the same store file from the same process is the kind of
/// thing that works until it does not, so the app registers its container at
/// launch and the intents borrow it; the lazy fallback covers the case where an
/// intent is served before `RepeatApp.init` has run.
@MainActor
enum IntentStore {
    private static var registered: ModelContainer?

    static func register(_ container: ModelContainer) {
        registered = container
    }

    static func container() throws -> ModelContainer {
        if let registered { return registered }
        let container = try ModelStore.container()
        registered = container
        return container
    }

    static func context() throws -> ModelContext {
        try container().mainContext
    }
}

// MARK: - Add card

/// §7.4: add a card without opening anything.
struct AddCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Додати картку"
    static var description = IntentDescription(
        "Додає картку до колоди. Вона потрапить у таблицю під час наступної синхронізації."
    )
    /// The point of this one is that it does *not* open the app — from the Action
    /// button it should be a single press and a confirmation.
    static var openAppWhenRun = false

    @Parameter(title: "Питання", requestValueDialog: "Що на лицьовому боці?")
    var front: String

    /// Optional on purpose. §7.4 names the intent `AddCard(front:deck:)`, but a
    /// note with no answer cannot be saved — so a front-only call becomes a quick
    /// capture rather than an error or an empty card.
    @Parameter(title: "Відповідь")
    var back: String?

    @Parameter(title: "Колода")
    var deck: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Додати \(\.$front) до \(\.$deck)") {
            \.$back
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context()
        let outcome = try IntentActions.addCard(
            front: front, back: back, deckTitle: deck, in: context
        )
        switch outcome {
        case let .saved(front, deck):
            DueCountPublisher.publish(from: context)
            return .result(dialog: "Додано «\(front)» до «\(deck)».")
        case let .captured(front):
            return .result(dialog: "Збережено «\(front)» в інбокс — відповідь допишеш у застосунку.")
        case let .unknownDeck(title):
            return .result(dialog: "Колоди «\(title)» немає.")
        case .noDecks:
            return .result(dialog: "Ще немає жодної колоди — спершу підключи таблицю.")
        case .emptyFront:
            return .result(dialog: "Порожнє питання — нічого додавати.")
        }
    }
}

// MARK: - Start review

/// §7.4: straight into a session.
struct StartReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Почати повторення"
    static var description = IntentDescription("Відкриває сесію повторення.")
    /// Unlike the other two, this one has nothing to return — the result *is*
    /// the app being open on the right screen.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.request(.study)
        return .result()
    }
}

// MARK: - Due count

/// §7.4: the number, for a Shortcut to do something with.
struct DueCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Скільки карток до повторення"
    static var description = IntentDescription("Повертає кількість карток на сьогодні.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let context = try IntentStore.context()
        let settings = AppSettings()
        guard let due = IntentActions.dueCount(in: context, config: settings.queueConfig) else {
            // Returning 0 here would be a lie in the one direction that matters:
            // "nothing to do today" is exactly the answer that stops someone
            // opening the app.
            return .result(value: 0, dialog: "Не вдалося порахувати — відкрий застосунок.")
        }
        return .result(
            value: due,
            dialog: due == 0 ? "На сьогодні все повторено." : "Карток до повторення: \(due)."
        )
    }
}

// MARK: - Donation

/// Puts the three in Shortcuts and on the Action button without anyone having to
/// build a shortcut first (§7.4).
struct RepeatShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartReviewIntent(),
            phrases: ["Почати повторення в \(.applicationName)"],
            shortTitle: "Повторення",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: DueCountIntent(),
            phrases: ["Скільки карток у \(.applicationName)"],
            shortTitle: "Скільки карток",
            systemImageName: "number.circle"
        )
        AppShortcut(
            intent: AddCardIntent(),
            phrases: ["Додати картку в \(.applicationName)"],
            shortTitle: "Додати картку",
            systemImageName: "plus.circle"
        )
    }
}
