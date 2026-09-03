import Foundation

/// One quick capture as it crosses the App Group boundary (§7.3).
///
/// The Share Extension and the app share this file, so the format is defined
/// once rather than agreed twice. Deliberately plain: a `Codable` struct of
/// primitives, written as one JSON file per capture. The extension gets a few
/// hundred milliseconds and can be killed mid-write, and one file per capture
/// means a torn write costs that capture rather than the whole inbox.
public struct InboxDrop: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var sourceURL: String?

    /// Set when the sheet's "Save as card" was used: the deck chosen, and the
    /// answer typed. The extension cannot write to SwiftData — two processes
    /// opening the same store is not a risk worth taking for a capture — so the
    /// card is *described* here and created by the app on ingest.
    ///
    /// Both optional, so a drop written by an older build still decodes.
    public var deckTitle: String?
    public var back: String?

    /// A drop that names a deck and carries an answer is a finished card, not a
    /// note to self.
    public var isCard: Bool {
        guard let back, !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return deckTitle?.isEmpty == false
    }

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = .now,
        sourceURL: String? = nil,
        deckTitle: String? = nil,
        back: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.deckTitle = deckTitle
        self.back = back
    }

    /// `<id>.json`, so the file name alone identifies the capture and a repeated
    /// write of the same drop overwrites rather than duplicates.
    public var fileName: String { "\(id.uuidString).json" }

    public static let fileExtension = "json"

    /// Dates as ISO 8601: the two sides are separate processes, possibly built by
    /// different Xcode versions, and a floating-point interval is a poor thing to
    /// depend on across that boundary.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes the capture into the shared inbox. Used by the Share Extension
    /// (#28) and by the app's own tests.
    @discardableResult
    public func write(to directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
        return url
    }
}
