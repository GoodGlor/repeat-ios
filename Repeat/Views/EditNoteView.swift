import SwiftUI
import SwiftData

/// Editing an existing card's wording (§5.4's **Rewrite**).
///
/// The Add form builds a note; this one changes the words on a note that already
/// exists and already has scheduling. Kept separate for exactly that reason: the
/// two look alike and mean different things, and a shared screen would end up
/// with a flag deciding whether to reset a memory.
struct EditNoteView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncCoordinator.self) private var sync: SyncCoordinator?

    let note: Note
    /// §5.4: saving a rewrite clears the lapse count and unsuspends. Off for an
    /// ordinary edit.
    var clearsLeech = false
    var onSaved: (() -> Void)?

    @State private var front = ""
    @State private var back = ""
    @State private var example = ""
    @FocusState private var focused: Bool

    private var isSavable: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Питання", text: $front, axis: .vertical)
                        .focused($focused)
                    TextField("Відповідь", text: $back, axis: .vertical)
                    TextField("Приклад речення (необовʼязково)", text: $example, axis: .vertical)
                } header: {
                    Text("Картка")
                } footer: {
                    Text(clearsLeech
                         ? "Картка повернеться в чергу, а лічильник помилок обнулиться. Те, наскільки добре ти її памʼятаєш, збережеться."
                         : "Зміни потраплять у Таблицю під час наступної синхронізації.")
                }

                if clearsLeech {
                    Section {
                        Text("Ця картка постійно забувається — зазвичай це означає, що вона надто довга або питання допускає кілька відповідей. Перепиши її коротше й однозначніше.")
                            .font(.caption)
                            .foregroundStyle(Palette.ink2)
                    }
                }
            }
            .navigationTitle(clearsLeech ? "Переписати" : "Редагувати")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Зберегти") { save() }
                        .disabled(!isSavable)
                }
            }
            .task {
                front = note.front
                back = note.back
                example = note.example ?? ""
                focused = true
            }
        }
    }

    /// The reset happens on **save**, not when the editor opens: cancelling has
    /// to leave the card exactly as it was, or "Rewrite" becomes a way to
    /// accidentally un-suspend a leech by looking at it.
    private func save() {
        guard isSavable else { return }
        note.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        note.back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExample = example.trimmingCharacters(in: .whitespacesAndNewlines)
        note.example = trimmedExample.isEmpty ? nil : trimmedExample

        if clearsLeech {
            try? Leech.rewrite(note, in: context)
        } else {
            note.updatedAt = .now
            note.refreshContentHash()
            note.pendingUpload = true
            try? context.save()
        }
        // §4.2 trigger 3.
        sync?.trigger(.contentEdited)
        onSaved?()
        dismiss()
    }
}
