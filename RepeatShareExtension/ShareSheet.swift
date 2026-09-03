import SwiftUI

/// The minimal capture sheet (§7.3).
///
/// Two ways out, and they mean different things: "to the inbox" is *I will deal
/// with this later*, and "save as a card" is *this is finished*. Everything the
/// second one needs is an answer and a deck, so the answer field only appears
/// when a deck exists to put it in.
struct ShareSheet: View {
    let capture: SharedCapture
    let decks: [SharedDecks.Entry]
    var onSave: (InboxDrop) -> Void
    var onCancel: () -> Void

    @State private var front = ""
    @State private var back = ""
    @State private var deck: String?
    @FocusState private var backFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Питання") {
                    TextField("Текст картки", text: $front, axis: .vertical)
                        .lineLimit(1...4)
                    if let source = capture.sourceURL, let host = URL(string: source)?.host() {
                        Label(host, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if decks.isEmpty {
                    Section {
                        Text("Відкрийте застосунок хоча б раз, щоб він показав тут ваші колоди.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Колода") {
                        Picker("Колода", selection: $deck) {
                            ForEach(decks) { entry in
                                Text(entry.title).tag(Optional(entry.title))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("Відповідь") {
                        TextField("Необовʼязково", text: $back, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($backFocused)
                    }
                }

                Section {
                    Button("Зберегти карткою") { save(asCard: true) }
                        .font(.headline)
                        .disabled(!canSaveAsCard)
                    Button("До вхідних") { save(asCard: false) }
                } footer: {
                    Text(canSaveAsCard
                         ? "Картка зʼявиться у Таблиці після наступної синхронізації."
                         : "«До вхідних» збереже текст — відповідь допишете в застосунку.")
                }
            }
            .navigationTitle("Repeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { onCancel() }
                }
            }
            .task {
                front = capture.text
                deck = decks.first?.title
            }
        }
    }

    private var canSaveAsCard: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && deck != nil
    }

    private func save(asCard: Bool) {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFront.isEmpty else { return onCancel() }
        onSave(InboxDrop(
            text: trimmedFront,
            sourceURL: capture.sourceURL,
            deckTitle: asCard ? deck : nil,
            back: asCard ? back.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        ))
    }
}
