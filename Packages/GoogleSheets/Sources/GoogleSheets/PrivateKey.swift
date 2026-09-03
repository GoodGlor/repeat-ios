import Foundation
import Security

/// Turns the PEM in a service-account key into a `SecKey` usable for RS256
/// signing (§4.1).
///
/// Google issues **PKCS#8** (`-----BEGIN PRIVATE KEY-----`), while
/// `SecKeyCreateWithData` expects a bare **PKCS#1** RSAPrivateKey. The wrapper
/// has to come off, which needs just enough DER parsing to reach the inner
/// OCTET STRING — no ASN.1 library, and nothing is trusted about lengths.
public enum PrivateKeyImporter {

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notPEM
        case badBase64
        case notPKCS8
        case rejectedBySecurityFramework(String)

        public var description: String {
            switch self {
            case .notPEM:
                "Ключ не має рядків -----BEGIN PRIVATE KEY-----."
            case .badBase64:
                "Тіло ключа не декодується з base64."
            case .notPKCS8:
                "Ключ не у форматі PKCS#8, який видає Google."
            case .rejectedBySecurityFramework(let reason):
                "Система не прийняла ключ: \(reason)"
            }
        }
    }

    public static func rsaPrivateKey(fromPEM pem: String) throws -> SecKey {
        let der = try derBody(fromPEM: pem)
        let pkcs1 = try unwrapPKCS8(der)

        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "невідома причина"
            throw ImportError.rejectedBySecurityFramework(reason)
        }
        return key
    }

    /// Strips the PEM armour and decodes the base64 body.
    static func derBody(fromPEM pem: String) throws -> Data {
        let begin = "-----BEGIN PRIVATE KEY-----"
        let end = "-----END PRIVATE KEY-----"
        // The JSON carries the key with literal \n escapes already decoded by the
        // JSON parser, but a hand-pasted key may use real newlines or \r\n.
        guard let start = pem.range(of: begin), let stop = pem.range(of: end), start.upperBound <= stop.lowerBound
        else { throw ImportError.notPEM }

        let body = pem[start.upperBound..<stop.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !body.isEmpty, let data = Data(base64Encoded: body) else { throw ImportError.badBase64 }
        return data
    }

    /// PKCS#8 `PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE,
    /// privateKey OCTET STRING }` — the OCTET STRING holds the PKCS#1 key.
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(der)
        guard let outer = reader.readTLV(), outer.tag == 0x30 else { throw ImportError.notPKCS8 }

        var inner = DERReader(outer.value)
        guard let version = inner.readTLV(), version.tag == 0x02 else { throw ImportError.notPKCS8 }
        guard let algorithm = inner.readTLV(), algorithm.tag == 0x30 else { throw ImportError.notPKCS8 }
        guard let key = inner.readTLV(), key.tag == 0x04 else { throw ImportError.notPKCS8 }
        guard !key.value.isEmpty else { throw ImportError.notPKCS8 }
        return key.value
    }
}

/// Minimal DER tag-length-value reader. Only what unwrapping PKCS#8 needs, and
/// it refuses anything it cannot read rather than guessing.
struct DERReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    struct TLV { let tag: UInt8; let value: Data }

    mutating func readTLV() -> TLV? {
        guard index < data.endIndex else { return nil }
        let tag = data[index]
        index = data.index(after: index)

        guard index < data.endIndex else { return nil }
        var length = Int(data[index])
        index = data.index(after: index)

        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            // 0x80 is indefinite length, illegal in DER; more than 4 length bytes
            // would exceed anything a key can legitimately be.
            guard byteCount > 0, byteCount <= 4 else { return nil }
            guard data.distance(from: index, to: data.endIndex) >= byteCount else { return nil }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[index])
                index = data.index(after: index)
            }
        }

        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else { return nil }
        let end = data.index(index, offsetBy: length)
        let value = Data(data[index..<end])
        index = end
        return TLV(tag: tag, value: value)
    }
}
