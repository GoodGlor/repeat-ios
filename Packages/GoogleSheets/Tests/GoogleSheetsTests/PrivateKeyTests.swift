import XCTest
import Security
@testable import GoogleSheets

/// The PKCS#8 → PKCS#1 unwrap (§4.1). Google issues PKCS#8; the Security
/// framework wants PKCS#1, and getting the boundary wrong fails at signing time
/// with an opaque error.
final class PrivateKeyTests: XCTestCase {

    func testARealGeneratedKeyRoundTripsFromPEMToSecKey() throws {
        let pem = try TestKeys.makePEM()
        let key = try PrivateKeyImporter.rsaPrivateKey(fromPEM: pem)

        // Prove it is genuinely usable for RS256, which is the only reason to
        // import it (§4.1).
        XCTAssertTrue(SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256))
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, Data("payload".utf8) as CFData, &error
        )
        XCTAssertNotNil(signature)
        XCTAssertNil(error?.takeRetainedValue())
    }

    func testPEMWithCarriageReturnsAndStrayWhitespaceStillImports() throws {
        let pem = try TestKeys.makePEM()
            .replacingOccurrences(of: "\n", with: "\r\n")
            .appending("   \n")
        XCTAssertNoThrow(try PrivateKeyImporter.rsaPrivateKey(fromPEM: pem))
    }

    func testMissingArmourIsReportedAsNotPEM() {
        XCTAssertThrowsError(try PrivateKeyImporter.rsaPrivateKey(fromPEM: "abcdef")) {
            XCTAssertEqual($0 as? PrivateKeyImporter.ImportError, .notPEM)
        }
    }

    func testUndecodableBodyIsReportedAsBadBase64() {
        let pem = "-----BEGIN PRIVATE KEY-----\n!!!!\n-----END PRIVATE KEY-----"
        XCTAssertThrowsError(try PrivateKeyImporter.rsaPrivateKey(fromPEM: pem)) {
            XCTAssertEqual($0 as? PrivateKeyImporter.ImportError, .badBase64)
        }
    }

    /// A PKCS#1 key pasted directly — plausible if someone converts the key by
    /// hand — is not PKCS#8 and must say so rather than failing deep in Security.
    func testABarePKCS1BodyIsReportedAsNotPKCS8() throws {
        var error: Unmanaged<CFError>?
        let pkcs1 = SecKeyCopyExternalRepresentation(try TestKeys.makeSecKey(), &error) as Data?
        let body = try XCTUnwrap(pkcs1).base64EncodedString()
        let pem = "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----"
        XCTAssertThrowsError(try PrivateKeyImporter.rsaPrivateKey(fromPEM: pem)) {
            XCTAssertEqual($0 as? PrivateKeyImporter.ImportError, .notPKCS8)
        }
    }

    // MARK: - The DER reader refuses malformed input rather than guessing

    func testTruncatedDERIsRejected() {
        let der = TestKeys.der(tag: 0x30, value: Data([0x02, 0x01, 0x00]))
        XCTAssertThrowsError(try PrivateKeyImporter.unwrapPKCS8(der.prefix(2)))
    }

    func testLengthLongerThanTheBufferIsRejected() {
        // SEQUENCE claiming 200 bytes of content but carrying two.
        let der = Data([0x30, 0xC8, 0x02, 0x01])
        XCTAssertThrowsError(try PrivateKeyImporter.unwrapPKCS8(der))
    }

    func testIndefiniteLengthIsRejected() {
        // 0x80 is indefinite length — legal in BER, never in DER.
        let der = Data([0x30, 0x80, 0x02, 0x01, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try PrivateKeyImporter.unwrapPKCS8(der))
    }

    func testAnEmptyOctetStringIsRejected() {
        var body = Data([0x02, 0x01, 0x00])
        body.append(TestKeys.der(tag: 0x30, value: Data([0x06, 0x01, 0x2A])))
        body.append(TestKeys.der(tag: 0x04, value: Data()))
        XCTAssertThrowsError(try PrivateKeyImporter.unwrapPKCS8(TestKeys.der(tag: 0x30, value: body))) {
            XCTAssertEqual($0 as? PrivateKeyImporter.ImportError, .notPKCS8)
        }
    }

    func testAMultiByteLengthIsParsed() throws {
        // A 2048-bit key's PKCS#8 body needs a two-byte length, so this is the
        // normal path rather than an exotic one.
        let der = try PrivateKeyImporter.derBody(fromPEM: try TestKeys.makePEM())
        XCTAssertGreaterThan(der.count, 1000)
        XCTAssertNoThrow(try PrivateKeyImporter.unwrapPKCS8(der))
    }
}
