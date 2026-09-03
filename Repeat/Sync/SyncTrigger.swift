import Foundation

/// Which parts of a sync a trigger asks for (§4.2).
///
/// The trigger list is not "run everything, more or less often": two of the five
/// triggers are deliberately narrow. A card edit pushes without pulling, so
/// typing in the app cannot pull an unrelated 5 000-row sheet; a finished session
/// pushes `_log` only, so the reward for studying is not a full sync.
struct SyncWork: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let pull = SyncWork(rawValue: 1 << 0)
    static let push = SyncWork(rawValue: 1 << 1)
    static let log = SyncWork(rawValue: 1 << 2)

    static let everything: SyncWork = [.pull, .push, .log]
    /// §4.2 trigger 3: "push only" — notes, not `_log`. The log has its own
    /// trigger, and draining it here would make every keystroke's debounce
    /// window a candidate for a 500-row upload.
    static let notesOnly: SyncWork = [.push]
    /// §4.2 trigger 4: "push `_log`".
    static let logOnly: SyncWork = [.log]
}

/// The five triggers of §4.2, plus the one the spec implies: coming back online.
enum SyncTrigger: String, CaseIterable, Sendable {
    /// App became active. The only throttled trigger.
    case appActive
    /// Pull-to-refresh on Home — explicitly exempt from the throttle (§4.2).
    case pullToRefresh
    /// A card was created or edited. Debounced 3 s by the coordinator.
    case contentEdited
    /// A study session ended.
    case sessionEnded
    /// `BGAppRefreshTask`, once a day if the app hasn't been opened.
    case backgroundRefresh
    /// The network came back. §4.5 promises the queue drains on reconnect, which
    /// needs a trigger of its own — none of the other five fires on its own when
    /// a phone leaves airplane mode.
    case reconnected

    var work: SyncWork {
        switch self {
        case .appActive, .pullToRefresh, .backgroundRefresh, .reconnected: .everything
        case .contentEdited: .notesOnly
        case .sessionEnded: .logOnly
        }
    }

    /// §4.2: "not more than once per 10 min unless pull-to-refresh".
    var throttleInterval: TimeInterval? {
        self == .appActive ? 10 * 60 : nil
    }

    /// §4.2 trigger 3 is debounced 3 s — a burst of keystrokes in the editor is
    /// one edit, not twenty.
    var debounceInterval: TimeInterval? {
        self == .contentEdited ? 3 : nil
    }
}
