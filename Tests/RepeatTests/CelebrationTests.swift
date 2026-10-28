import XCTest
@testable import Repeat

/// §5.6 — what the Done screen adds this session: at most four lines since #112,
/// in a fixed order, and a badges line that never grows past three tiles.
final class CelebrationTests: XCTestCase {

    func testNothingApplyingIsNoLines() {
        XCTAssertEqual(Celebration.lines(goalClosed: false, record: nil, badges: []), [])
    }

    func testTheOrderIsGoalThenRecordThenBadges() {
        let lines = Celebration.lines(goalClosed: true, record: .bestDay(40), badges: [.firstSession])
        XCTAssertEqual(lines, [.goalClosed, .record(.bestDay(40)), .badges([.firstSession])])
    }

    /// #112 puts the freeze first. It is the only line reporting something that
    /// happened *to* the owner rather than something they did, and it explains a
    /// streak number that would otherwise look wrong.
    func testAFreezeIsNamedBeforeAnythingTheSessionEarned() {
        let lines = Celebration.lines(freezeSpent: true, goalClosed: true, levelGained: 2,
                                      record: .bestDay(40), badges: [.firstSession])
        XCTAssertEqual(lines.first, .freezeSpent)
        XCTAssertEqual(lines, [.freezeSpent, .goalClosed, .levelGained(2), .record(.bestDay(40)),
                               .badges([.firstSession])])
    }

    func testNoFreezeIsTheOrdinaryCase() {
        XCTAssertEqual(Celebration.lines(goalClosed: true, record: nil, badges: []), [.goalClosed])
        XCTAssertEqual(Celebration.lines(freezeSpent: false, goalClosed: false,
                                         record: nil, badges: []), [])
    }

    func testEachLineStandsAlone() {
        XCTAssertEqual(Celebration.lines(goalClosed: true, record: nil, badges: []), [.goalClosed])
        XCTAssertEqual(Celebration.lines(goalClosed: false, record: .longestStreak(7), badges: []),
                       [.record(.longestStreak(7))])
        XCTAssertEqual(Celebration.lines(goalClosed: false, record: nil, badges: [.nightOwl, .words100]),
                       [.badges([.nightOwl, .words100])])
    }

    /// Was three; #112 made it four by adding the freeze line. Everything that
    /// can appear at once still has to fit inside the cap, which is what keeps
    /// the screen's two buttons on it at the largest accessibility size.
    /// Was three; #112 added the freeze line and #113 the level line. Everything
    /// that can appear at once still has to fit inside the cap, which is what
    /// keeps the screen's two buttons on it at the largest accessibility size.
    func testFiveIsTheCap() {
        let all = Celebration.lines(freezeSpent: true, goalClosed: true, levelGained: 7,
                                    record: .bestWeek(300), badges: Achievements.Badge.allCases)
        XCTAssertEqual(all.count, Celebration.lineLimit)
        XCTAssertEqual(Celebration.lineLimit, 5)
    }

    /// §5.7: the Done screen says so only when a level was actually *gained*,
    /// never merely because the owner is at one.
    func testALevelIsNamedOnlyWhenItWasGained() {
        XCTAssertEqual(Celebration.lines(goalClosed: false, levelGained: 3, record: nil, badges: []),
                       [.levelGained(3)])
        XCTAssertEqual(Celebration.lines(goalClosed: false, levelGained: nil, record: nil, badges: []),
                       [])
    }

    func testTheBadgesLineKeepsTheOrderItWasGiven() {
        let badges: [Achievements.Badge] = [.words100, .firstSession]
        XCTAssertEqual(Celebration.lines(goalClosed: false, record: nil, badges: badges), [.badges(badges)])
    }

    func testTilesShowThreeAndCountTheRest() {
        let five: [Achievements.Badge] = [.firstSession, .streak7, .reviews100, .perfectSession, .nightOwl]
        let split = Celebration.tiles(five)
        XCTAssertEqual(split.shown, [.firstSession, .streak7, .reviews100])
        XCTAssertEqual(split.more, 2)
    }

    func testThreeOrFewerTilesHaveNoRest() {
        XCTAssertEqual(Celebration.tiles([.firstSession]).more, 0)
        XCTAssertEqual(Celebration.tiles([.firstSession, .streak7, .reviews100]).shown.count, 3)
        XCTAssertEqual(Celebration.tiles([]).shown, [])
    }
}
