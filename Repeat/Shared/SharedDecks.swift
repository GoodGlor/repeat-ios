import Foundation

/// The deck list, published for the Share Extension (§7.3).
///
/// The extension needs a deck picker but cannot open SwiftData — two processes
/// on one SQLite store is not a risk worth taking for a quick capture, and the
/// extension is killed in seconds. The app publishes the titles; the extension
/// reads them.
public struct SharedDecks: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var colorHex: String
        public var id: String { title }

        public init(title: String, colorHex: String) {
            self.title = title
            self.colorHex = colorHex
        }
    }

    public var decks: [Entry]
    public var updatedAt: Date

    public init(decks: [Entry], updatedAt: Date = .now) {
        self.decks = decks
        self.updatedAt = updatedAt
    }

    public static var fileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("decks.json", isDirectory: false)
    }

    public static func read(from url: URL? = fileURL) -> SharedDecks? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedDecks.self, from: data)
    }

    @discardableResult
    public func write(to url: URL? = fileURL) throws -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        return true
    }
}
