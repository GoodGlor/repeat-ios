import SwiftUI
import SwiftData

/// The app edits the Sheet overruled (§4.5, §6.2).
///
/// Shows both versions rather than only the lost one: "re-apply" means
/// overwriting what is in the Sheet now, and that is not a decision anyone can
/// make without seeing what they would be overwriting.
struct ConflictsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SyncConflict.occurredAt, order: .reverse) private var conflicts: [SyncConflict]

    var body: some View {
        List {
            if conflicts.isEmpty {
                ContentUnavailableView(
                    "Конфліктів немає",
                    systemImage: "checkmark.circle",
                    description: Text("Тут зʼявляться правки, які не потрапили в Таблицю.")
                )
            }
            ForEach(conflicts) { conflict in
                Section(conflict.deckTitle) {
                    version(Localized.string("Ваша правка"), front: conflict.front, back: conflict.back,
                            example: conflict.example, tint: Palette.accent)
                    version(Localized.string("У Таблиці зараз"), front: conflict.winningFront,
                            back: conflict.winningBack, example: nil, tint: Palette.ink2)

                    Button("Застосувати мою правку") { reapply(conflict) }
                    Button("Відхилити", role: .destructive) {
                        try? ConflictResolver.dismiss(conflict, in: context)
                    }
                }
            }
        }
        .navigationTitle("Конфлікти синхронізації")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func version(
        _ title: String, front: String, back: String, example: String?, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(tint)
            Text(front).font(.body.weight(.medium))
            Text(back).font(.subheadline).foregroundStyle(Palette.ink2)
            if let example, !example.isEmpty {
                Text(example).font(.caption).italic().foregroundStyle(Palette.ink2)
            }
        }
        .padding(.vertical, 2)
    }

    private func reapply(_ conflict: SyncConflict) {
        try? ConflictResolver.reapply(conflict, in: context)
    }
}
