import Foundation
import OSLog

/// SwiftData's own diagnosis of the 2026-09-04 crash, made assertable.
///
/// A `ModelContext` is bound to the queue that created it, and the first time it
/// is touched anywhere else SwiftData logs *"Unbinding from the main queue …"*.
/// That line, on the main context, is what three crash reports from the owner's
/// phone amounted to. The log store is read back rather than a thread probed
/// because most of the code under test goes through the Sheets client, whose own
/// executor hops are legitimate; only the **context's** thread is the question.
enum OffQueue {
    static func uses(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // `position(date:)` is a hint, not a cut: in a full run it handed back the
        // previous class's entries. The date on each entry is exact.
        return try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start && $0.composedMessage.contains("Unbinding from the main queue") }
            .map { "\($0.date)  \($0.composedMessage)" }
    }
}
