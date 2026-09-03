import Foundation
import Security

/// The self-signed JWT Google's OAuth endpoint accepts in place of a user flow
/// (§4.1).
public enum JWT {
    /// Google caps the assertion lifetime at one hour.
    public static let maximumLifetime: TimeInterval = 3600
    public static let spreadsheetsScope = "https://www.googleapis.com/auth/spreadsheets"

    /// Builds and signs the assertion.
    ///
    /// - Note: `iat` is backdated by a small amount. Google rejects assertions
    ///   whose `iat` is in the future, and a phone's clock can sit a second or two
    ///   ahead of Google's — a failure that would look like a bad key.
    public static func assertion(
        for account: ServiceAccount,
        scope: String = spreadsheetsScope,
        now: Date = Date(),
        lifetime: TimeInterval = maximumLifetime,
        clockSkewAllowance: TimeInterval = 10
    ) throws -> String {
        let issuedAt = Int((now - clockSkewAllowance).timeIntervalSince1970)
        let expiry = Int((now + min(lifetime, maximumLifetime)).timeIntervalSince1970)

        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": scope,
            "aud": account.tokenURI.absoluteString,
            "iat": issuedAt,
            "exp": expiry,
        ]

        let signingInput = try [header, claims]
            .map { try base64URL(JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
            .joined(separator: ".")

        let key = try PrivateKeyImporter.rsaPrivateKey(fromPEM: account.privateKeyPEM)
        let signature = try sign(Data(signingInput.utf8), with: key)
        return "\(signingInput).\(base64URL(signature))"
    }

    static func sign(_ payload: Data, with key: SecKey) throws -> Data {
        guard SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw GoogleAuthError.signingFailed("ключ не підтримує RS256")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, &error
        ) as Data? else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "невідома причина"
            throw GoogleAuthError.signingFailed(reason)
        }
        return signature
    }

    /// base64url, unpadded — JWS requires it, and plain base64 would be rejected.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        return Data(base64Encoded: value)
    }
}
