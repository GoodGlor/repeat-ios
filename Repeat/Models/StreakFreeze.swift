import Foundation
import SwiftData

/// A day the streak survived without a review (§4, second exception).
///
/// The only piece of gamification this app stores rather than derives. It has to
/// be stored because it **changes what `Streak.length` returns**: nothing in
/// `_log` records a day on which nothing happened, so a rebuild from the log
/// could not tell a frozen day from a broken one.
///
/// Everything else about freezes is still derived — how many have been earned is
/// `reviewDays.count / Freeze.daysPerFreeze`, and how many are left is that minus
/// the rows here. Only the irreducible fact is written down.
@Model
final class StreakFreeze {
    /// Start of the covered day. Unique, which is what makes settling twice a
    /// no-op at the store level rather than only in the code that calls it.
    @Attribute(.unique) var day: Date
    var spentAt: Date
    /// `nil` until the Done screen has named it. This mirrors what
    /// `AchievementLedger` does for badges, but on the row itself — there is
    /// already a stored row here, so it needs no second mechanism, and unlike the
    /// ledger it is worth keeping, since re-announcing a freeze is a lie about
    /// today rather than a harmless repeat.
    var announcedAt: Date?

    init(day: Date, spentAt: Date, announcedAt: Date? = nil) {
        self.day = day
        self.spentAt = spentAt
        self.announcedAt = announcedAt
    }
}
