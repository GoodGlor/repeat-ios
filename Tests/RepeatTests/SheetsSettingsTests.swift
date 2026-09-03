import XCTest
import GoogleSheets
@testable import Repeat

final class SheetsSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SheetsSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        try? CredentialStore.delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? CredentialStore.delete()
        super.tearDown()
    }

    // MARK: - Spreadsheet id

    /// Owners paste the sheet's URL at least as often as its id.
    func testAPastedSheetURLYieldsTheId() {
        let id = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
        let cases = [
            "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=0",
            "https://docs.google.com/spreadsheets/d/\(id)/edit?usp=sharing",
            "https://docs.google.com/spreadsheets/d/\(id)",
            "  \(id)  ",
        ]
        for input in cases {
            XCTAssertEqual(SheetsSettings.extractSpreadsheetId(from: input), id, input)
        }
    }

    func testANonSheetStringIsLeftAlone() {
        XCTAssertEqual(SheetsSettings.extractSpreadsheetId(from: "hello"), "hello")
        XCTAssertEqual(SheetsSettings.extractSpreadsheetId(from: ""), "")
    }

    func testTheSpreadsheetIdPersistsAcrossInstances() {
        let settings = SheetsSettings(defaults: defaults)
        settings.spreadsheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
        XCTAssertEqual(SheetsSettings(defaults: defaults).spreadsheetId,
                       "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms")
    }

    // MARK: - Status

    func testStatusReflectsWhetherAKeyIsStored() throws {
        let settings = SheetsSettings(defaults: defaults)
        XCTAssertEqual(settings.status, .notConfigured)
        XCTAssertFalse(settings.isConfigured)

        let json = try sampleJSON()
        guard case .success = settings.saveKey(json: json) else { return XCTFail("save failed") }
        guard case .configured(let summary) = settings.status else { return XCTFail("not configured") }
        XCTAssertTrue(summary.contains("…"), "the account is shown masked (§6.6)")

        settings.removeKey()
        XCTAssertEqual(settings.status, .notConfigured)
    }

    func testAnInvalidPasteLeavesAFailedStatusCarryingTheReason() throws {
        let settings = SheetsSettings(defaults: defaults)
        guard case .failure = settings.saveKey(json: #"{"type":"authorized_user"}"#) else {
            return XCTFail("expected failure")
        }
        guard case .failed(let message) = settings.status else { return XCTFail("expected failed status") }
        XCTAssertTrue(message.contains("service_account"), "the message names what is wrong: \(message)")
    }

    // MARK: - Local validation names the specific problem (§4.6)

    func testValidationRequiresAKeyFirst() {
        let settings = SheetsSettings(defaults: defaults)
        settings.spreadsheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
        guard case .failure(let error) = settings.validateLocally() else { return XCTFail("expected failure") }
        XCTAssertEqual(error as? SheetsSettings.ConfigurationError, .noKey)
    }

    func testValidationRequiresASpreadsheetId() throws {
        let settings = SheetsSettings(defaults: defaults)
        _ = settings.saveKey(json: try sampleJSON())
        guard case .failure(let error) = settings.validateLocally() else { return XCTFail("expected failure") }
        XCTAssertEqual(error as? SheetsSettings.ConfigurationError, .noSpreadsheetId)
    }

    func testAnImplausibleSpreadsheetIdIsCalledOutSeparately() throws {
        let settings = SheetsSettings(defaults: defaults)
        _ = settings.saveKey(json: try sampleJSON())
        settings.spreadsheetId = "Мої картки"
        guard case .failure(let error) = settings.validateLocally() else { return XCTFail("expected failure") }
        XCTAssertEqual(error as? SheetsSettings.ConfigurationError, .implausibleSpreadsheetId)
    }

    /// The success message has to say what the owner must still do: sharing the
    /// sheet with the service account is a step nothing else prompts for.
    func testValidationSucceedsAndNamesTheAccountToShareWith() throws {
        let settings = SheetsSettings(defaults: defaults)
        _ = settings.saveKey(json: try sampleJSON())
        settings.spreadsheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"

        guard case .success(let message) = settings.validateLocally() else { return XCTFail("expected success") }
        XCTAssertTrue(message.contains("repeat-sync@repeat-demo.iam.gserviceaccount.com"), message)
        XCTAssertTrue(settings.isConfigured)
    }

    private func sampleJSON() throws -> String {
        let pem = try RepeatTestKeys.makePEM()
        let object: [String: Any] = [
            "type": "service_account",
            "project_id": "repeat-demo",
            "private_key": pem,
            "client_email": "repeat-sync@repeat-demo.iam.gserviceaccount.com",
            "token_uri": "https://oauth2.googleapis.com/token",
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// Closes out #10's deferred acceptance line: a live check that distinguishes
/// "not shared with the service account" from "offline" — two failures that
/// need opposite responses from the owner.
final class ConnectionCheckTests: XCTestCase {

    override func setUp() { super.setUp(); try? CredentialStore.delete() }
    override func tearDown() { try? CredentialStore.delete(); super.tearDown() }

    private func configuredSettings() throws -> SheetsSettings {
        let settings = SheetsSettings(defaults: UserDefaults(suiteName: "check-\(UUID().uuidString)")!)
        let object: [String: Any] = [
            "type": "service_account",
            "project_id": "repeat-demo",
            "private_key": try RepeatTestKeys.makePEM(),
            "client_email": "repeat-sync@repeat-demo.iam.gserviceaccount.com",
        ]
        _ = settings.saveKey(json: String(
            decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        settings.spreadsheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
        return settings
    }

    func testTheLocalChecksStillGateTheNetworkCall() async throws {
        let settings = SheetsSettings(defaults: UserDefaults(suiteName: "gate-\(UUID().uuidString)")!)
        guard case .failure(let error) = await settings.checkConnection() else {
            return XCTFail("expected failure with no key")
        }
        XCTAssertEqual(error as? SheetsSettings.ConfigurationError, .noKey)
    }

    func testAClientCanBeBuiltOnceAKeyAndIdArePresent() throws {
        XCTAssertNoThrow(try configuredSettings().makeClient())
    }

    func testBuildingAClientFailsWithTheSpecificMissingPiece() throws {
        let settings = try configuredSettings()
        settings.spreadsheetId = ""
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? SheetsSettings.ConfigurationError, .noSpreadsheetId)
        }
        settings.removeKey()
        settings.spreadsheetId = "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms"
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? SheetsSettings.ConfigurationError, .noKey)
        }
    }

    /// The two cases #10 could not tell apart. Both are reported here with the
    /// distinct wording §4.6 needs, and only one of them is the owner's to fix by
    /// touching Settings.
    func testNotSharedAndOfflineAreDistinctAndAdviseDifferently() {
        XCTAssertEqual(SheetsError.notShared.description,
                       "Немає доступу до таблиці. Поділіться нею зі службовим акаунтом як редактором.")
        XCTAssertTrue(SheetsError.notShared.needsSettingsAttention)

        let offline = SheetsError.transport("немає мережі")
        XCTAssertNotEqual(offline.description, SheetsError.notShared.description)
        XCTAssertFalse(offline.needsSettingsAttention, "a dropped connection is not a credential problem")

        XCTAssertTrue(SheetsError.spreadsheetNotFound.needsSettingsAttention)
        XCTAssertFalse(SheetsError.rateLimited(afterAttempts: 5).needsSettingsAttention)
    }
}
