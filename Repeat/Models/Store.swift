import Foundation
import SwiftData

/// Schema version 1. Versioned from the start so the first real migration is a
/// stage rather than a store wipe. The local DB is the only copy of scheduling
/// state (§8), so losing it to a failed lightweight migration is not an
/// acceptable failure mode.
///
/// #21 did add the per-deck TTS and type-answer toggles this comment anticipated,
/// and needed **no** stage: both are `Bool`s with a default, which is all
/// SwiftData's lightweight inference requires to fill the rows already on disk.
/// The rule that matters is the one `Note.lastSyncedHash` taught by breaking —
/// a mandatory attribute with neither a default nor optionality fails the
/// migration outright. A stage becomes necessary when a column changes meaning or
/// type, not when one is added.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Deck.self, Note.self, Card.self, ReviewLog.self, InboxItem.self, SyncConflict.self]
    }
}

/// #112 adds `StreakFreeze`, and with it the first migration this plan has ever
/// had to perform.
///
/// A whole new entity is additive: no column on disk changes meaning or type, so
/// nothing has to be rewritten and `.lightweight` is both correct and the safest
/// thing available. The rule that would have forced a custom stage is the one
/// `Note.lastSyncedHash` taught by breaking — a *mandatory attribute added to an
/// existing model*. `StreakFreeze`'s attributes are mandatory, and may be: there
/// are no rows of it on disk to fill in.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV1.models + [StreakFreeze.self]
    }
}

enum RepeatMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}

enum ModelStore {
    static let schema = Schema(versionedSchema: SchemaV2.self)
    static let storeFileName = "Repeat.store"

    /// Where the store lives.
    ///
    /// Explicit on purpose. `ModelConfiguration`'s default is
    /// `groupContainer: .automatic`, which silently relocates the store into the
    /// App Group as soon as the entitlement exists — and then fails to open it,
    /// because nothing has created `Library/Application Support` in that
    /// container. Deciding the location here means the store cannot move because
    /// of an entitlement change, and the directory is guaranteed to exist.
    ///
    /// The App Group is preferred so #26 and #28 can reach the store later; it
    /// falls back to the app's own container when the entitlement is unavailable,
    /// which is what a free Apple Developer account gets.
    static func storeURL(fileManager: FileManager = .default) throws -> URL {
        let base: URL
        if let group = AppGroup.containerURL {
            base = group.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        } else {
            base = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// - Parameter inMemory: tests use an in-memory store so they cannot disturb
    ///   the on-disk one, which holds the only copy of scheduling state.
    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: try storeURL())
        return try ModelContainer(
            for: schema,
            migrationPlan: RepeatMigrationPlan.self,
            configurations: configuration
        )
    }
}

extension ModelContext {
    /// Creates the `Card`s a note should have and removes the ones it should not,
    /// which is how a `reverse` flip is applied (§4.3). Removing a reverse card
    /// deletes the card; its `_log` rows are unaffected, by design.
    @discardableResult
    func syncCards(for note: Note, now: Date = .now) -> [Card] {
        let wanted = Set(note.expectedDirections)

        for card in note.cards where !wanted.contains(card.direction) {
            delete(card)
        }

        let existing = Set(note.cards.filter { wanted.contains($0.direction) }.map(\.direction))
        for direction in note.expectedDirections where !existing.contains(direction) {
            let card = Card(note: note, direction: direction, due: now)
            insert(card)
            note.cards.append(card)
        }

        return note.cards.filter { wanted.contains($0.direction) }
    }
}
