import Foundation
import SwiftData
import Scheduling
import Observation

/// Drives one study session (§6.3): owns the queue, the scheduler and the store
/// writes, so the view stays a rendering of this state rather than a second copy
/// of the rules.
@Observable
final class StudySession {
    /// Set once the last card is answered; the Done screen (#8) reads it.
    struct Summary: Equatable {
        var reviewed: Int
        var forgotten: Int
    }

    private let context: ModelContext
    private let scheduler: Scheduler
    private let queue: StudyQueue
    private var cardsById: [String: Card]

    private(set) var current: Card?
    private(set) var isRevealed = false
    private(set) var previews: [Grade: GradePreview] = [:]
    private(set) var summary: Summary?
    /// Set when everything left is a learning card whose timer has not expired.
    private(set) var waitingUntil: Date?

    var total: Int { queue.total }
    var completed: Int { queue.completedCount }
    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    /// 1-based position for the `n / total` counter.
    var position: Int { min(completed + 1, max(total, 1)) }

    private var reviewed = 0
    private var forgotten = 0

    /// The one rating that can be taken back. §5.5 offers undo for *the last*
    /// rating, not a history, so this is a single slot rather than a stack —
    /// which also keeps `_log` from accumulating undo markers for undos.
    private(set) var undoableLog: ReviewLog?
    var canUndo: Bool { undoableLog != nil }

    /// Set for one rating when the card just became a leech, so the screen can
    /// say what happened. §5.4 takes a card away mid-session, and doing that
    /// silently looks like a bug.
    private(set) var becameLeech: String?

    /// Runs when the session ends. §6.3 hangs two things off this moment: the
    /// `_log` push (#17) and scheduling tomorrow's reminder (#27). Neither exists
    /// yet; this is the seam they attach to, so the trigger is defined in one
    /// place rather than rediscovered twice.
    var onSessionEnded: ((Summary) -> Void)?

    /// §5.4's threshold, from Settings. Held rather than read each time so a
    /// session grades against one definition from start to finish.
    private let leechThreshold: Int

    init(
        context: ModelContext,
        scheduler: Scheduler = Scheduler(),
        plan: QueuePlan,
        decks: [Deck],
        leechThreshold: Int = AppSettings.defaultLeechThreshold
    ) {
        self.context = context
        self.scheduler = scheduler
        self.leechThreshold = leechThreshold
        self.queue = StudyQueue(plan: plan)
        self.cardsById = Dictionary(
            uniqueKeysWithValues: decks
                .flatMap(\.notes).flatMap(\.cards)
                .map { ($0.id, $0) }
        )
        advance()
    }

    // MARK: - Interaction

    func reveal(now: Date = .now) {
        guard !isRevealed, let card = current else { return }
        isRevealed = true
        previews = (try? scheduler.preview(for: card.snapshot, now: now)) ?? [:]
        Haptics.reveal()
    }

    /// Rates the current card. Ignored before reveal — §6.3 requires the buttons
    /// to be unreachable until the answer has been seen, so an accidental tap
    /// cannot grade a card the user never read.
    func rate(_ grade: Grade, now: Date = .now) {
        guard isRevealed, let card = current else { return }
        becameLeech = nil

        guard let log = try? context.rate(card, grade, with: scheduler, now: now) else { return }
        undoableLog = log

        if grade == .again { forgotten += 1; Haptics.again() }
        reviewed += 1

        queue.recordAnswer(
            cardId: card.id, resultingState: card.state, nextDue: card.due, now: now
        )

        // §5.4: "a card crossing the threshold leaves the queue immediately" —
        // this session, not the next one. Marked after `recordAnswer`, which
        // would otherwise put a relearning card straight back into `waiting`.
        if Leech.markIfNeeded(card, threshold: leechThreshold) {
            queue.drop(cardId: card.id)
            becameLeech = card.id
        }

        try? context.save()
        advance(now: now)
    }

    /// Takes back the last rating (§5.5).
    ///
    /// Restores the card's scheduling from the snapshot the log carries, puts the
    /// card back at the front of the queue and rewinds the session counters. If
    /// the session had just ended, it reopens — otherwise the last card of a
    /// session would be the one card that could never be corrected.
    @discardableResult
    func undo(now: Date = .now) -> Bool {
        guard let log = undoableLog,
              let card = cardsById[log.cardId],
              let previous = try? log.decodedPrevState()
        else { return false }

        card.restore(from: previous)
        // `restore` puts back the lapse count and the suspension the snapshot
        // carried, so an undone rating also undoes the leech mark. The queue has
        // to hear about it too, or the card would stay dropped.
        becameLeech = nil

        if log.uploaded {
            // Already in the Sheet, so the row cannot be withdrawn. §5.5 records
            // the reversal as its own row instead; rating 0 is not a grade, and
            // replay (#41) skips it.
            let marker = try? ReviewLog(
                cardId: log.cardId,
                direction: log.direction,
                rating: 0,
                reviewedAt: now,
                elapsedDays: log.elapsedDays,
                scheduledDays: log.scheduledDays,
                stateBefore: log.stateBefore,
                prevState: previous
            )
            if let marker { context.insert(marker) }
        } else {
            context.delete(log)
        }

        if log.rating == Grade.again.rawValue { forgotten = max(0, forgotten - 1) }
        reviewed = max(0, reviewed - 1)

        queue.reinsertAtFront(cardId: log.cardId)
        undoableLog = nil
        summary = nil
        try? context.save()
        advance(now: now)
        return true
    }

    /// Re-checks the queue — the view calls this when a learning card's timer is
    /// due, so a session waiting on a `10m` step resumes on its own.
    func refresh(now: Date = .now) {
        guard current == nil, summary == nil else { return }
        advance(now: now)
    }

    // MARK: - Queue

    private func advance(now: Date = .now) {
        isRevealed = false
        previews = [:]

        if let id = queue.next(now: now), let card = cardsById[id] {
            current = card
            waitingUntil = nil
            return
        }

        current = nil
        if queue.isFinished {
            waitingUntil = nil
            let summary = Summary(reviewed: reviewed, forgotten: forgotten)
            self.summary = summary
            onSessionEnded?(summary)
        } else {
            // Nothing to show yet, but learning cards are still pending.
            waitingUntil = queue.nextAvailableAt()
        }
    }
}

/// So a live session can drive `fullScreenCover(item:)`. Identity is the object
/// itself: a session is inherently one-of-a-kind and outlives no presentation.
extension StudySession: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}
