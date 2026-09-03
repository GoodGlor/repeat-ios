import Foundation

/// The service-account credential pasted into Settings (§4.1).
///
/// Deliberately not `Codable` on the raw Google JSON alone: the file carries far
/// more than is needed, and a decoder that accepts anything shaped roughly right
/// would let a wrong file — an OAuth client secret, say — reach the signing code
/// and fail much later with a useless error.
public struct ServiceAccount: Equatable, Sendable {
    public let clientEmail: String
    public let tokenURI: URL
    public let projectId: String?
    /// PKCS#8 PEM. Never logged, never printed; see `description`.
    public let privateKeyPEM: String

    public init(clientEmail: String, tokenURI: URL, projectId: String?, privateKeyPEM: String) {
        self.clientEmail = clientEmail
        self.tokenURI = tokenURI
        self.projectId = projectId
        self.privateKeyPEM = privateKeyPEM
    }
}

extension ServiceAccount: CustomStringConvertible, CustomDebugStringConvertible {
    /// §8 requires secrets never to appear in logs. The synthesised description
    /// would print the private key, and `print(account)` is the kind of thing that
    /// gets added during debugging and forgotten.
    public var description: String {
        "ServiceAccount(clientEmail: \(clientEmail), privateKey: <redacted>)"
    }
    public var debugDescription: String { description }
}

public extension ServiceAccount {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case wrongCredentialType(found: String)
        case missingField(String)
        case malformedPrivateKey
        case malformedEmail(String)

        public var description: String {
            switch self {
            case .notJSON:
                "Це не схоже на JSON. Скопіюйте вміст файлу ключа повністю."
            case .wrongCredentialType(let found):
                "Це облікові дані типу «\(found)». Потрібен ключ службового акаунта (service_account)."
            case .missingField(let name):
                "У ключі бракує поля «\(name)»."
            case .malformedPrivateKey:
                "Поле private_key не схоже на PEM-ключ."
            case .malformedEmail(let value):
                "client_email «\(value)» не схожий на адресу службового акаунта."
            }
        }
    }

    /// Parses the JSON Google hands out for a service-account key.
    ///
    /// Every failure names what is wrong, because the alternative — one "invalid
    /// key" message — leaves the owner comparing a 2 KB blob against a web page.
    static func parse(json: String) throws -> ServiceAccount {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ParseError.notJSON }

        if let type = object["type"] as? String, type != "service_account" {
            throw ParseError.wrongCredentialType(found: type)
        }
        guard object["type"] != nil else { throw ParseError.missingField("type") }

        guard let email = object["client_email"] as? String, !email.isEmpty else {
            throw ParseError.missingField("client_email")
        }
        guard email.contains("@"), email.hasSuffix(".gserviceaccount.com") || email.contains(".iam.") else {
            throw ParseError.malformedEmail(email)
        }
        guard let key = object["private_key"] as? String, !key.isEmpty else {
            throw ParseError.missingField("private_key")
        }
        guard key.contains("-----BEGIN PRIVATE KEY-----"), key.contains("-----END PRIVATE KEY-----") else {
            throw ParseError.malformedPrivateKey
        }

        let tokenURI = (object["token_uri"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://oauth2.googleapis.com/token")!

        return ServiceAccount(
            clientEmail: email,
            tokenURI: tokenURI,
            projectId: object["project_id"] as? String,
            privateKeyPEM: key
        )
    }

    /// What Settings shows in place of the key (§6.6): enough to tell which
    /// account is configured, nothing that helps use it.
    var maskedSummary: String {
        let account = clientEmail.split(separator: "@").first.map(String.init) ?? clientEmail
        let prefix = account.prefix(6)
        return "\(prefix)…@\(clientEmail.split(separator: "@").last.map(String.init) ?? "")"
    }
}
