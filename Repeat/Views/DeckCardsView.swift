import SwiftUI
import SwiftData

/// Every card in one deck, and a way to fix the wording of any of them (#121).
///
/// Until this screen there was no way to change a card's words except §5.4's
/// **Rewrite**, which is reserved for leeches — so an ordinary typo in an
/// ordinary card had no way out but the spreadsheet. The edit here is the
/// ordinary one: `clearsLeech: false`, so scheduling and the lapse count are
/// left exactly as they were.
struct DeckCardsView: View {
    @Query private var notes: [Note]

    let deck: Deck
    @State private var search = ""
    @State private var editing: Note?

    init(deck: Deck) {
        self.deck = deck
        // Selected by predicate, never by walking `deck.notes`. #116 measured
        // that walk at 2.4 s on 10k cards and every `@Query` re-faults it, which
        // is gotcha 58 in one sentence. Matched on `sheetTitle` for the same
        // reason `HomeSummary.cards(of:)` is — it is the deck's identity in the
        // Sheet, and it survives the deck object being refetched.
        let title = deck.sheetTitle
        _notes = Query(
            filter: #Predicate<Note> { note in
                note.deletedAt == nil
                    && note.deck.deletedAt == nil
                    && note.deck.sheetTitle == title
            },
            sort: \Note.front
        )
    }

    /// Filtered in memory rather than by re-running the query: `front` and `back`
    /// are attributes on notes this screen has already fetched, so no
    /// relationship is touched and no second round trip happens per keystroke.
    private var visible: [Note] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.front.localizedCaseInsensitiveContains(query)
                || $0.back.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                empty
            } else {
                ForEach(visible) { note in
                    Button { editing = note } label: { DeckCardRow(note: note) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("deck.card.\(note.front)")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle(deck.sheetTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Explicit, because Home hides its own bar (`toolbar(.hidden, for:
        // .navigationBar)` on its List) and that hiding reaches this pushed
        // screen. Without this there is no search field **and no back button** —
        // #121's UI test caught the first; the second is what makes it a bug
        // rather than a test artefact.
        .toolbar(.visible, for: .navigationBar)
        // `.always`, not the default drawer: on a screen whose whole purpose is
        // finding one card among thousands, a search field that has to be
        // revealed by scrolling is a search field most people never find.
        .searchable(text: $search,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Пошук"))
        .accessibilityIdentifier("deck.cards")
        .sheet(item: $editing) { note in
            EditNoteView(note: note, clearsLeech: false)
        }
    }

    /// Two different nothings: a deck with no cards, and a search that found
    /// none. Saying "this deck is empty" to someone who has just typed a word
    /// into the search field is a small lie that costs them a real moment.
    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: search.isEmpty ? "tray" : "magnifyingglass")
                .font(.title)
                .foregroundStyle(Palette.accent)
                .frame(width: 56, height: 56)
                .background(Palette.accentSoft, in: Circle())
            Text(search.isEmpty ? "У цій колоді ще немає карток" : "Нічого не знайдено")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            if search.isEmpty {
                Text("Додайте їх на вкладці «Додати» або в Таблиці.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("deck.cards.empty")
    }
}

/// One note: its two sides, and where it stands.
private struct DeckCardRow: View {
    let note: Note
    /// #155: decoded small, off the main queue, when the row appears.
    @State private var thumbnail: UIImage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Computed here rather than for the whole deck up front, so `List` pays for
    /// it only on rows that are actually on screen — a dozen, not ten thousand
    /// (gotcha 58).
    private var hint: DeckCards.Hint { DeckCards.hint(for: note.cards, now: .now) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Beside the words at ordinary sizes; above them at the accessibility
            // sizes, where 44 pt of width beside a word broke "reluctant" in two.
            if let thumbnail, !dynamicTypeSize.isAccessibilitySize {
                thumbnailView(thumbnail)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let thumbnail, dynamicTypeSize.isAccessibilitySize {
                    thumbnailView(thumbnail)
                        .padding(.bottom, 6)
                }
                Text(note.front)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(note.back)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Plain coloured text rather than a filled pill: #89 made this app
            // calm and took the `…Soft` fills out with it (see `Palette`), and a
            // list of ten thousand rows is the last place to put ten thousand
            // badges back.
            Text(hint.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Palette.radius))
        .elevated(.low)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thumbnail == nil
            ? "\(note.front), \(note.back), \(hint.label)"
            : "\(note.front), \(note.back), \(hint.label), \(Localized.string("з картинкою"))")
        // 44 pt at 3× is 132 px — the most the row can show.
        .task(id: note.id) {
            thumbnail = await PictureLoader.image(for: note.extras, maxPixelSize: 132)
        }
    }

    private func thumbnailView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    /// `known` and `suspended` share the muted ink deliberately: both mean "not
    /// in your queue", and the word is what tells them apart.
    private var tint: Color {
        switch hint {
        case .due: Palette.streak
        case .new: Palette.accent
        case .learning: Palette.hard
        case .known, .suspended: Palette.onSurfaceMuted
        }
    }
}
