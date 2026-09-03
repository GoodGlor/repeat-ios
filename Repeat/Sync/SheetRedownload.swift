import Foundation
import SwiftData
import GoogleSheets
import Scheduling

/// §6.6's "Re-download everything": wipes notes, keeps scheduling by card id.
///
/// The escape hatch for a local store that has drifted — a botched merge, a
/// half-applied migration, a deck that will not stop showing the wrong text. It
/// throws away everything the Sheet owns and reads it again.
///
/// **Scheduling is not the Sheet's to own** (§3.2: "`Card` fields never leave the
/// phone"), so it must survive. It does because `Card.id` is `noteId#direction`
/// and `noteId` comes from the Sheet's own `id` column: delete the notes, pull
/// them back, and every card lands with the same id it had. The snapshots are
/// re-applied by that id.
///
/// A card whose row has since been deleted from the Sheet simply does not come
/// back, and its snapshot is dropped — which is correct, and is why the count of
/// unmatched snapshots is reported rather than swallowed.
struct SheetRedownload {
    struct Outcome: Equatable {
        var pushedFirst = PushResult()
        var notesRemoved = 0
        var pull = PullResult()
        var schedulingRestored = 0
        /// Cards whose rows no longer exist in the Sheet. Their scheduling is
        /// gone with them.
        var schedulingDropped = 0
    }

    let client: SheetsClient

    init(client: SheetsClient) {
        self.client = client
    }

    func run(in context: ModelContext, now: Date = .now) async throws -> Outcome {
        var outcome = Outcome()

        // Push first. "Wipes notes" would otherwise mean "loses every card typed
        // since the last sync", and a recovery tool that destroys work is not one.
        let discovery = try await SheetDiscovery(client: client).run(in: context, now: now)
        outcome.pushedFirst = try await SheetPush(client: client)
            .run(discovery: discovery, in: context, now: now)

        // Scheduling, by card id.
        var snapshots: [String: CardSchedulingSnapshot] = [:]
        for card in try context.fetch(FetchDescriptor<Card>()) {
            snapshots[card.id] = card.snapshot
        }

        // Notes cascade to their cards; decks, logs and conflicts are untouched.
        let notes = try context.fetch(FetchDescriptor<Note>())
        outcome.notesRemoved = notes.count
        for note in notes { context.delete(note) }
        try context.save()

        // Read everything again, through the ordinary pull.
        let fresh = try await SheetDiscovery(client: client).run(in: context, now: now)
        outcome.pull = try await SheetPull(client: client)
            .run(discovery: fresh, in: context, now: now)

        var restored = 0
        var seen: Set<String> = []
        for card in try context.fetch(FetchDescriptor<Card>()) {
            guard let snapshot = snapshots[card.id] else { continue }
            card.restore(from: snapshot)
            seen.insert(card.id)
            restored += 1
        }
        outcome.schedulingRestored = restored
        outcome.schedulingDropped = snapshots.keys.filter { !seen.contains($0) }.count

        try context.save()
        return outcome
    }
}
