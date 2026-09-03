import Foundation
import SwiftData

/// A quick capture with no answer yet (§6.4). Written by the Share Extension into
/// the App Group container and ingested on next launch (§7.3).
@Model
final class InboxItem {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var sourceURL: String?

    init(id: UUID = UUID(), text: String, createdAt: Date = .now, sourceURL: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sourceURL = sourceURL
    }
}
