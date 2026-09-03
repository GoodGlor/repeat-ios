import SwiftUI
import SwiftData

/// Home's "Needs attention" section (§6.2) — **hidden entirely when empty**.
///
/// It collects the three things that quietly stop working: decks whose header the
/// app cannot read (§4.6), local edits the Sheet overruled (§4.5), and a Google
/// connection that is refusing, and cards that keep being forgotten (§5.4).
///
/// Everything here is the result of a decision already taken. The app never
/// prompts mid-flow; this is where it says afterwards what it decided.
enum NeedsAttention {
    /// The banner text for a connection the owner has to fix, or `nil`.
    ///
    /// Offline is deliberately **not** one: the queue is safe, there is nothing
    /// to do, and putting it here would leave a permanent red row on the Home
    /// screen of anyone who commutes underground. Same for a 5xx — §4.6 retries
    /// it, and the owner cannot help.
    static func authProblem(status: SyncCoordinator.Status) -> String? {
        switch status {
        case .failed(let message, true): message
        case .notConfigured: Localized.string("Google Таблицю не підключено.")
        case .idle, .syncing, .offline, .failed: nil
        }
    }

    /// §6.2: the section is hidden when empty, not shown empty.
    static func isEmpty(
        conflicts: Int,
        malformedDecks: Int,
        status: SyncCoordinator.Status,
        leeches: Int = 0
    ) -> Bool {
        conflicts == 0 && malformedDecks == 0 && leeches == 0
            && authProblem(status: status) == nil
    }

    /// §5.4's line.
    ///
    /// Was hand-rolled as `count == 1 ? … : "карток"`, which is wrong for 2–4 and
    /// for 21: Ukrainian wants "2 картки" and "21 картка", and a test asserted
    /// the broken form. The catalogue varies it now.
    static func leechTitle(count: Int, locale: Locale = .current) -> String {
        Localized.string("\(count) картка постійно забувається", locale: locale)
    }
}

struct NeedsAttentionCard: View {
    @Query private var conflicts: [SyncConflict]
    @Query private var decks: [Deck]

    let status: SyncCoordinator.Status
    var onOpenSettings: (() -> Void)?
    /// §5.4. Passed in rather than fetched here: the threshold lives in Settings,
    /// and Home already holds it.
    var leeches: [Card] = []
    var onRewrite: ((Note) -> Void)?
    var onDelete: ((Note) -> Void)?

    private var malformed: [Deck] {
        decks.filter { $0.malformedReason != nil }.sorted { $0.sheetTitle < $1.sheetTitle }
    }

    private var authProblem: String? { NeedsAttention.authProblem(status: status) }

    var isEmpty: Bool {
        NeedsAttention.isEmpty(conflicts: conflicts.count,
                               malformedDecks: malformed.count, status: status,
                               leeches: leeches.count)
    }

    var body: some View {
        if !isEmpty {
            Section {
                // One row holding one card, rather than a row per item: a plain
                // List gives every row an edge-to-edge background, which made this
                // section the only full-bleed block on a screen of inset cards.
                VStack(alignment: .leading, spacing: 14) {
                    if let authProblem {
                        row(symbol: "key.slash", tint: Palette.again,
                            title: authProblem,
                            detail: Localized.string("Перевірте ключ службового акаунта в Налаштуваннях.")) {
                            onOpenSettings?()
                        }
                    }

                    if !conflicts.isEmpty {
                        NavigationLink {
                            ConflictsListView()
                        } label: {
                            label(symbol: "arrow.triangle.branch", tint: Palette.hard,
                                  title: Localized.string("Конфлікти синхронізації: \(conflicts.count)"),
                                  detail: Localized.string("Ваші правки, які перезаписала Таблиця."))
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(malformed) { deck in
                        label(symbol: "tablecells.badge.ellipsis", tint: Palette.hard,
                              title: deck.sheetTitle,
                              detail: deck.malformedReason ?? "")
                    }

                    if !leeches.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            label(symbol: "exclamationmark.arrow.circlepath", tint: Palette.again,
                                  title: NeedsAttention.leechTitle(count: leeches.count),
                                  detail: Localized.string("Їх відкладено, щоб вони не займали сесію. Перепиши або видали."))
                            ForEach(leeches, id: \.id) { card in
                                leechRow(card)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Palette.radius))
                // #89: every card-shaped surface on Home is raised. A flat one
                // beside raised ones does not read as "quieter", it reads as a
                // rendering bug.
                .elevated(.low)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            } header: {
                Text("Потребує уваги")
                    .font(.headline)
                    .textCase(nil)
                    .foregroundStyle(Palette.onSurface)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)
            }
        }
    }

    /// One leech, with §5.4's two actions.
    ///
    /// The wording is shown because the point is to judge it: a card that keeps
    /// being forgotten is usually badly written, and deciding that needs to be
    /// possible without opening the editor first.
    private func leechRow(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.note.front)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.onSurface)
                .lineLimit(2)
            Text(card.note.back)
                .font(.caption)
                .foregroundStyle(Palette.onSurfaceMuted)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("Переписати") { onRewrite?(card.note) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                // Explicitly tinted: `role: .destructive` alone loses to the
                // accent tint inherited from the tab bar, and a delete button
                // that looks exactly like the safe one next to it is a trap.
                Button("Видалити", role: .destructive) { onDelete?(card.note) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(Palette.again)
                Spacer()
                Text("\(card.lapses) помилок")
                    .font(.caption2)
                    .foregroundStyle(Palette.onSurfaceMuted)
            }
        }
        .padding(.leading, 26)
    }

    private func row(
        symbol: String, tint: Color, title: String, detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label(symbol: symbol, tint: tint, title: title, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private func label(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(Palette.onSurfaceMuted)
                }
            }
        }
    }
}
