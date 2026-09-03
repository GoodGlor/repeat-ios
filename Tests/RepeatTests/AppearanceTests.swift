import XCTest
import SwiftUI
@testable import Repeat

/// #87 — the setting itself, as opposed to the colours it selects.
final class AppearanceTests: XCTestCase {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "appearance.\(name)")!
        defaults.removePersistentDomain(forName: "appearance.\(name)")
        return defaults
    }

    /// The card's third acceptance line: "Система by default".
    func testTheDefaultIsToFollowTheSystem() {
        XCTAssertEqual(Appearance.stored(in: makeDefaults()), .system)
        XCTAssertNil(Appearance.system.colorScheme,
                     "«Система» must hand the decision back to the phone, not pin a scheme")
    }

    func testAnExplicitChoiceSurvivesRelaunch() {
        let defaults = makeDefaults()
        defaults.set(Appearance.dark.rawValue, forKey: Appearance.storageKey)

        // A fresh read, which is all a relaunch is.
        XCTAssertEqual(Appearance.stored(in: defaults), .dark)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
    }

    /// A value this version does not recognise leaves the app following the phone
    /// rather than pinned to a guess — the failure that matters is a defaults file
    /// written by a newer build, and "follow the system" is the only safe answer.
    func testAnUnreadableValueFallsBackToFollowingTheSystem() {
        let defaults = makeDefaults()
        defaults.set("sepia", forKey: Appearance.storageKey)
        XCTAssertEqual(Appearance.stored(in: defaults), .system)
    }

    /// Every case is offered, and each one is named in the UI language rather than
    /// showing a raw value.
    func testEveryCaseIsSelectableAndNamed() {
        XCTAssertEqual(Appearance.allCases, [.system, .light, .dark])
        for option in Appearance.allCases {
            XCTAssertFalse(option.title.isEmpty, "\(option) has no title")
            XCTAssertNotEqual(option.title, option.rawValue,
                              "\(option) is showing its raw value to the owner")
        }
    }
}
