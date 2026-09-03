import Foundation

/// The words on Home's sync line (§4.2, §6.2).
///
/// Separated from the view because the interesting part is not the layout — it
/// is that the line reports the last *successful* sync. A phone that has been
/// failing to reach Google for an hour must still say "synced an hour ago", not
/// "synced just now" because it tried a second ago.
enum SyncStatusFormatter {
    enum Tone: Equatable {
        case normal
        /// Nothing is wrong; the work is simply waiting.
        case waiting
        /// The owner has to do something (§4.6).
        case attention
    }

    struct Line: Equatable {
        var text: String
        var symbol: String
        var tone: Tone = .normal
        /// Whether tapping should open Settings (§4.6's auth banner).
        var linksToSettings = false
    }

    static func line(
        status: SyncCoordinator.Status,
        lastSyncedAt: Date?,
        now: Date = .now
    ) -> Line {
        switch status {
        case .syncing:
            return Line(text: Localized.string("Синхронізація…"), symbol: "arrow.triangle.2.circlepath")
        case .notConfigured:
            return Line(text: Localized.string("Google Таблицю не підключено"), symbol: "link.badge.plus",
                        tone: .attention, linksToSettings: true)
        case .offline:
            // The queue is safe and the owner needs no action, so this is
            // deliberately not an error tone.
            return Line(text: Localized.string("Офлайн — зміни синхронізуються пізніше"),
                        symbol: "wifi.slash", tone: .waiting)
        case .failed(let message, let needsAttention):
            return Line(text: needsAttention ? message : Localized.string("Не вдалося синхронізувати — спробуємо ще раз"),
                        symbol: "exclamationmark.triangle",
                        tone: .attention, linksToSettings: needsAttention)
        case .idle:
            guard let lastSyncedAt else {
                return Line(text: Localized.string("Ще не синхронізовано"), symbol: "clock", tone: .waiting)
            }
            return Line(text: Localized.string("Синхронізовано \(elapsed(since: lastSyncedAt, now: now))"),
                        symbol: "checkmark.circle")
        }
    }

    /// Deliberately coarse, and in abbreviated units.
    ///
    /// `хв / год / дн` do not inflect, which keeps this line clear of Ukrainian
    /// plural agreement until the localisation catalog (#38) can handle it
    /// properly. A sync line is glanced at, never read.
    static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return Localized.string("щойно")
        case ..<3600: return Localized.string("\(Int(seconds / 60)) хв тому")
        case ..<86_400: return Localized.string("\(Int(seconds / 3600)) год тому")
        default: return Localized.string("\(Int(seconds / 86_400)) дн тому")
        }
    }
}
