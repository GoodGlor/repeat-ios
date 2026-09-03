import Foundation
import Security
@testable import GoogleSheets

/// Generates a throwaway RSA key at test time and wraps it as Google would.
///
/// Deliberately not a fixture: a real-looking private key committed to the
/// repository is a secret-shaped object that scanners flag and people copy, and
/// it would have to be rotated for no benefit. Generating one per run also proves
/// the importer works on keys it has never seen.
enum TestKeys {

    static func makePEM() throws -> String {
        let key = try makeSecKey()
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NSError(domain: "TestKeys", code: 1)
        }
        let pkcs8 = wrapInPKCS8(pkcs1: pkcs1)
        let base64 = pkcs8.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }

    static func makeSecKey(bits: Int = 2048) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw NSError(domain: "TestKeys", code: 2)
        }
        return key
    }

    static func serviceAccountJSON(
        email: String = "repeat-sync@repeat-demo.iam.gserviceaccount.com",
        pem: String? = nil
    ) throws -> String {
        let key = try pem ?? makePEM()
        let object: [String: Any] = [
            "type": "service_account",
            "project_id": "repeat-demo",
            "private_key_id": "0123456789abcdef",
            "private_key": key,
            "client_email": email,
            "client_id": "1234567890",
            "token_uri": "https://oauth2.googleapis.com/token",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `PrivateKeyInfo ::= SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING }`
    /// with the rsaEncryption OID — the shape Google emits.
    static func wrapInPKCS8(pkcs1: Data) -> Data {
        let rsaEncryptionOID = Data([
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        var body = Data([0x02, 0x01, 0x00])          // INTEGER 0
        body.append(rsaEncryptionOID)
        body.append(der(tag: 0x04, value: pkcs1))    // OCTET STRING
        return der(tag: 0x30, value: body)
    }

    static func der(tag: UInt8, value: Data) -> Data {
        var out = Data([tag])
        let count = value.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(value)
        return out
    }
}
