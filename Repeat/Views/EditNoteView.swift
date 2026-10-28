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
    /// #155: the card's picture, above its words. The link lives in the Sheet
    /// (#149), so this screen shows it and does not edit it.
    @State private var picture: UIImage?
    @FocusState private var focused: Bool

    private var isSavable: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let picture {
                    Section {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, maxHeight: 240)
                            .accessibilityLabel("Картинка")
                            .accessibilityIdentifier("edit.picture")
                    } footer: {
                        Text("Картинку змінюють у колонці «image» у Таблиці.")
                    }
                }

                Section {
                    TextField("Питання", text: $front, axis: .vertical)
                        .focused($focused)
                        .accessibilityIdentifier("edit.front")
                    TextField("Відповідь", text: $back, axis: .vertical)
                        .accessibilityIdentifier("edit.back")
                    TextField("Приклад речення (необовʼязково)", text: $example, axis: .vertical)
                        .accessibilityIdentifier("edit.example")
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
                        .accessibilityIdentifier("edit.save")
                }
            }
            .task {
                front = note.front
                back = note.back
                example = note.example ?? ""
                focused = true
                picture = await PictureLoader.image(for: note.extras, maxPixelSize: 1200)
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
