import Foundation
import Security
import GoogleSheets

/// Keychain storage for the service-account key (§4.1).
///
/// The raw JSON is stored rather than the parsed fields, so a future parser fix
/// can re-read what the owner actually pasted instead of a lossy projection of
/// it. Accessibility is `AfterFirstUnlock` because background refresh (§4.2) runs
/// while the phone is locked and still needs to sync.
enum CredentialStore {
    static let service = "com.goodglor.repeat.google"
    private static let account = "service-account-json"

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case keychain(OSStatus)

        var description: String {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
                return Localized.string("Не вдалося звернутися до Keychain: \(message)")
            }
        }
    }

    /// Validates before storing: a key that cannot be parsed or whose PEM will not
    /// import is worth rejecting at the point of paste, not at the first sync.
    @discardableResult
    static func save(json: String) throws -> ServiceAccount {
        let account = try ServiceAccount.parse(json: json)
        _ = try PrivateKeyImporter.rsaPrivateKey(fromPEM: account.privateKeyPEM)

        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(json.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return account
    }

    static func loadJSON() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func load() throws -> ServiceAccount? {
        guard let json = try loadJSON() else { return nil }
        return try ServiceAccount.parse(json: json)
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
