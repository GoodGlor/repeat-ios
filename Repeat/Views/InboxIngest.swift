import Foundation
import SwiftData

/// Moves quick captures from the App Group container into the store (§7.3).
///
/// Runs at launch and on foreground: the Share Extension is a separate process
/// that cannot touch SwiftData, so the file drop is the handover, and this is the
/// only place that reads it.
enum InboxIngest {
    struct Outcome: Equatable {
        var ingested = 0
        /// Drops the Share Extension had already finished into cards (§7.3).
        var cardsCreated = 0
        /// Card-shaped drops whose deck has since gone. Kept as inbox items
        /// rather than discarded — the words are still worth having.
        var cardsDemoted = 0
        /// Files that were already known — a drop the extension wrote twice, or a
        /// previous run that was killed after inserting but before deleting.
        var duplicates = 0
        /// Files that could not be decoded. Removed rather than retried forever.
        var unreadable = 0
    }

    @discardableResult
    static func run(
        in context: ModelContext,
        directory: URL? = AppGroup.inboxURL,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        var outcome = Outcome()
        guard let directory, fileManager.fileExists(atPath: directory.path) else { return outcome }

        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == InboxDrop.fileExtension }
        // Oldest first, so the inbox reads in capture order even when several
        // arrive between launches.
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else { return outcome }

        let known = Set(try context.fetch(FetchDescriptor<InboxItem>()).map(\.id))
        var seen = known

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let drop = try? InboxDrop.decoder().decode(InboxDrop.self, from: data)
            else {
                // A half-written or corrupt file will never decode. Keeping it
                // would mean re-reading it on every launch forever.
                try? fileManager.removeItem(at: file)
                outcome.unreadable += 1
                continue
            }

            let text = drop.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.contains(drop.id) || text.isEmpty {
                try? fileManager.removeItem(at: file)
                outcome.duplicates += 1
                continue
            }

            // A drop the extension finished into a card becomes one directly.
            // The extension could not write to SwiftData, so it described the
            // card instead; this is where the description is honoured.
            if drop.isCard, let deck = deck(named: drop.deckTitle, in: context) {
                try AddCardComposer.save(
                    .init(front: text, back: drop.back ?? ""),
                    to: deck, in: context, now: drop.createdAt
                )
                outcome.cardsCreated += 1
            } else {
                if drop.isCard { outcome.cardsDemoted += 1 }
                context.insert(InboxItem(
                    id: drop.id, text: text, createdAt: drop.createdAt, sourceURL: drop.sourceURL
                ))
            }
            seen.insert(drop.id)
            outcome.ingested += 1

            // Deleted only after the insert. A crash between the two leaves the
            // file, which the id check above then treats as a duplicate — the
            // capture survives either way, and never lands twice.
            try? fileManager.removeItem(at: file)
        }

        if outcome.ingested > 0 { try context.save() }
        return outcome
    }

    private static func deck(named title: String?, in context: ModelContext) -> Deck? {
        guard let title else { return nil }
        let descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.sheetTitle == title })
        guard let deck = try? context.fetch(descriptor).first, deck.deletedAt == nil,
              deck.malformedReason == nil
        else { return nil }
        return deck
    }
}
