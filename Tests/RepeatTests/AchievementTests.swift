import XCTest
import Scheduling
@testable import Repeat

/// M9 §5.4 — twelve badges, each a pure predicate over the log, the cards and
/// the records. Every test here builds `Facts` by hand with fixed dates in
/// January 2027 and a fixed Kyiv calendar, and every badge is tested on both
/// sides of its line, the way the card's acceptance asks.
final class AchievementTests: XCTestCase {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// A moment in January 2027, Kyiv time.
    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    /// `count` good reviews one minute apart, starting at `start`.
    private func run(_ count: Int, from start: Date, rating: Int = Grade.good.rawValue) -> [Achievements.Review] {
        (0..<count).map { Achievements.Review(at: start.addingTimeInterval(Double($0) * 60), rating: rating) }
    }

    /// One review a day for `days` days ending on `lastDay` of January, at 12:00.
    /// Counted back with calendar arithmetic, so a run that starts before
    /// January (streak 100) is still one review per calendar day.
    private func daily(_ days: Int, endingOn lastDay: Int) -> [Achievements.Review] {
        let end = at(day: lastDay, hour: 12)
        return (0..<days).map { offset in
            let day = Self.calendar.date(byAdding: .day, value: offset - (days - 1), to: end)!
            return Achievements.Review(at: day, rating: Grade.good.rawValue)
        }
    }

    private func facts(
        reviews: [Achievements.Review], knownWords: Int = 0, liveDecks: Int = 1,
        dueAnywhere: Int = 5, owedToday: Int = 0, now: Date? = nil
    ) -> Achievements.Facts {
        let sorted = reviews.sorted { $0.at < $1.at }
        return Achievements.Facts(
            reviews: sorted,
            records: Records.make(reviewDates: sorted.map(\.at), calendar: Self.calendar),
            knownWords: knownWords, liveDecks: liveDecks, dueAnywhere: dueAnywhere,
            owedToday: owedToday,
            now: now ?? sorted.last?.at ?? at(day: 15, hour: 12),
            calendar: Self.calendar
        )
    }

    private func unlocked(_ facts: Achievements.Facts) -> Set<Achievements.Badge> {
        Achievements.unlocked(facts)
    }

    // MARK: - The catalogue

    func testTheCatalogueHasTwelveBadgesWithStableAsciiIds() {
        XCTAssertEqual(Achievements.Badge.allCases.count, 12)
        for badge in Achievements.Badge.allCases {
            XCTAssertTrue(badge.rawValue.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                          "\(badge.rawValue) is not a stable ledger key")
        }
        XCTAssertEqual(Set(Achievements.Badge.allCases.map(\.rawValue)).count, 12, "ids collide")
    }

    func testNothingIsUnlockedOnAFreshInstall() {
        XCTAssertEqual(unlocked(facts(reviews: [], liveDecks: 0, dueAnywhere: 0)), [])
    }

    // MARK: - Sessions are runs of reviews with no half-hour gap

    func testReviewsLessThanThirtyMinutesApartAreOneSession() {
        let reviews = run(3, from: at(day: 15, hour: 12)) + run(2, from: at(day: 15, hour: 12, minute: 31))
        XCTAssertEqual(Achievements.sessions(reviews).map(\.count), [5])
    }

    func testAThirtyMinuteGapStartsANewSession() {
        let reviews = run(3, from: at(day: 15, hour: 12)) + run(2, from: at(day: 15, hour: 12, minute: 32))
        XCTAssertEqual(Achievements.sessions(reviews).map(\.count), [3, 2])
    }

    func testSessionsOfNoReviewsAreNoSessions() {
        XCTAssertEqual(Achievements.sessions([]).count, 0)
    }

    // MARK: - Перша сесія

    func testTheFirstReviewUnlocksTheFirstSession() {
        XCTAssertTrue(unlocked(facts(reviews: run(1, from: at(day: 15, hour: 12)))).contains(.firstSession))
    }

    func testNoReviewsMeansNoFirstSession() {
        XCTAssertFalse(unlocked(facts(reviews: [])).contains(.firstSession))
    }

    // MARK: - Серія 7 · 30 · 100 — the longest streak ever

    func testSevenDaysInARowUnlocksStreakSeven() {
        XCTAssertTrue(unlocked(facts(reviews: daily(7, endingOn: 20))).contains(.streak7))
    }

