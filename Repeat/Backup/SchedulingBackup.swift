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
    static let currentVersion = 1

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
