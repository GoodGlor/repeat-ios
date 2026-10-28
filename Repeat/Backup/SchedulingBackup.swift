import Foundation
import Scheduling

/// A nightly snapshot of every card's scheduling state (§8, recovery path 1).
///
/// The phone holds the only copy of scheduling state, so this file is what makes
/// losing it survivable. It carries `CardSchedulingSnapshot` rather than a
/// backup-specific struct, deliberately: that type already has a deterministic
/// encoding, and `Card.restore(from:)` is already the single write-back path used
/// by rating and undo. Sharing them means "undo restores exactly" and "a restored
/// backup reproduces every due date exactly" are the same claim, tested once.
struct SchedulingBackup: Codable, Equatable {
    /// Bumped when the shape changes. `decode` refuses a version it does not
    /// know rather than silently restoring garbage onto real scheduling state.
    ///
    /// **2** since #112 added `frozenDays`. The guard below is `<=`, so every
    /// backup already on disk still restores — it simply restores no freezes,
    /// which is the truth about a backup taken before they existed.
    static let currentVersion = 2

    struct Entry: Codable, Equatable {
        /// `Card.id` — the Sheet's row id, which is what makes a restore
        /// survive the Sheet changing underneath it.
        let id: String
        let scheduling: CardSchedulingSnapshot
    }

    var version: Int = currentVersion
    var createdAt: Date
    /// Sorted by id. `.sortedKeys` orders object keys but says nothing about
    /// array order, and two backups of an unchanged store should be byte
    /// identical.
    var entries: [Entry]
    /// Days a `StreakFreeze` covers (#112), sorted for the same reason `entries`
    /// is. Defaulted so a version 1 backup decodes as one with no freezes rather
    /// than failing — the store is the only copy of scheduling state, and a
    /// backup that will not open is no backup.
    var frozenDays: [Date] = []

    var cardCount: Int { entries.count }

    enum BackupError: Error, Equatable, CustomStringConvertible {
        case unsupportedVersion(Int)

        var description: String {
            switch self {
            case .unsupportedVersion(let version):
                Localized.string("Ця копія створена новішою версією застосунку (формат \(version)).")
            }
        }
    }

    // MARK: - Coding

    /// Matches `CardSchedulingSnapshot.encoded()` exactly — including the
    /// *absence* of a date strategy. `.iso8601` truncates to whole seconds, which
    /// would move a restored `due` by up to a second and break the acceptance
    /// line this whole card exists for.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decoded(from data: Data) throws -> SchedulingBackup {
        let backup = try JSONDecoder().decode(SchedulingBackup.self, from: data)
        guard backup.version <= currentVersion else {
            throw BackupError.unsupportedVersion(backup.version)
        }
        return backup
    }
}

extension SchedulingBackup {
    /// Written out rather than synthesized, and this is not a style choice: a
    /// synthesized `init(from:)` **ignores the property's default** and throws
    /// `keyNotFound` instead. `frozenDays = []` above therefore did nothing for
    /// the case it exists for, and every backup already on the owner's phone —
    /// all of them written before #112 — would have failed to open. Caught by
    /// `testABackupWrittenBeforeFreezesExistedStillOpens`.
    ///
    /// In an extension so the memberwise initialiser survives.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        entries = try container.decode([Entry].self, forKey: .entries)
        frozenDays = try container.decodeIfPresent([Date].self, forKey: .frozenDays) ?? []
    }
}
