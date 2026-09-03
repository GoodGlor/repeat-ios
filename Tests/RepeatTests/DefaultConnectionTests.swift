import XCTest
import GoogleSheets
@testable import Repeat

/// #78 — a build can carry the owner's connection so a fresh install is already
/// connected. The interesting cases are all about *not* seeding: an owner who
/// deleted the key, or typed their own id, must not be overridden.
final class DefaultConnectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DefaultConnectionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? CredentialStore.delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try? CredentialStore.delete()
        super.tearDown()
    }

    private static let sheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"

    private func writePayload(spreadsheetId: String = sheetId,
                              includeAccount: Bool = true) throws -> URL {
        var root: [String: Any] = ["spreadsheetId": spreadsheetId]
        if includeAccount {
            root["serviceAccount"] = [
                "type": "service_account",
                "project_id": "repeat-demo",
                "private_key": try RepeatTestKeys.makePEM(),
                "client_email": "repeat-sync@repeat-demo.iam.gserviceaccount.com",
                "token_uri": "https://oauth2.googleapis.com/token",
            ] as [String: Any]
        }
        let url = directory.appendingPathComponent("DefaultConnection.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    // MARK: - The happy path

    func testAFreshInstallIsSeededWithBothKeyAndSheet() throws {
        let outcome = DefaultConnection.seed(from: try writePayload(), defaults: defaults)

        XCTAssertEqual(outcome, .seeded(key: true, spreadsheetId: true))
        let settings = SheetsSettings(defaults: defaults)
        XCTAssertTrue(settings.isConfigured)
        XCTAssertEqual(settings.spreadsheetId, Self.sheetId)
        XCTAssertEqual(try CredentialStore.load()?.clientEmail,
                       "repeat-sync@repeat-demo.iam.gserviceaccount.com")
    }

    /// The payload may carry the sheet's URL, because that is what a person
    /// copies. The script normalises it, but a hand-edited file may not have.
    func testAPastedSheetURLInThePayloadIsNormalised() throws {
        let url = try writePayload(
            spreadsheetId: "https://docs.google.com/spreadsheets/d/\(Self.sheetId)/edit#gid=0"
        )
        DefaultConnection.seed(from: url, defaults: defaults)
        XCTAssertEqual(SheetsSettings(defaults: defaults).spreadsheetId, Self.sheetId)
    }

    // MARK: - Not seeding

    /// The regression this card most needs to avoid: "Видалити ключ" has to
    /// stick. Without the marker the next cold launch would put the key back and
    /// the owner could never disconnect.
    func testDeletingTheKeyIsNotUndoneByTheNextLaunch() throws {
        let payload = try writePayload()
        DefaultConnection.seed(from: payload, defaults: defaults)

        let settings = SheetsSettings(defaults: defaults)
        settings.removeKey()
        XCTAssertFalse(settings.isConfigured)

        XCTAssertEqual(DefaultConnection.seed(from: payload, defaults: defaults), .skipped)
        XCTAssertNil(try CredentialStore.load())
        XCTAssertFalse(SheetsSettings(defaults: defaults).isConfigured)
    }

    func testAnIdTheOwnerSetIsNotOverwritten() throws {
        let settings = SheetsSettings(defaults: defaults)
        settings.spreadsheetId = "0000000000000000000000000000000000000000000"

        let outcome = DefaultConnection.seed(from: try writePayload(), defaults: defaults)

        XCTAssertEqual(outcome, .seeded(key: true, spreadsheetId: false))
        XCTAssertEqual(SheetsSettings(defaults: defaults).spreadsheetId,
                       "0000000000000000000000000000000000000000000")
    }

    func testAKeyTheOwnerPastedIsNotReplaced() throws {
        let settings = SheetsSettings(defaults: defaults)
        let object: [String: Any] = [
            "type": "service_account",
            "project_id": "mine",
            "private_key": try RepeatTestKeys.makePEM(),
            "client_email": "mine@mine.iam.gserviceaccount.com",
            "token_uri": "https://oauth2.googleapis.com/token",
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        guard case .success = settings.saveKey(json: json) else { return XCTFail("save failed") }

        let outcome = DefaultConnection.seed(from: try writePayload(), defaults: defaults)

        XCTAssertEqual(outcome, .seeded(key: false, spreadsheetId: true))
        XCTAssertEqual(try CredentialStore.load()?.clientEmail, "mine@mine.iam.gserviceaccount.com")
    }

    // MARK: - Absent and broken payloads

    /// The ordinary state of a clean clone, and of anyone else's checkout.
    func testNoPayloadLeavesEverythingUnconfigured() {
        let missing = directory.appendingPathComponent("DefaultConnection.json")
        XCTAssertEqual(DefaultConnection.seed(from: missing, defaults: defaults), .noPayload)
        XCTAssertEqual(DefaultConnection.seed(from: nil, defaults: defaults), .noPayload)
        XCTAssertFalse(SheetsSettings(defaults: defaults).isConfigured)
        // Crucially it did not mark itself done — dropping the file in later
        // must still work.
        XCTAssertFalse(defaults.bool(forKey: DefaultConnection.seededKey))
    }

    func testAMalformedPayloadFailsWithoutBlockingLaunch() throws {
        let url = directory.appendingPathComponent("DefaultConnection.json")
        try Data("not json".utf8).write(to: url)

        guard case .failed = DefaultConnection.seed(from: url, defaults: defaults) else {
            return XCTFail("expected a failure")
        }
        XCTAssertFalse(SheetsSettings(defaults: defaults).isConfigured)
    }

    func testAPayloadWithoutAServiceAccountFails() throws {
        let url = try writePayload(includeAccount: false)
        guard case .failed = DefaultConnection.seed(from: url, defaults: defaults) else {
            return XCTFail("expected a failure")
        }
    }

    /// A failure must not burn the one shot. The owner's recovery is to fix the
    /// payload and rebuild — which replaces the bundle but not `UserDefaults`,
    /// so a marker set on failure would mean the app never connects again and
    /// never says why.
    func testABrokenPayloadCanBeFixedAndRetried() throws {
        _ = DefaultConnection.seed(from: try writePayload(includeAccount: false),
                                   defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: DefaultConnection.seededKey))

        XCTAssertEqual(DefaultConnection.seed(from: try writePayload(), defaults: defaults),
                       .seeded(key: true, spreadsheetId: true))
    }

    func testSeedingRunsOnlyOnceOnRepeatedLaunches() throws {
        let payload = try writePayload()
        XCTAssertEqual(DefaultConnection.seed(from: payload, defaults: defaults),
                       .seeded(key: true, spreadsheetId: true))
        XCTAssertEqual(DefaultConnection.seed(from: payload, defaults: defaults), .skipped)
    }

    func testForgettingSeedingAllowsItAgain() throws {
        let payload = try writePayload()
        DefaultConnection.seed(from: payload, defaults: defaults)
        try CredentialStore.delete()
        defaults.removeObject(forKey: "google.spreadsheetId")

        DefaultConnection.forgetSeeding(defaults: defaults)
        XCTAssertEqual(DefaultConnection.seed(from: payload, defaults: defaults),
                       .seeded(key: true, spreadsheetId: true))
    }
}
