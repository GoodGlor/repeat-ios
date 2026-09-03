import Foundation
import SwiftData
import Scheduling

/// The live session queue (§5.2).
///
/// Holds the plan's order and handles the one thing a static list cannot: learning
/// cards whose intra-day timer expires mid-session come back, while cards due
/// later today stay out. That distinction is what keeps a session from either
/// dropping half-learned material or never ending.
@Observable
final class StudyQueue {
    private(set) var plan: QueuePlan
    /// Ids not yet answered this pass, in order.
    private(set) var pending: [String]
    /// Learning and relearning cards answered this session, waiting for their timer.
    private(set) var waiting: [(id: String, readyAt: Date)] = []
    private(set) var answered: [String] = []

    /// Total the progress bar counts against — the plan's size, not including
    /// re-shown learning cards, so the bar advances monotonically (§6.3).
    let total: Int

    init(plan: QueuePlan) {
        self.plan = plan
        self.pending = plan.cardIds
        self.total = plan.cardIds.count
    }

    var completedCount: Int { answered.count }
    var isFinished: Bool { pending.isEmpty && waiting.isEmpty }

    /// The next card id to show, promoting any learning card whose timer has come
    /// due. Returns `nil` when the session is over — or when everything left is
    /// still waiting, which the caller shows as a short pause rather than an end.
    func next(now: Date = .now) -> String? {
        promoteReadyCards(now: now)
        return pending.first
    }

    /// When the earliest waiting card becomes available, if the queue is otherwise
    /// empty. `nil` means nothing is waiting.
    func nextAvailableAt() -> Date? {
        waiting.map(\.readyAt).min()
    }

    /// Records an answer. A card that is still learning goes back into the waiting
    /// set for its own due time; anything else leaves the session.
    func recordAnswer(cardId: String, resultingState: SchedulingState, nextDue: Date, now: Date = .now) {
        pending.removeAll { $0 == cardId }
        waiting.removeAll { $0.id == cardId }
        if !answered.contains(cardId) { answered.append(cardId) }

        let staysInSession = (resultingState == .learning || resultingState == .relearning)
            && Calendar.current.isDate(nextDue, inSameDayAs: now)
        if staysInSession {
            waiting.append((id: cardId, readyAt: nextDue))
        }
    }

    /// Takes a card out of the session for good — used when a rating turns it
    /// into a leech (§5.4).
    ///
    /// It stays in `answered`, because it *was* answered and the progress bar
    /// must not run backwards. Only its future in this session is removed.
    func drop(cardId: String) {
        pending.removeAll { $0 == cardId }
        waiting.removeAll { $0.id == cardId }
    }

    /// Puts a card back at the front — used by undo (§5.5).
    func reinsertAtFront(cardId: String) {
        pending.removeAll { $0 == cardId }
        waiting.removeAll { $0.id == cardId }
        answered.removeAll { $0 == cardId }
        pending.insert(cardId, at: 0)
    }

    private func promoteReadyCards(now: Date) {
        let ready = waiting.filter { $0.readyAt <= now }
        guard !ready.isEmpty else { return }
        waiting.removeAll { $0.readyAt <= now }
        // Learning cards go to the front: they are the material the session is
        // actively trying to fix in memory, and delaying them defeats the step.
        pending.insert(contentsOf: ready.map(\.id), at: 0)
    }
}
