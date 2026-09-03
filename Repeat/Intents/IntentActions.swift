import Foundation
import SwiftData
import Scheduling

/// What the three intents actually do (§7.4), with no App Intents framework in
/// sight.
///
/// The framework types are a shell: they declare parameters, and call in here.
/// That is what makes any of this testable — an `AppIntent`'s `perform()` cannot
/// be run from a unit test without a live Shortcuts donation, and the part worth
/// testing is the part that touches the store.
enum IntentActions {

    // MARK: - Add card

    /// What happened, in terms the intent can turn into a sentence.
    enum AddOutcome: Equatable {
        /// A real note, queued for the next push exactly like one typed into the
        /// Add form.
        case saved(front: String, deck: String)
        /// Front only: there is no card without an answer, so the text is kept as
        /// a capture and finished in the app (§6.4).
        case captured(front: String)
        /// The intent named a deck that is not there. Named rather than
        /// swallowed: silently filing a card into the wrong deck is worse than
        /// saying no.
        case unknownDeck(String)
        /// Nothing to file into. A fresh install that has not synced yet.
        case noDecks
        /// Shortcuts can pass an empty string, and a card whose prompt is blank
        /// is not a card.
        case emptyFront
    }

    /// Adds a card, or captures the text when there is no answer to add it with.
    ///
    /// Goes through `AddCardComposer.save` rather than building a `Note` here.
    /// That function is where `pendingUpload`, the cleared `lastSyncedHash` and
    /// the card generation live, and a second path that forgot any one of them
    /// would produce a note the sync cannot place.
    @discardableResult
    static func addCard(
        front: String,
        back: String?,
        deckTitle: String?,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) throws -> AddOutcome {
        let front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = (back ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty else { return .emptyFront }

        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let live = decks.filter { $0.deletedAt == nil && $0.malformedReason == nil }
        guard !live.isEmpty else { return .noDecks }

        let deck: Deck
        if let requested = deckTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard let match = live.first(where: {
                $0.sheetTitle.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else { return .unknownDeck(requested) }
            deck = match
        } else if let remembered = AddCardComposer.LastDeck.resolve(among: live, defaults: defaults) {
            deck = remembered
        } else {
            return .noDecks
        }

        guard !back.isEmpty else {
            // No answer yet. The inbox is where §6.4 already puts a half-formed
            // card, so it goes there rather than becoming a note with an empty
            // back that the Sheet would have to carry.
            context.insert(InboxItem(text: front, createdAt: now))
            try context.save()
            return .captured(front: front)
        }

        var draft = AddCardComposer.Draft()
        draft.front = front
        draft.back = back
        try AddCardComposer.save(draft, to: deck, in: context, now: now)
        return .saved(front: front, deck: deck.sheetTitle)
    }

    // MARK: - Due count

    /// The number the widget shows, for whoever asked Siri.
    ///
    /// Reads the published file first. That file is the single definition of
    /// "due" (#26) — Home, the widget and this intent all quote it, so they
    /// cannot disagree. When it is stale the fix is to *republish*, not to count
    /// separately here: a third derivation would eventually be a third number.
    static func dueCount(
        in context: ModelContext,
        config: QueueConfig = QueueConfig(),
        now: Date = .now,
        calendar: Calendar = .current,
        url: URL? = AppGroup.dueCountURL
    ) -> Int? {
        if let published = DueCount.read(from: url), published.isFresh(on: now, calendar: calendar) {
            return published.due
        }
        DueCountPublisher.publish(from: context, config: config, now: now, reloadWidgets: false, to: url)
        guard let refreshed = DueCount.read(from: url),
              refreshed.isFresh(on: now, calendar: calendar)
        else {
            // No App Group container: the write silently did nothing, and
            // guessing a number here would be worse than admitting it.
            return nil
        }
        return refreshed.due
    }
}
