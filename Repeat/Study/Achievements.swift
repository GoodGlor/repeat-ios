import Foundation
import Scheduling
import SwiftData

/// M9 §5.4 — badges.
///
/// A badge is a fact about the log, the cards and the records, computed on
/// demand like `Streak.length` and `Records.make`. Nothing about "unlocked" is
/// stored: an undo that drops the count below the line takes the badge back,
/// and a rebuild from `_log` gives the same answer as the live path, because
/// both read the same rows. The one stored thing is the ledger of badges
/// already **shown** (`AchievementLedger`) — losing it means a badge is
/// celebrated twice, never that one is lost (spec §4).
enum Achievements {

    /// The catalogue (spec §8: fixed in code). The raw value is the ledger key
    /// and is never renamed. The Ukrainian name of each badge is UI copy and
    /// lives with the tiles (#108), not here.
    enum Badge: String, CaseIterable, Identifiable, Hashable {
        case firstSession = "first-session"
        case streak7 = "streak-7"
        case streak30 = "streak-30"
        case streak100 = "streak-100"
        case reviews100 = "reviews-100"
        case reviews1000 = "reviews-1000"
        case reviews10000 = "reviews-10000"
        case perfectSession = "perfect-session"
        case earlyBird = "early-bird"
        case nightOwl = "night-owl"
        case allDecksGreen = "all-decks-green"
        case words100 = "words-100"

        var id: String { rawValue }
    }

    /// Reviews closer together than this are one session. The log records no
    /// sessions, and a badge only `StudySession` could judge could not be
    /// re-derived after a rebuild — so a session is a run of reviews with no
    /// half-hour gap, judged from `reviewedAt` alone.
    static let sessionGap: TimeInterval = 30 * 60
    /// "Ідеальна сесія": this many reviews or more, none of them Again.
    static let perfectSessionMinimum = 10
    /// "Рання пташка": a session whose last review fell in this local window.
    /// The lower bound keeps a session that ran past midnight from counting
    /// as an early one — that session belongs to the owl.
    static let earlyBirdHours: Range<Int> = 4..<8
    /// "Сова": a session whose last review fell at or after this local hour…
    static let nightOwlFrom = 23
    /// …or before this one, the same night carried past midnight.
    static let nightOwlUntil = 4

    /// One real review. No card id: nothing in the catalogue asks which card.
    struct Review: Equatable {
        var at: Date
        var rating: Int
    }

    /// Everything a predicate may read, spec §3's `(decks, cards, logs, now,
    /// calendar)` reduced to the numbers the catalogue actually uses.
    /// `Facts.make` builds it from the store by query; tests build it by hand.
    struct Facts {
        /// Real reviews only (`rating != 0`), ascending by `at`.
        var reviews: [Review]
        var records: Records
        /// Notes with at least one known card (`Mastery.bucket == .known`).
        var knownWords: Int
        /// Decks not soft-deleted.
        var liveDecks: Int
        /// Cards due right now across live decks — `QueueBuilder`'s definition.
        var dueAnywhere: Int
        /// What Home says is owed today: the plan's count, due reviews plus
        /// today's new-card share. 0 is exactly "every deck row is green".
        var owedToday: Int
        var now: Date
        var calendar: Calendar
    }

    /// Runs of reviews with no gap of `sessionGap` or more. Sorted here.
    static func sessions(_ reviews: [Review]) -> [[Review]] {
        // `Facts.reviews` is documented ascending, but a negative interval would
        // merge everything into one session, so the sort is cheap insurance.
        let reviews = reviews.sorted { $0.at < $1.at }
        var sessions: [[Review]] = []
        for review in reviews {
            if let last = sessions.last?.last,
               review.at.timeIntervalSince(last.at) < sessionGap {
                sessions[sessions.count - 1].append(review)
            } else {
                sessions.append([review])
            }
        }
        return sessions
    }

    /// Every badge whose condition holds for these facts.
    static func unlocked(_ facts: Facts) -> Set<Badge> {
        let sessions = sessions(facts.reviews)
        func lastHour(_ session: [Review]) -> Int? {
            session.last.map { facts.calendar.component(.hour, from: $0.at) }
        }
        // Today's reviews are at the end of an ascending log.
        let studiedToday = facts.reviews.reversed().contains {
            facts.calendar.isDate($0.at, inSameDayAs: facts.now)
        }

        var unlocked: Set<Badge> = []
        for badge in Badge.allCases {
            let holds: Bool
            switch badge {
            case .firstSession:
                holds = !facts.reviews.isEmpty
            case .streak7:
                holds = facts.records.longestStreak >= 7
            case .streak30:
                holds = facts.records.longestStreak >= 30
            case .streak100:
                holds = facts.records.longestStreak >= 100
            case .reviews100:
                holds = facts.reviews.count >= 100
            case .reviews1000:
                holds = facts.reviews.count >= 1_000
            case .reviews10000:
                holds = facts.reviews.count >= 10_000
            case .perfectSession:
                holds = sessions.contains { session in
                    session.count >= perfectSessionMinimum
                        && !session.contains { $0.rating == Grade.again.rawValue }
                }
            case .earlyBird:
                holds = sessions.contains { lastHour($0).map(earlyBirdHours.contains) ?? false }
            case .nightOwl:
                holds = sessions.contains { session in
                    guard let hour = lastHour(session) else { return false }
                    return hour >= nightOwlFrom || hour < nightOwlUntil
                }
            case .allDecksGreen:
                holds = facts.liveDecks > 0 && facts.owedToday == 0 && facts.dueAnywhere == 0 && studiedToday
            case .words100:
                holds = facts.knownWords >= 100
            }
            if holds { unlocked.insert(badge) }
        }
        return unlocked
    }

