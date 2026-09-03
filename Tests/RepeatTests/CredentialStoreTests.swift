import XCTest
import GoogleSheets
@testable import Repeat

/// Card #10 acceptance, app half.
final class CredentialStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? CredentialStore.delete()
    }

    override func tearDown() {
        try? CredentialStore.delete()
        super.tearDown()
    }

    private func sampleJSON() throws -> String {
        // Generated per run rather than committed: a real-looking private key in
        // the repository is a secret-shaped object with no upside.
        let pem = try RepeatTestKeys.makePEM()
        return """
        {"type":"service_account","project_id":"repeat-demo",\
        "private_key":\(jsonString(pem)),\
        "client_email":"repeat-sync@repeat-demo.iam.gserviceaccount.com",\
        "token_uri":"https://oauth2.googleapis.com/token"}
        """
    }

    private func jsonString(_ value: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [value], options: []), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    // MARK: - Storage

    /// "Survives app restart" in a unit test means: written to the Keychain, and
    /// readable through a fresh query rather than from memory.
    func testAKeyIsReadableBackThroughAFreshKeychainQuery() throws {
        let json = try sampleJSON()
        let saved = try CredentialStore.save(json: json)
        XCTAssertEqual(saved.clientEmail, "repeat-sync@repeat-demo.iam.gserviceaccount.com")

        let loaded = try XCTUnwrap(try CredentialStore.load())
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(try CredentialStore.loadJSON(), json, "the raw paste is kept, not a projection of it")
    }

    func testSavingTwiceReplacesRatherThanDuplicating() throws {
        try CredentialStore.save(json: try sampleJSON())
        let second = try sampleJSON()
        try CredentialStore.save(json: second)
        XCTAssertEqual(try CredentialStore.loadJSON(), second)
    }

    func testDeletingRemovesTheKeyAndIsIdempotent() throws {
        try CredentialStore.save(json: try sampleJSON())
        try CredentialStore.delete()
        XCTAssertNil(try CredentialStore.load())
        XCTAssertNoThrow(try CredentialStore.delete())
    }

    func testLoadingWithNoKeyStoredReturnsNilRatherThanThrowing() throws {
        XCTAssertNil(try CredentialStore.load())
        XCTAssertNil(try CredentialStore.loadJSON())
    }

    /// Background refresh (§4.2) runs while the phone is locked, so the key has
    /// to be readable after first unlock rather than only while unlocked.
    func testTheKeychainItemIsAccessibleAfterFirstUnlock() throws {
        try CredentialStore.save(json: try sampleJSON())

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialStore.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()

        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlock as String)
    }

    // MARK: - Rejection happens at paste time

    func testAnInvalidKeyIsRejectedBeforeItReachesTheKeychain() throws {
        XCTAssertThrowsError(try CredentialStore.save(json: "not json"))
        XCTAssertNil(try CredentialStore.load(), "nothing invalid is ever stored")

        XCTAssertThrowsError(try CredentialStore.save(
            json: #"{"type":"authorized_user","client_id":"x"}"#))
        XCTAssertNil(try CredentialStore.load())
    }

    /// A key whose PEM parses as text but will not import is worth catching now,
    /// not at the first sync at 3am under background refresh.
    func testAKeyWhosePEMCannotImportIsRejectedAtPasteTime() throws {
        let json = """
        {"type":"service_account","project_id":"p",\
        "private_key":"-----BEGIN PRIVATE KEY-----\\nZm9vYmFy\\n-----END PRIVATE KEY-----",\
        "client_email":"a@b.iam.gserviceaccount.com"}
        """
        XCTAssertThrowsError(try CredentialStore.save(json: json))
        XCTAssertNil(try CredentialStore.load())
    }
}

/// Local mirror of the package's key generator; the package's test target is not
/// visible from here.
enum RepeatTestKeys {
    static func makePEM(bits: Int = 2048) throws -> String {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else { throw NSError(domain: "RepeatTestKeys", code: 1) }

        let oid = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
                        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        var body = Data([0x02, 0x01, 0x00])
        body.append(oid)
        body.append(der(tag: 0x04, value: pkcs1))
        let base64 = der(tag: 0x30, value: body)
            .base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }

    static func der(tag: UInt8, value: Data) -> Data {
        var out = Data([tag])
        if value.count < 0x80 {
            out.append(UInt8(value.count))
        } else {
            var length = value.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(value)
        return out
    }
}
