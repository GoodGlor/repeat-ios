import XCTest
import UIKit
@testable import Repeat

/// The badge's words, and the one sentence VoiceOver reads for a tile — the
/// card's acceptance line: "<name>, здобуто <date>" or "<name>, <condition>".
final class BadgeTileTests: XCTestCase {

    private let uk = Locale(identifier: "uk_UA")

    func testEveryBadgeHasATitleAConditionAndASymbol() {
        for badge in Achievements.Badge.allCases {
            XCTAssertFalse(badge.title.isEmpty, badge.rawValue)
            XCTAssertFalse(badge.condition.isEmpty, badge.rawValue)
            XCTAssertFalse(badge.symbol.isEmpty, badge.rawValue)
            XCTAssertNotNil(UIImage(systemName: badge.symbol), "\(badge.symbol) is not an SF Symbol")
        }
        XCTAssertEqual(Set(Achievements.Badge.allCases.map(\.title)).count, 12, "two badges share a title")
    }

    func testTheTitlesAreTheCardsNames() {
        XCTAssertEqual(Achievements.Badge.firstSession.title, "Перша сесія")
        XCTAssertEqual(Achievements.Badge.streak7.title, "Серія 7")
        XCTAssertEqual(Achievements.Badge.reviews1000.title, "1 000 повторень")
        XCTAssertEqual(Achievements.Badge.perfectSession.title, "Ідеальна сесія")
        XCTAssertEqual(Achievements.Badge.earlyBird.title, "Рання пташка")
        XCTAssertEqual(Achievements.Badge.nightOwl.title, "Сова")
        XCTAssertEqual(Achievements.Badge.allDecksGreen.title, "Усі колоди зелені")
        XCTAssertEqual(Achievements.Badge.words100.title, "100 слів вивчено")
    }

    func testAnEarnedTileSaysWhen() {
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2027, month: 1, day: 5, hour: 12))!
        let text = BadgeTile.accessibilityText(for: .firstSession, earnedOn: day, locale: uk)
        XCTAssertTrue(text.hasPrefix("Перша сесія, здобуто "), text)
        XCTAssertTrue(text.contains("2027"), text)
        XCTAssertFalse(text.contains("Завершіть"), "an earned tile does not repeat the condition: \(text)")
    }

    func testALockedTileSaysWhatItTakes() {
        XCTAssertEqual(BadgeTile.accessibilityText(for: .firstSession, earnedOn: nil, locale: uk),
                       "Перша сесія, завершіть першу сесію")
        XCTAssertEqual(BadgeTile.accessibilityText(for: .streak30, earnedOn: nil, locale: uk),
                       "Серія 30, 30 днів поспіль")
    }
}
