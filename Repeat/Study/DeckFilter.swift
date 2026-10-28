import Foundation
import SwiftData

/// Which of a deck's cards a session covers (#144): all of them, only the notes
/// carrying one tag, or only the notes carrying none.
///
/// One at a time, by the owner's choice. A tag narrows a session; it is not a
/// separate deck, so the deck's new-card allowance and the global cap apply to a
/// tag session exactly as they do to the whole deck.
enum DeckFilter: Hashable, Sendable {
    case all
    case tag(String)
    case untagged

    /// Whether a note with these tags belongs to the filter. Tags arrive from the
    /// Sheet trimmed and without empties (`SheetPull`), but a note made on the
    /// phone does not go through that path, so blanks are ignored here too.
    func matches(_ tags: [String]) -> Bool {
        switch self {
        case .all: true
        case .tag(let name): tags.contains { $0.trimmingCharacters(in: .whitespaces) == name }
        case .untagged: !tags.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// The picker's choices: everything, each distinct tag sorted by name, then
    /// "no tag" when some note has none. **Empty** when no note carries a tag at
    /// all — there is nothing to choose between, so there is no control.
    static func options(tags: [[String]]) -> [DeckFilter] {
        var names = Set<String>()
        var someUntagged = false
        for noteTags in tags {
            let clean = noteTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if clean.isEmpty { someUntagged = true } else { names.formUnion(clean) }
        }
        guard !names.isEmpty else { return [] }
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [.all] + sorted.map(DeckFilter.tag) + (someUntagged ? [.untagged] : [])
    }

    // MARK: - The tag index

    /// Every live note's tags in one deck, by note id — enough to list the
    /// choices and to say which notes a filter keeps, without the notes.
    ///
    /// Exists because reading tags **is** reading notes: `tags` cannot be
    /// filtered in SQL, so the only way to know them is to materialise every
    /// note, and at 10k cards that measured **0.40 s** on its own — more than
    /// §8's whole 0.3 s for a queue build. So the queue reads it through
    /// `TagIndexCache` (built once, not per plan), and Deck settings reads it
    /// off the main queue (`load`). Plain values, so it crosses queues.
    struct TagIndex: Sendable, Equatable {
        let tagsByNote: [UUID: [String]]

        var options: [DeckFilter] { DeckFilter.options(tags: Array(tagsByNote.values)) }

        /// `nil` for `.all`: the queue's signal to take the unfiltered path.
        func noteIds(matching filter: DeckFilter) -> Set<UUID>? {
            guard filter != .all else { return nil }
            return Set(tagsByNote.lazy.filter { filter.matches($0.value) }.map(\.key))
        }

        /// Reads on a `ModelContext` created **inside** the detached task, so it
        /// belongs to that task's queue — the main context is never touched off
        /// its own (the 2026-09-04 crash; `OffQueue`). Sees what has been saved,
        /// which every writer of tags does before this could be asked.
        static func load(deckTitled title: String, from container: ModelContainer) async -> TagIndex {
            await Task.detached(priority: .userInitiated) {
                build(deckTitled: title, in: ModelContext(container))
            }.value
        }

        /// The one fetch, on whatever queue owns `context`.
        static func build(deckTitled title: String, in context: ModelContext) -> TagIndex {
            let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate<Note> { note in
                note.deletedAt == nil && note.deck.sheetTitle == title
            }))) ?? []
            return TagIndex(tagsByNote: Dictionary(
                notes.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// What a deck's own setting means right now (#153): the filter it studies
    /// under, with the index that says which notes that is. A deck never
    /// filtered is `.all` and costs nothing — not even a cache lookup. A tag
    /// that is gone after a sync falls back to `.all`, as #144 decided.
    static func applied(toDeckTitled title: String, in context: ModelContext,
                        defaults: UserDefaults = .standard,
                        cache: TagIndexCache = .shared) -> (filter: DeckFilter, index: TagIndex?) {
        guard let stored = stored(forDeckTitled: title, defaults: defaults), stored != .all
        else { return (.all, nil) }
        let index = cache.index(forDeckTitled: title, in: context)
        return index.options.contains(stored) ? (stored, index) : (.all, nil)
    }

    // MARK: - Remembered per deck

    /// How the choice is written to defaults. A tag is prefixed so that a tag
    /// literally named "all" cannot be mistaken for everything.
    var storageValue: String {
        switch self {
        case .all: "all"
        case .tag(let name): "tag:" + name
        case .untagged: "untagged"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "all": self = .all
        case "untagged": self = .untagged
        default:
            guard storageValue.hasPrefix("tag:") else { return nil }
            self = .tag(String(storageValue.dropFirst(4)))
        }
    }

    /// The deck's remembered choice, if it is still one of `options`. A tag that
    /// vanished in a sync — or a deck that no longer has tags at all — falls back
    /// to everything, which is also what a deck that was never filtered gets.
    static func remembered(forDeckTitled title: String, options: [DeckFilter],
                           defaults: UserDefaults = .standard) -> DeckFilter {
        guard let filter = stored(forDeckTitled: title, defaults: defaults),
              options.contains(filter) else { return .all }
        return filter
    }

    /// What was written, unchecked against the deck's tags — for knowing,
    /// before the tags are read, whether there is a tag to wait for.
    static func stored(forDeckTitled title: String, defaults: UserDefaults = .standard) -> DeckFilter? {
        defaults.string(forKey: key(title)).flatMap(DeckFilter.init(storageValue:))
    }

    static func remember(_ filter: DeckFilter, forDeckTitled title: String,
                         defaults: UserDefaults = .standard) {
        defaults.set(filter.storageValue, forKey: key(title))
    }

    /// Every deck's choice, for `-resetStoreOnLaunch`.
    static func forgetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static let keyPrefix = "deckFilter."

    /// Keyed on `sheetTitle`, the deck's identity in the Sheet — the same key
    /// `DeckCardsView` and `HomeSummary` select by.
    private static func key(_ title: String) -> String { keyPrefix + title }
}

extension DeckFilter {
    /// What the menu and Home's deck row show. A tag is the owner's own word
    /// from the Sheet and is shown as written, never translated.
    var label: String {
        switch self {
        case .all: Localized.string("Усі картки")
        case .tag(let name): name
        case .untagged: Localized.string("Без тегу")
        }
    }
}

/// The tag index per deck, kept between queue builds (#153).
///
/// Home rebuilds its plan on every appearance, foreground and sync, and with a
/// deck's tag now applying to every plan, rebuilding the index each time would
/// put the 0.40 s note fetch on every one of them. Tags change in exactly one
/// place — a pull (`SheetPull` calls `invalidate()`); a note added on the phone
/// has none, and adding or deleting one changes the deck's live note count,
/// which every lookup checks with a cheap `fetchCount`. A stale entry is rebuilt,
/// never trusted.
///
/// Shared across contexts on purpose: the entries are note ids and tags, the
/// same whichever context read them. Locked, because the sync actor and the main
/// queue both build plans.
final class TagIndexCache: @unchecked Sendable {
    static let shared = TagIndexCache()

    private let lock = NSLock()
    private var generation = 0
    private var entries: [String: (generation: Int, noteCount: Int, index: DeckFilter.TagIndex)] = [:]

    func invalidate() {
        lock.lock(); generation += 1; entries = [:]; lock.unlock()
    }

    func index(forDeckTitled title: String, in context: ModelContext) -> DeckFilter.TagIndex {
        let count = (try? context.fetchCount(FetchDescriptor<Note>(predicate: #Predicate<Note> { note in
            note.deletedAt == nil && note.deck.sheetTitle == title
        }))) ?? -1
        lock.lock()
        let current = generation
        if let entry = entries[title], entry.generation == current, entry.noteCount == count {
            lock.unlock()
            return entry.index
        }
        lock.unlock()

        let index = DeckFilter.TagIndex.build(deckTitled: title, in: context)
        lock.lock()
        if generation == current { entries[title] = (current, count, index) }
        lock.unlock()
        return index
    }
}
