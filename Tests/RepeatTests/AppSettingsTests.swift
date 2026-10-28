import XCTest
@testable import Repeat

final class AppSettingsTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let name = "streak-reminder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// §5.5 gives the streak reminder its own time, earlier than the due-reminder's
    /// 21:00 default, so that on a colliding evening the one that survives is the
    /// one the owner sees first.
    func testTheStreakTimeDefaultsToEightInTheEvening() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertEqual(settings.streakReminderMinutes, 20 * 60)
        XCTAssertEqual(AppSettings.defaultStreakReminderMinutes, 20 * 60)
    }

    /// Minutes from midnight rather than a `Date`, so a time set at 20:00 stays at
    /// 20:00 across a timezone change — the reason `reminderMinutes` is stored the
    /// same way.
    func testTheStreakTimeSurvivesReload() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).streakReminderMinutes = 19 * 60 + 30
        XCTAssertEqual(AppSettings(defaults: defaults).streakReminderMinutes, 19 * 60 + 30)
    }

    /// A stored 0 means midnight, and must not be mistaken for "unset" by a
    /// sentinel check like `value == 0 ? default : value`. The guard against
    /// `defaults.integer(forKey:)` returning 0 for a missing key is
    /// `testTheStreakTimeDefaultsToEightInTheEvening`, which uses a fresh suite
    /// where the key is truly absent.
    func testMidnightIsStoredRatherThanTreatedAsMissing() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).streakReminderMinutes = 0
        XCTAssertEqual(AppSettings(defaults: defaults).streakReminderMinutes, 0)
    }
}