    func testSixDaysInARowDoesNot() {
        XCTAssertFalse(unlocked(facts(reviews: daily(6, endingOn: 20))).contains(.streak7))
    }

    func testSevenDaysWithAGapIsNotAStreakOfSeven() {
        let reviews = daily(4, endingOn: 14) + daily(3, endingOn: 19)   // days 15 and 16 empty
        XCTAssertFalse(unlocked(facts(reviews: reviews)).contains(.streak7))
    }

    func testAStreakBrokenSinceStillCounts() {
        // Seven days ending on the 10th, nothing since: the badge is about the
        // longest streak, not the current one.
        let reviews = daily(7, endingOn: 10)
        XCTAssertTrue(unlocked(facts(reviews: reviews, now: at(day: 20, hour: 12))).contains(.streak7))
    }

    func testThirtyDaysUnlocksStreakThirtyAndTwentyNineDoesNot() {
        XCTAssertTrue(unlocked(facts(reviews: daily(30, endingOn: 31))).contains(.streak30))
        XCTAssertFalse(unlocked(facts(reviews: daily(29, endingOn: 31))).contains(.streak30))
    }

    func testAHundredDaysUnlocksStreakHundredAndNinetyNineDoesNot() {
        // 100 days back from 31 January is October 2026, across a DST change;
        // `daily` counts calendar days, so only the count matters here.
        XCTAssertTrue(unlocked(facts(reviews: daily(100, endingOn: 31))).contains(.streak100))
        XCTAssertFalse(unlocked(facts(reviews: daily(99, endingOn: 31))).contains(.streak100))
    }

    // MARK: - 100 · 1 000 · 10 000 повторень — reviews, repeats included

    func testAHundredReviewsUnlocksAndNinetyNineDoesNot() {
        XCTAssertTrue(unlocked(facts(reviews: run(100, from: at(day: 15, hour: 12)))).contains(.reviews100))
        XCTAssertFalse(unlocked(facts(reviews: run(99, from: at(day: 15, hour: 12)))).contains(.reviews100))
    }

    func testAThousandReviewsUnlocksAndNineHundredNinetyNineDoesNot() {
        XCTAssertTrue(unlocked(facts(reviews: run(1_000, from: at(day: 15, hour: 12)))).contains(.reviews1000))
        XCTAssertFalse(unlocked(facts(reviews: run(999, from: at(day: 15, hour: 12)))).contains(.reviews1000))
    }

    func testTenThousandReviewsUnlocksAndOneFewerDoesNot() {
        XCTAssertTrue(unlocked(facts(reviews: run(10_000, from: at(day: 15, hour: 12)))).contains(.reviews10000))
        XCTAssertFalse(unlocked(facts(reviews: run(9_999, from: at(day: 15, hour: 12)))).contains(.reviews10000))
    }

    // MARK: - Ідеальна сесія — ten or more, none forgotten

    func testTenGoodReviewsInOneSessionArePerfect() {
        XCTAssertTrue(unlocked(facts(reviews: run(10, from: at(day: 15, hour: 12)))).contains(.perfectSession))
    }

    func testNineGoodReviewsAreNotEnough() {
        XCTAssertFalse(unlocked(facts(reviews: run(9, from: at(day: 15, hour: 12)))).contains(.perfectSession))
    }

    func testOneAgainSpoilsTheSession() {
        var reviews = run(10, from: at(day: 15, hour: 12))
        reviews[4].rating = Grade.again.rawValue
        XCTAssertFalse(unlocked(facts(reviews: reviews)).contains(.perfectSession))
    }

    func testHardIsNotAgain() {
        XCTAssertTrue(unlocked(facts(reviews: run(10, from: at(day: 15, hour: 12), rating: Grade.hard.rawValue))).contains(.perfectSession))
    }

    func testTenGoodReviewsSplitAcrossTwoSessionsAreNotPerfect() {
        let reviews = run(5, from: at(day: 15, hour: 12)) + run(5, from: at(day: 15, hour: 14))
        XCTAssertFalse(unlocked(facts(reviews: reviews)).contains(.perfectSession))
    }

    func testAnEarlierSpoiledSessionDoesNotHideALaterPerfectOne() {
        var spoiled = run(10, from: at(day: 14, hour: 12))
        spoiled[0].rating = Grade.again.rawValue
        let reviews = spoiled + run(10, from: at(day: 15, hour: 12))
        XCTAssertTrue(unlocked(facts(reviews: reviews)).contains(.perfectSession))
    }