    /// What evaluation found: everything unlocked now, and the part of it the
    /// owner has not been shown yet, in catalogue order.
    struct Evaluation: Equatable {
        var unlocked: Set<Badge>
        var fresh: [Badge]

        static let empty = Evaluation(unlocked: [], fresh: [])
    }

    /// Unlocked now, diffed against the ledger. Reads the ledger and writes
    /// nothing: evaluating is not showing, and the ledger is written by the
    /// surface that shows (#108's tiles, #109's notification).
    static func evaluate(facts: Facts, ledger: AchievementLedger) -> Evaluation {
        let unlocked = unlocked(facts)
        let shown = ledger.shown
        let fresh = Badge.allCases.filter { unlocked.contains($0) && !shown.contains($0.rawValue) }
        return Evaluation(unlocked: unlocked, fresh: fresh)
    }
}

extension Achievements.Facts {
    /// The facts from the store, **by query** (handoff gotcha 58: a relationship
    /// walk that is fast in a unit test is cold on the screen, and this runs on
    /// every `rebuildPlan()`).
    ///
    /// - `logs` is the whole log the caller already holds; undo markers are
    ///   dropped here so callers can pass what they fetched.
    /// - Known words: cards with `stability >= knownStability` and a review,
    ///   prefiltered in SQL with the two soft-delete joins, then
    ///   `Mastery.bucket` in memory (`SchedulingState` cannot be in a predicate),
    ///   counted as distinct notes.
    /// - Due anywhere: `QueueBuilder`'s definition of a due review, as a count.
    /// - `owedToday` is Home's plan count, supplied by the caller because the
    ///   plan is Home's, not the store's.
    static func make(in context: ModelContext, logs: [ReviewLog], owedToday: Int,
                     now: Date = .now, calendar: Calendar = .current) -> Achievements.Facts {
        let reviews = logs
            .filter { $0.rating != 0 }
            .map { Achievements.Review(at: $0.reviewedAt, rating: $0.rating) }
            .sorted { $0.at < $1.at }
        // #112: the same bridged definition Stats and Home use, or a badge for a
        // streak would disagree with the streak the app is showing.
        let records = Records.make(reviewDates: reviews.map(\.at),
                                   frozenDays: Freeze.days(in: context), calendar: calendar)

        // Spelled with `note.deck.deletedAt == nil`, the two predicates below
        // ran the compiler's type-checker out of its budget: five terms for the
        // due count (`!isSuspended && due <= now && lastReview != nil &&
        // note.deletedAt == nil && note.deck.deletedAt == nil`) and four for
        // the known words. Nothing general about nested optionals follows from
        // that — `Leech.all`'s four terms and `HomeSummary.cards(of:)`'s three
        // carry both nil hops and compile fine; it is the length of this chain
        // that did not. Testing deck liveness as `Set<String>.contains` is the
        // shape `QueueBuilder`'s own due predicate uses, and it is equivalent
        // to `deck.deletedAt == nil` because `Deck.sheetTitle` is
        // `@Attribute(.unique)`. The live decks' titles are fetched once
        // (cheap: decks are never in the thousands) and reused below.
        let liveDeckTitles = Set((try? context.fetch(FetchDescriptor<Deck>(
            predicate: #Predicate<Deck> { $0.deletedAt == nil }
        )))?.map(\.sheetTitle) ?? [])
        let liveDecks = liveDeckTitles.count

        // A count we could not take is not zero: 0 is the value that unlocks a badge.
        let dueAnywhere = (try? context.fetchCount(FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                !card.isSuspended
                    && card.due <= now
                    && card.lastReview != nil
                    && card.note.deletedAt == nil
                    && liveDeckTitles.contains(card.note.deck.sheetTitle)
            }
        ))) ?? .max

        let threshold = Mastery.knownStability
        let candidates = (try? context.fetch(FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                card.stability >= threshold
                    && card.lastReview != nil
                    && card.note.deletedAt == nil
                    && liveDeckTitles.contains(card.note.deck.sheetTitle)
            }
        ))) ?? []
        var knownNotes: Set<UUID> = []
        for card in candidates
        where Mastery.bucket(state: card.state, stability: card.stability, lastReview: card.lastReview) == .known {
            if let noteId = Card.noteId(inCardId: card.id) { knownNotes.insert(noteId) }
        }

        return Achievements.Facts(
            reviews: reviews, records: records, knownWords: knownNotes.count,
            liveDecks: liveDecks, dueAnywhere: dueAnywhere, owedToday: owedToday,
            now: now, calendar: calendar
        )
    }
}
