import XCTest
import Security
@testable import GoogleSheets

/// Card #11, signing half.
///
/// "Accepted by Google's token endpoint" cannot be asserted without a live
/// account, so it is decomposed into the two things that make an assertion
/// acceptable: the signature verifies under the matching public key, and the
/// claim set is exactly what Google documents.
final class JWTTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(pem: String) -> ServiceAccount {
        ServiceAccount(
            clientEmail: "repeat-sync@repeat-demo.iam.gserviceaccount.com",
            tokenURI: URL(string: "https://oauth2.googleapis.com/token")!,
            projectId: "repeat-demo",
            privateKeyPEM: pem
        )
    }

    private func parts(_ jwt: String) throws -> (header: [String: Any], claims: [String: Any], signature: Data) {
        let segments = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(segments.count, 3, "a JWS has three segments")
        let header = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(JWT.decodeBase64URL(segments[0]))) as? [String: Any])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(JWT.decodeBase64URL(segments[1]))) as? [String: Any])
        return (header, claims, try XCTUnwrap(JWT.decodeBase64URL(segments[2])))
    }

    func testTheAssertionIsSignedWithRS256AndVerifiesUnderThePublicKey() throws {
        let key = try TestKeys.makeSecKey()
        var error: Unmanaged<CFError>?
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        let pem = "-----BEGIN PRIVATE KEY-----\n"
            + TestKeys.wrapInPKCS8(pkcs1: pkcs1).base64EncodedString()
            + "\n-----END PRIVATE KEY-----"

        let jwt = try JWT.assertion(for: account(pem: pem), now: now)
        let (header, _, signature) = try parts(jwt)
        XCTAssertEqual(header["alg"] as? String, "RS256")
        XCTAssertEqual(header["typ"] as? String, "JWT")

        // The signature covers exactly "header.claims" — the bytes Google will
        // reconstruct and verify.
        let signingInput = Data(jwt.split(separator: ".").dropLast().joined(separator: ".").utf8)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertTrue(SecKeyVerifySignature(
            publicKey, .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData, signature as CFData, &error
        ), "Google would reject a signature that does not verify")
        XCTAssertNil(error?.takeRetainedValue())
    }

    func testTheClaimSetIsExactlyWhatGoogleRequires() throws {
        let jwt = try JWT.assertion(for: account(pem: try TestKeys.makePEM()), now: now)
        let (_, claims, _) = try parts(jwt)

        XCTAssertEqual(claims["iss"] as? String, "repeat-sync@repeat-demo.iam.gserviceaccount.com")
        XCTAssertEqual(claims["scope"] as? String, "https://www.googleapis.com/auth/spreadsheets")
        XCTAssertEqual(claims["aud"] as? String, "https://oauth2.googleapis.com/token")

        let issuedAt = try XCTUnwrap(claims["iat"] as? Int)
        let expiry = try XCTUnwrap(claims["exp"] as? Int)
        XCTAssertEqual(expiry - issuedAt, Int(JWT.maximumLifetime) + 10)
        XCTAssertLessThanOrEqual(expiry, Int(now.timeIntervalSince1970) + Int(JWT.maximumLifetime))
    }

    /// A phone whose clock runs a second or two ahead of Google's would otherwise
    /// mint assertions with a future `iat`, which Google rejects — and which looks
    /// exactly like a bad key.
    func testIssuedAtIsBackdatedToAbsorbClockSkew() throws {
        let jwt = try JWT.assertion(for: account(pem: try TestKeys.makePEM()), now: now)
        let issuedAt = try XCTUnwrap(try parts(jwt).claims["iat"] as? Int)
        XCTAssertLessThan(issuedAt, Int(now.timeIntervalSince1970))
    }

    func testLifetimeIsCappedAtGooglesOneHourLimit() throws {
        let jwt = try JWT.assertion(for: account(pem: try TestKeys.makePEM()), now: now, lifetime: 86_400)
        let claims = try parts(jwt).claims
        let issuedAt = try XCTUnwrap(claims["iat"] as? Int)
        let expiry = try XCTUnwrap(claims["exp"] as? Int)
        XCTAssertLessThanOrEqual(Double(expiry - issuedAt) - 10, JWT.maximumLifetime)
    }

    /// JWS requires base64url without padding; plain base64 is rejected outright.
    func testSegmentsAreUnpaddedBase64URL() throws {
        let jwt = try JWT.assertion(for: account(pem: try TestKeys.makePEM()), now: now)
        for segment in jwt.split(separator: ".") {
            XCTAssertFalse(segment.contains("="), "padding is not allowed")
            XCTAssertFalse(segment.contains("+"), "base64url uses -")
            XCTAssertFalse(segment.contains("/"), "base64url uses _")
        }
        XCTAssertEqual(JWT.base64URL(Data([0xFB, 0xFF, 0xFE])), "-__-")
    }

    func testAKeyThatCannotImportFailsAtSigningWithAClearReason() {
        let broken = account(pem: "-----BEGIN PRIVATE KEY-----\nZm9v\n-----END PRIVATE KEY-----")
        XCTAssertThrowsError(try JWT.assertion(for: broken, now: now))
    }
}
