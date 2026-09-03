import Foundation
import SwiftData

/// One worksheet in the spreadsheet (§3.1). Tabs prefixed with `_` are reserved
/// and never become decks.
@Model
final class Deck {
    /// Worksheet name. Unique because the Sheet cannot hold two tabs by one name.
    @Attribute(.unique) var sheetTitle: String
    /// The tab's `gid`, used for range addressing. Survives a rename, which is why
    /// renaming a tab in Sheets does not lose scheduling state.
    var sheetId: Int
    var colorHex: String
    var newCardsPerDay: Int
    var sortOrder: Int

    /// Set when the tab disappears from the Sheet. Notes are kept for 30 days so a
    /// tab deleted by accident can be recovered (§4.3).
    var deletedAt: Date?

    /// Speak the answer automatically when it is revealed (§6.3). Stored per
    /// deck because a vocabulary deck wants it and a formulas deck does not.
    /// The speaking itself is #31; this is the switch it reads.
    ///
    /// Defaulted, not optional: SwiftData's lightweight migration can add a
    /// column to an existing store only if it knows what to put in the rows that
    /// are already there. A mandatory attribute with no default fails the
    /// migration outright, which for this app means losing the only copy of the
    /// scheduling state.
    var autoTTS: Bool = false

    /// Ask for the answer to be typed rather than self-graded (§6.3). #32
    /// implements the input and the diff; this is the switch it reads.
    var typeAnswer: Bool = false

    /// Why the deck was skipped on the last pull — a missing `front`/`back` column,
    /// or duplicate headers (§4.6). Surfaces under "Needs attention" on Home.
    var malformedReason: String?

    @Relationship(deleteRule: .cascade, inverse: \Note.deck)
    var notes: [Note] = []

    init(
        sheetTitle: String,
        sheetId: Int,
        colorHex: String = "#1F7A5C",
        newCardsPerDay: Int = 15,
        sortOrder: Int = 0,
        autoTTS: Bool = false,
        typeAnswer: Bool = false
    ) {
        self.sheetTitle = sheetTitle
        self.sheetId = sheetId
        self.colorHex = colorHex
        self.newCardsPerDay = newCardsPerDay
        self.sortOrder = sortOrder
        self.autoTTS = autoTTS
        self.typeAnswer = typeAnswer
    }
}
