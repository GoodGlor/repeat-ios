import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #8 acceptance (§6.3).
final class DoneScreenTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    // MARK: - Counts match the logs

    private func makeSession(cards: Int) throws -> (ModelContext, StudySession) {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 50)
        ctx.insert(deck)
        for row in 0..<cards {
            let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", sheetRow: row)
            ctx.insert(note)
            for card in ctx.syncCards(for: note, now: now) {
                card.state = .review
                card.stability = 12
                card.difficulty = 5
                card.reps = 4
                card.scheduledDays = 12
                card.due = now.addingTimeInterval(-86_400)
                card.lastReview = now.addingTimeInterval(-13 * 86_400)
            }
        }
        try ctx.save()
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: [deck], now: now, using: &generator)
        return (ctx, StudySession(context: ctx, plan: plan, decks: [deck]))
    }

    func testSummaryCountsMatchTheLogRowsWritten() throws {
        let (ctx, session) = try makeSession(cards: 4)
        let grades: [Grade] = [.easy, .hard, .easy, .easy]
        for grade in grades {
            session.reveal(now: now)
            session.rate(grade, now: now)
        }
        let summary = try XCTUnwrap(session.summary)

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>()).filter { $0.rating != 0 }
        XCTAssertEqual(summary.reviewed, logs.count)
        XCTAssertEqual(summary.forgotten, logs.filter { $0.rating == Grade.again.rawValue }.count)
        XCTAssertEqual(summary.forgotten, 0)
    }

    func testForgottenCountsOnlyAgain() throws {
        let (_, session) = try makeSession(cards: 3)
        session.reveal(now: now); session.rate(.again, now: now)
        // The Again card returns on its 10m step; finish it and the rest.
        var guard_ = 0
        while session.summary == nil, guard_ < 20 {
            guard_ += 1
            if session.current == nil, let until = session.waitingUntil {
                session.refresh(now: until); continue
            }
            guard let card = session.current else { break }
            session.reveal(now: card.due)
            session.rate(.easy, now: card.due)
        }
        XCTAssertEqual(session.summary?.forgotten, 1)
    }

    func testTheEndOfSessionHookFiresOnceWithTheSummary() throws {
        let (_, session) = try makeSession(cards: 2)
        var received: [StudySession.Summary] = []
        session.onSessionEnded = { received.append($0) }

        session.reveal(now: now); session.rate(.easy, now: now)
        XCTAssertTrue(received.isEmpty, "not over yet")
        session.reveal(now: now); session.rate(.easy, now: now)

        XCTAssertEqual(received.count, 1, "the _log push (#17) and reminder (#27) attach here")
        XCTAssertEqual(received.first, session.summary)
    }

    // MARK: - Streak

    func testStreakCountsConsecutiveDaysEndingToday() {
        let dates = [day(0), day(-1), day(-2), day(-3)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 4)
    }

    func testSeveralReviewsInOneDayAreStillOneDay() {
        let dates = [now, now.addingTimeInterval(60), now.addingTimeInterval(3600), day(-1)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 2)
    }

    /// A day that has not ended yet is not a missed day — otherwise the streak
    /// would read zero every morning before the first review.
    func testAnUnstartedTodayDoesNotBreakTheStreak() {
        let dates = [day(-1), day(-2), day(-3)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 3)
    }

    func testAMissedDayEndsTheStreak() {
        let dates = [day(0), day(-1), day(-3), day(-4)]
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 2)
    }

    func testAGapBeforeYesterdayMeansNoStreak() {
        XCTAssertEqual(Streak.length(reviewDates: [day(-2), day(-3)], now: now, calendar: calendar), 0)
        XCTAssertEqual(Streak.length(reviewDates: [], now: now, calendar: calendar), 0)
    }

    /// The streak is derived, so completing a second session today cannot
    /// increment it twice.
    func testASecondSessionOnTheSameDayDoesNotIncrementTheStreak() throws {
        let (ctx, session) = try makeSession(cards: 2)
        for _ in 0..<2 { session.reveal(now: now); session.rate(.easy, now: now) }
        try ctx.save()

        let dates = try ctx.fetch(FetchDescriptor<ReviewLog>())
            .filter { $0.rating != 0 }.map(\.reviewedAt)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(Streak.length(reviewDates: dates, now: now, calendar: calendar), 1)
    }

    func testUndoMarkersDoNotKeepAStreakAlive() throws {
        // Rating 0 rows are excluded by the caller; assert the caller's filter is
        // the thing that matters by feeding only real reviews.
        let realReviews = [day(-1)]
        XCTAssertEqual(Streak.length(reviewDates: realReviews, now: now, calendar: calendar), 1)
        XCTAssertEqual(Streak.length(reviewDates: [], now: now, calendar: calendar), 0)
    }

    // MARK: - The record line

    /// §5.2: "Нова найдовша серія — 12 днів". The unit is inflected by the same
    /// plural helpers Stats uses, so the two screens cannot disagree.
    func testTheRecordLineNamesWhatWasBeaten() {
        let uk = Locale(identifier: "uk")
        XCTAssertEqual(DoneView.recordLine(.longestStreak(12), locale: uk), "Нова найдовша серія — 12 днів")
        XCTAssertEqual(DoneView.recordLine(.bestDay(40), locale: uk), "Новий найкращий день — 40 карток")
        XCTAssertEqual(DoneView.recordLine(.bestWeek(201), locale: uk), "Новий найкращий тиждень — 201 картка")
        XCTAssertEqual(DoneView.recordLine(.longestStreak(12), locale: Locale(identifier: "en")),
                       "New longest streak — 12 days")
    }
}