    // MARK: - Рання пташка · сова — when a session ended

    func testASessionThatEndedBeforeEightIsAnEarlyBird() {
        XCTAssertTrue(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 7, minute: 40)))).contains(.earlyBird))
    }

    func testASessionThatEndedAtEightIsNot() {
        // Starts 07:58, three reviews a minute apart, last at 08:00.
        XCTAssertFalse(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 7, minute: 58)))).contains(.earlyBird))
    }

    func testASessionThatStartedEarlyButEndedLateIsNotAnEarlyBird() {
        // 07:45 to 08:20, no gap: one session, ended after eight.
        XCTAssertFalse(unlocked(facts(reviews: run(36, from: at(day: 15, hour: 7, minute: 45)))).contains(.earlyBird))
    }

    func testASessionThatEndedAtTwentyThreeIsANightOwl() {
        XCTAssertTrue(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 22, minute: 58)))).contains(.nightOwl))
    }

    func testASessionThatEndedAtTwentyTwoFiftyNineIsNot() {
        XCTAssertFalse(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 22, minute: 57)))).contains(.nightOwl))
    }

    func testTheHourIsLocalToTheCalendar() {
        // 07:40 Kyiv is 05:40 UTC. In a UTC calendar the same instant is still
        // early; the point is that `facts.calendar` decides, not the device.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var facts = self.facts(reviews: run(3, from: at(day: 15, hour: 7, minute: 40)))
        facts.calendar = utc
        XCTAssertTrue(unlocked(facts).contains(.earlyBird))
        // 09:30 Kyiv is 07:30 UTC: early in UTC, not in Kyiv.
        var later = self.facts(reviews: run(3, from: at(day: 15, hour: 9, minute: 30)))
        XCTAssertFalse(unlocked(later).contains(.earlyBird))
        later.calendar = utc
        XCTAssertTrue(unlocked(later).contains(.earlyBird))
    }

    func testASessionThatRanPastMidnightIsAnOwlNotABird() {
        // 23:40 to 00:10, no gap: one session whose last review is at hour 0.
        let reviews = run(31, from: at(day: 15, hour: 23, minute: 40))
        let unlocked = unlocked(facts(reviews: reviews))
        XCTAssertTrue(unlocked.contains(.nightOwl))
        XCTAssertFalse(unlocked.contains(.earlyBird))
    }

    func testASessionThatEndedAtThreeFiftyNineIsStillAnOwl() {
        XCTAssertTrue(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 3, minute: 57)))).contains(.nightOwl))
    }

    func testASessionThatEndedAtFourIsABirdNotAnOwl() {
        // 03:58, 03:59, 04:00 — the last review is the one that decides.
        let unlocked = unlocked(facts(reviews: run(3, from: at(day: 15, hour: 3, minute: 58))))
        XCTAssertTrue(unlocked.contains(.earlyBird))
        XCTAssertFalse(unlocked.contains(.nightOwl))
    }

    // MARK: - Усі колоди зелені — nothing due anywhere, after today's session

    func testNothingDueAfterTodaysSessionIsAllGreen() {
        XCTAssertTrue(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 12)), dueAnywhere: 0)).contains(.allDecksGreen))
    }

    func testOneDueCardAnywhereIsNotGreen() {
        XCTAssertFalse(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 12)), dueAnywhere: 1)).contains(.allDecksGreen))
    }

    func testNothingDueButNoSessionTodayIsNotGreen() {
        let reviews = run(3, from: at(day: 14, hour: 12))
        XCTAssertFalse(unlocked(facts(reviews: reviews, dueAnywhere: 0, now: at(day: 15, hour: 12))).contains(.allDecksGreen))
    }

    func testANewCardStillPlannedTodayIsNotGreen() {
        // No review is due, but Home's plan still holds a new card for today,
        // so a deck row is showing a number.
        XCTAssertFalse(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 12)), dueAnywhere: 0, owedToday: 1)).contains(.allDecksGreen))
    }

    func testNoDecksAtAllIsNotGreen() {
        XCTAssertFalse(unlocked(facts(reviews: run(3, from: at(day: 15, hour: 12)), liveDecks: 0, dueAnywhere: 0)).contains(.allDecksGreen))
    }

    // MARK: - 100 слів вивчено

    func testAHundredKnownWordsUnlocksAndNinetyNineDoesNot() {
        XCTAssertTrue(unlocked(facts(reviews: run(1, from: at(day: 15, hour: 12)), knownWords: 100)).contains(.words100))
        XCTAssertFalse(unlocked(facts(reviews: run(1, from: at(day: 15, hour: 12)), knownWords: 99)).contains(.words100))
    }

    // MARK: - All at once

    func testAnUnremarkableDayUnlocksExactlyTheFirstSession() {
        let reviews = run(5, from: at(day: 15, hour: 12))
        XCTAssertEqual(unlocked(facts(reviews: reviews)), [.firstSession])
    }

    // MARK: - The ledger: the one stored thing

    private func freshDefaults() -> UserDefaults {
        let name = "AchievementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testALedgerStartsEmpty() {
        let ledger = AchievementLedger(defaults: freshDefaults())
        XCTAssertEqual(ledger.shownOn, [:])
        XCTAssertEqual(ledger.shown, [])
    }

    func testMarkingShownRecordsTheDayAndPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let day = at(day: 15, hour: 21)
        AchievementLedger(defaults: defaults).markShown([.firstSession, .streak7], on: day)

        let reread = AchievementLedger(defaults: defaults)
        XCTAssertEqual(reread.shownOn, ["first-session": day, "streak-7": day])
        XCTAssertEqual(reread.shown, ["first-session", "streak-7"])
    }

    func testTheFirstShowingKeepsItsDate() {
        let defaults = freshDefaults()
        let ledger = AchievementLedger(defaults: defaults)
        ledger.markShown([.firstSession], on: at(day: 10, hour: 21))
        ledger.markShown([.firstSession, .reviews100], on: at(day: 15, hour: 21))
        XCTAssertEqual(ledger.shownOn, ["first-session": at(day: 10, hour: 21),
                                        "reviews-100": at(day: 15, hour: 21)])
    }

    func testResetForgetsEverything() {
        let defaults = freshDefaults()
        let ledger = AchievementLedger(defaults: defaults)
        ledger.markShown([.firstSession])
        ledger.reset()
        XCTAssertEqual(AchievementLedger(defaults: defaults).shownOn, [:])
    }

    // MARK: - evaluate: unlocked now, and what is new

    func testEvaluateReportsEverythingUnlockedAndWhatIsFresh() {
        let ledger = AchievementLedger(defaults: freshDefaults())
        ledger.markShown([.firstSession])
        let facts = self.facts(reviews: run(10, from: at(day: 15, hour: 12)), dueAnywhere: 0)

        let evaluation = Achievements.evaluate(facts: facts, ledger: ledger)

        XCTAssertEqual(evaluation.unlocked, [.firstSession, .perfectSession, .allDecksGreen])
        XCTAssertEqual(evaluation.fresh, [.perfectSession, .allDecksGreen], "catalogue order, shown ones left out")
    }

    func testEvaluateWritesNothingToTheLedger() {
        let defaults = freshDefaults()
        let ledger = AchievementLedger(defaults: defaults)
        let facts = self.facts(reviews: run(10, from: at(day: 15, hour: 12)))

        let first = Achievements.evaluate(facts: facts, ledger: ledger)
        let second = Achievements.evaluate(facts: facts, ledger: ledger)

        XCTAssertEqual(first, second, "evaluating is not showing")
        XCTAssertEqual(ledger.shown, [])
    }

    func testAShownBadgeThatRelocksIsNeitherUnlockedNorFresh() {
        let ledger = AchievementLedger(defaults: freshDefaults())
        ledger.markShown([.reviews100])
        let facts = self.facts(reviews: run(99, from: at(day: 15, hour: 12)))

        let evaluation = Achievements.evaluate(facts: facts, ledger: ledger)

        XCTAssertFalse(evaluation.unlocked.contains(.reviews100))
        XCTAssertFalse(evaluation.fresh.contains(.reviews100))
        XCTAssertEqual(ledger.shown, ["reviews-100"], "the ledger remembers what was shown, whatever the log says now")
    }

    func testEmptyEvaluationIsEmpty() {
        XCTAssertEqual(Achievements.Evaluation.empty, Achievements.Evaluation(unlocked: [], fresh: []))
    }
}
