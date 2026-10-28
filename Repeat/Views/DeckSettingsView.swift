import SwiftUI
import SwiftData

/// Per-deck knobs, reached by swiping a deck row on Home (§6.2).
struct DeckSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var decks: [Deck]

    @Bindable var deck: Deck
    @State private var confirmingSuspend = false
    /// #153: the deck's tags, read off the main queue when the screen opens —
    /// reading tags means reading every note (see `DeckFilter.TagIndex`).
    @State private var tagOptions: [DeckFilter] = []
    @State private var tagFilter: DeckFilter = .all

    private var liveDecks: [Deck] { decks.filter { $0.deletedAt == nil } }
    private var position: Int {
        liveDecks
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
            .firstIndex { $0.sheetTitle == deck.sheetTitle } ?? 0
    }

    var body: some View {
        Form {
            // #153: one tag at a time (#144's rule). No section at all for a
            // deck without tags — there is nothing to choose between.
            if !tagOptions.isEmpty {
                Section {
                    Picker("Картки", selection: Binding(get: { tagFilter }, set: chooseTag)) {
                        ForEach(tagOptions, id: \.self) { option in
                            Text(verbatim: option.label).tag(option)
                        }
                    }
                    .accessibilityIdentifier("deckSettings.filter")
                } header: {
                    Text("Що вивчати")
                } footer: {
                    Text("Лише ці картки потрапляють у повторення: і в спільне на головному екрані, і в повторення цієї колоди.")
                }
            }

            Section("Нові картки") {
                Stepper(value: DeckSettings.binding(deck, \.newCardsPerDay, in: context),
                        in: DeckSettings.newCardsPerDayRange) {
                    LabeledContent("На день", value: "\(deck.newCardsPerDay)")
                }
                Text("Скільки нових карток із цієї колоди зʼявиться в черзі за день. 0 — не показувати нових.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }

            Section("Колір") {
                HStack(spacing: 12) {
                    ForEach(DeckSettings.palette, id: \.self) { hex in
                        Button {
                            deck.colorHex = hex
                            try? context.save()
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? Palette.accent)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Palette.ink, lineWidth: deck.colorHex == hex ? 2.5 : 0)
                                        .padding(-3)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex)
                        .accessibilityAddTraits(deck.colorHex == hex ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Порядок") {
                LabeledContent("Позиція", value: Localized.string("\(position + 1) з \(liveDecks.count)"))
                HStack {
                    Button("Вище") { move(.up) }
                        .disabled(position == 0)
                    Spacer()
                    Button("Нижче") { move(.down) }
                        .disabled(position >= liveDecks.count - 1)
                }
                .buttonStyle(.bordered)
            }

            Section("Повторення") {
                Toggle("Озвучувати питання",
                       isOn: DeckSettings.binding(deck, \.autoTTS, in: context))
                Toggle("Вводити відповідь",
                       isOn: DeckSettings.binding(deck, \.typeAnswer, in: context))
                // No issue numbers in user-facing copy: the reader is a person
                // studying vocabulary, not someone reading the board.
                Text("Питання читатиметься вголос, щойно картка зʼявиться; довгий дотик озвучує будь-яку картку. З уведенням відповіді картка розкривається не дотиком, а після набраного слова.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }

            Section {
                if DeckSettings.isFullySuspended(deck) {
                    Button("Повернути в чергу") {
                        try? DeckSettings.setSuspended(false, deck: deck, in: context)
                    }
                } else {
                    Button("Призупинити всі картки", role: .destructive) {
                        confirmingSuspend = true
                    }
                }
            } footer: {
                Text("Призупинені картки не потрапляють у чергу. Розклад не змінюється — колода продовжиться з того самого місця.")
            }
        }
        .navigationTitle(deck.sheetTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { dismiss() }
            }
        }
        .task {
            let index = await DeckFilter.TagIndex.load(deckTitled: deck.sheetTitle,
                                                       from: context.container)
            tagOptions = index.options
            tagFilter = DeckFilter.remembered(forDeckTitled: deck.sheetTitle, options: index.options)
        }
        .confirmationDialog(
            "Призупинити всі картки колоди?",
            isPresented: $confirmingSuspend,
            titleVisibility: .visible
        ) {
            Button("Призупинити", role: .destructive) {
                try? DeckSettings.setSuspended(true, deck: deck, in: context)
            }
        } message: {
            Text("Розклад збережеться — картки просто зникнуть із черги, доки ви їх не повернете.")
        }
    }

    /// Written at once; Home rebuilds its plan when this sheet closes.
    private func chooseTag(_ filter: DeckFilter) {
        tagFilter = filter
        DeckFilter.remember(filter, forDeckTitled: deck.sheetTitle)
    }

    private func move(_ direction: DeckSettings.Move) {
        try? DeckSettings.move(deck, direction, among: liveDecks, in: context)
    }
}
