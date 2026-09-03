import XCTest
@testable import GoogleSheets

/// Card #10 acceptance, package half.
final class ServiceAccountTests: XCTestCase {

    func testParsesAWellFormedServiceAccountKey() throws {
        let account = try ServiceAccount.parse(json: try TestKeys.serviceAccountJSON())
        XCTAssertEqual(account.clientEmail, "repeat-sync@repeat-demo.iam.gserviceaccount.com")
        XCTAssertEqual(account.projectId, "repeat-demo")
        XCTAssertEqual(account.tokenURI, URL(string: "https://oauth2.googleapis.com/token"))
        XCTAssertTrue(account.privateKeyPEM.contains("BEGIN PRIVATE KEY"))
    }

    func testTokenURIDefaultsWhenAbsent() throws {
        var object = try JSONSerialization.jsonObject(
            with: Data(try TestKeys.serviceAccountJSON().utf8)) as! [String: Any]
        object.removeValue(forKey: "token_uri")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertEqual(try ServiceAccount.parse(json: json).tokenURI,
                       URL(string: "https://oauth2.googleapis.com/token"))
    }

    // MARK: - Each failure names what is actually wrong (§4.6)

    func testNonJSONIsReportedAsSuch() {
        XCTAssertThrowsError(try ServiceAccount.parse(json: "not json at all")) {
            XCTAssertEqual($0 as? ServiceAccount.ParseError, .notJSON)
        }
        XCTAssertThrowsError(try ServiceAccount.parse(json: "")) {
            XCTAssertEqual($0 as? ServiceAccount.ParseError, .notJSON)
        }
    }

    /// The most likely wrong paste: an OAuth *client* secret, which is also JSON
    /// from the same console page.
    func testAnOAuthClientSecretIsRejectedByName() {
        let json = #"{"type":"authorized_user","client_id":"x","client_secret":"y","refresh_token":"z"}"#
        XCTAssertThrowsError(try ServiceAccount.parse(json: json)) {
            XCTAssertEqual($0 as? ServiceAccount.ParseError, .wrongCredentialType(found: "authorized_user"))
        }
    }

    func testMissingFieldsAreNamed() throws {
        func removing(_ key: String) throws -> String {
            var object = try JSONSerialization.jsonObject(
                with: Data(try TestKeys.serviceAccountJSON().utf8)) as! [String: Any]
            object.removeValue(forKey: key)
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        for field in ["type", "client_email", "private_key"] {
            XCTAssertThrowsError(try ServiceAccount.parse(json: try removing(field)), field) {
                XCTAssertEqual($0 as? ServiceAccount.ParseError, .missingField(field), field)
            }
        }
    }

    func testAPrivateKeyWithoutPEMArmourIsRejected() throws {
        let json = try TestKeys.serviceAccountJSON(pem: "just some base64 without headers")
        XCTAssertThrowsError(try ServiceAccount.parse(json: json)) {
            XCTAssertEqual($0 as? ServiceAccount.ParseError, .malformedPrivateKey)
        }
    }

    func testAPersonalEmailIsRejected() throws {
        let json = try TestKeys.serviceAccountJSON(email: "someone@gmail.com")
        XCTAssertThrowsError(try ServiceAccount.parse(json: json)) {
            XCTAssertEqual($0 as? ServiceAccount.ParseError, .malformedEmail("someone@gmail.com"))
        }
    }

    // MARK: - §8: no secret in any log output

    func testDescriptionRedactsThePrivateKey() throws {
        let account = try ServiceAccount.parse(json: try TestKeys.serviceAccountJSON())
        for rendering in [account.description, account.debugDescription, "\(account)", String(describing: account)] {
            XCTAssertFalse(rendering.contains("BEGIN PRIVATE KEY"), "the key must never be printable")
            XCTAssertFalse(rendering.contains(account.privateKeyPEM))
            XCTAssertTrue(rendering.contains("<redacted>"))
        }
    }

    func testMaskedSummaryIdentifiesTheAccountWithoutExposingIt() throws {
        let account = try ServiceAccount.parse(json: try TestKeys.serviceAccountJSON())
        let masked = account.maskedSummary
        XCTAssertTrue(masked.hasSuffix("repeat-demo.iam.gserviceaccount.com"))
        XCTAssertTrue(masked.contains("…"))
        XCTAssertFalse(masked.contains(account.privateKeyPEM))
    }
}
