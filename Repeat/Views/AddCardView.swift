import SwiftUI
import SwiftData

/// §6.4. Adding a card has to take seconds, so the form stays open, the deck
/// stays selected and the keyboard never goes away between cards.
struct AddCardView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncCoordinator.self) private var sync: SyncCoordinator?
    @Query private var decks: [Deck]
    @Query(sort: \InboxItem.createdAt, order: .forward) private var inbox: [InboxItem]

    /// Set by the tab bar so "Готово" can return to Home.
    var onDone: (() -> Void)?

    @State private var draft = AddCardComposer.Draft()
    @State private var selected: Deck?
    @State private var savedToast = false
    @State private var app = AppSettings()
    @State private var autofilling = false
    @State private var autofillProblem: String?
    /// Resolved once when the tab opens, not per render: deciding it inline
    /// would hit the Keychain on every body evaluation, and SwiftUI evaluates a
    /// form body on every keystroke.
    @State private var autofillAvailable = false
    @FocusState private var focus: Field?

    /// Injected by tests and by the debug launch argument; `nil` means the real
    /// URLSession. The client itself is built per tap so a key added in Settings
    /// takes effect without reopening the tab.
    var autofillTransport: (any AutofillTransport)?

    private enum Field: Hashable { case front, back, example }

    /// Front → Back → Example, then stop. Deliberately not wrapping: arriving
    /// back at Front would look like the card had been saved.
    private func next(after field: Field?) -> Field? {
        switch field {
        case .front: .back
        case .back: .example
        case .example, nil: nil
        }
    }

    private var usable: [Deck] {
        decks
            .filter { $0.deletedAt == nil && $0.malformedReason == nil }
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if usable.isEmpty {
                    Section {
                        Text("Спочатку підключіть Google Таблицю — картки додаються в її аркуші.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink2)
                    }
                } else {
                    deckPicker
                    fields
                    actions
                }
                inboxSection
            }
            .navigationTitle("Нова картка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { finish() }
                }
                // The form's own buttons sit under the keyboard, and this screen
                // exists to make adding a card take seconds — reaching the action
                // must not mean dismissing the keyboard and scrolling first.
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        focus = next(after: focus)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(next(after: focus) == nil)
                    Spacer()
                    Button("Зберегти й додати ще") { saveAndContinue() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(!draft.isSavable || selected == nil)
                        .accessibilityIdentifier("add.saveAndContinue")
                }
            }
            .overlay(alignment: .bottom) { toast }
        }
        .task {
            selected = AddCardComposer.LastDeck.resolve(among: decks)
            // Opening the tab is itself the intent to type, so the keyboard comes
            // up without a tap — unless there are captures waiting, in which case
            // the reason for opening this screen is probably one of them, and a
            // keyboard covering the list would hide it.
            focus = inbox.isEmpty ? .front : nil
            autofillAvailable = AutofillClient.configured(settings: app, transport: transport) != nil
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-autofillDemoOnLaunch") {
                draft.front = "reluctant"
                focus = nil
            }
            // Drives the button without a tap, so the filled state can be
            // screenshotted the same way every time.
            if arguments.contains("-runAutofillOnLaunch") { await autofill() }
            #endif
        }
    }

    // MARK: - Deck chips

    private var deckPicker: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(usable) { deck in
                        let isSelected = deck.sheetTitle == selected?.sheetTitle
                        Button {
                            selected = deck
                            AddCardComposer.LastDeck.remember(deck)
                        } label: {
                            Text(deck.sheetTitle)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected ? Palette.accentSoft : Palette.bg,
                                    in: .capsule
                                )
                                .foregroundStyle(isSelected ? Palette.accent : Palette.ink2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Колода")
        }
    }

    // MARK: - Inbox (§6.4)

    /// Half-finished captures, waiting to become cards. Hidden when empty — an
    /// empty inbox is not news.
    @ViewBuilder
    private var inboxSection: some View {
        if !inbox.isEmpty {
            Section {
                ForEach(inbox) { item in
                    Button { open(item) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text)
                                .font(.body)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            if let source = item.sourceURL, let host = URL(string: source)?.host() {
                                Label(host, systemImage: "link")
                                    .font(.caption)
                                    .foregroundStyle(Palette.ink2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Видалити", role: .destructive) {
                            context.delete(item)
                            try? context.save()
                        }
                    }
                }
            } header: {
                Text("Вхідні · \(inbox.count)")
            } footer: {
                Text("Збережене з інших застосунків. Торкніться, щоб дописати відповідь.")
            }
        }
    }

    private func open(_ item: InboxItem) {
        draft = AddCardComposer.Draft.from(item, reverse: draft.reverse)
        // Front is already filled, so the answer is what is actually being asked
        // for.
        focus = .back
    }

    // MARK: - Fields

    private var fields: some View {
        Section {
            TextField("Наприклад: reluctant", text: $draft.front, axis: .vertical)
                .accessibilityIdentifier("add.front")
                .focused($focus, equals: .front)
                .submitLabel(.next)
            HStack(alignment: .top, spacing: 8) {
                TextField("Наприклад: неохочий", text: $draft.back, axis: .vertical)
                    .accessibilityIdentifier("add.back")
                    .focused($focus, equals: .back)
                autofillButton
            }
            TextField("Приклад речення (необовʼязково)", text: $draft.example, axis: .vertical)
                .focused($focus, equals: .example)
            Toggle("Зворотна картка", isOn: $draft.reverse)
            if let source = draft.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label(url.host() ?? source, systemImage: "link")
                        .font(.caption)
                }
            }
            if let autofillProblem {
                Text(autofillProblem)
                    .font(.caption)
                    .foregroundStyle(Palette.again)
            }
        } header: {
            Text("Картка")
        } footer: {
            Text(draft.reverse
                 ? "Створяться дві картки: питання → відповідь і навпаки."
                 : "Створиться одна картка: питання → відповідь.")
        }
    }

    // MARK: - Autofill (§6.4)

    /// Shown only when autofill is on *and* a key is stored. §6.4's acceptance
    /// asks for exactly this: with autofill off the button is not there, so
    /// there is no way to reach the network by accident.
    @ViewBuilder
    private var autofillButton: some View {
        if autofillAvailable {
            Button {
                Task { await autofill() }
            } label: {
                if autofilling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .disabled(autofilling || draft.trimmedFront.isEmpty)
            .accessibilityLabel("Заповнити відповідь")
        }
    }

    private var transport: any AutofillTransport {
        if let autofillTransport { return autofillTransport }
        #if DEBUG
        if let stub = AutofillClient.debugTransport { return stub }
        #endif
        return AutofillURLSessionTransport()
    }

    /// Never automatic (§6.4) — this runs from a tap and nowhere else.
    private func autofill() async {
        guard let client = AutofillClient.configured(settings: app, transport: transport) else { return }
        let front = draft.trimmedFront
        guard !front.isEmpty else { return }
        let deckTitle = selected?.sheetTitle ?? ""

        autofilling = true
        autofillProblem = nil
        defer { autofilling = false }

        do {
            let suggestion = try await client.suggest(front: front, deckTitle: deckTitle)
            // Applied to whatever is in the form *now*, not to the draft as it
            // was when the request went out — someone typing while it flies
            // should not have their words replaced by a stale copy.
            draft = draft.applying(suggestion)
        } catch let error as AutofillError {
            autofillProblem = error.message
        } catch {
            autofillProblem = AutofillError.transport(error.localizedDescription).message
        }
    }

    private var actions: some View {
        Section {
            Button("Зберегти й додати ще") { saveAndContinue() }
                .font(.headline)
                .disabled(!draft.isSavable || selected == nil)
            Button("Зберегти й закрити") { finish(saving: true) }
                .accessibilityIdentifier("add.saveAndClose")
                .disabled(!draft.isSavable || selected == nil)
        } footer: {
            Text("Картка потрапить у Таблицю під час наступної синхронізації. Без інтернету вона зачекає в черзі.")
        }
    }

    @ViewBuilder
    private var toast: some View {
        if savedToast {
            Text("Збережено")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                // #87: see `OnboardingView` — an `ink` fill needs a `surface`
                // label. White here would have been invisible in dark, on the one
                // piece of UI whose whole job is to confirm the card was saved.
                .background(Palette.ink, in: .capsule)
                .foregroundStyle(Palette.surface)
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Saving

    /// §6.4: fields clear, Front regains focus, toast. The deck and the reverse
    /// toggle deliberately survive — a run of cards is usually a run of the same
    /// kind, and re-picking the deck each time is the whole cost this screen
    /// exists to avoid.
    private func saveAndContinue() {
        guard save() else { return }
        draft = draft.cleared()
        focus = .front
        withAnimation { savedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { savedToast = false }
        }
    }

    private func finish(saving: Bool = false) {
        if saving { _ = save() }
        draft = AddCardComposer.Draft()
        focus = nil
        onDone?()
    }

    private func save() -> Bool {
        guard let deck = selected, draft.isSavable else { return false }
        do {
            try AddCardComposer.save(draft, to: deck, in: context)
            AddCardComposer.LastDeck.remember(deck)
            // §4.2 trigger 3: push only, debounced 3 s. A burst of cards is one
            // sync, not one per card.
            sync?.trigger(.contentEdited)
            return true
        } catch {
            return false
        }
    }
}
