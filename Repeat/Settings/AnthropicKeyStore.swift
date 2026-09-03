import Foundation
import Security

/// Keychain storage for the Anthropic API key (§6.6, §10 of the spec's non-goals).
///
/// A second store rather than a second field on `CredentialStore`: the two keys
/// have different lifetimes and different blast radii, and deleting one must
/// never touch the other. Same accessibility as the Google key — autofill can be
/// triggered from the Share Extension while the phone is locked.
enum AnthropicKeyStore {
    static let service = "com.goodglor.repeat.anthropic"
    private static let account = "api-key"

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete() }

        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStore.StoreError.keychain(status) }
    }

    static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStore.StoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStore.StoreError.keychain(status)
        }
    }

    /// `sk-ant-…abcd` — enough to tell two keys apart, not enough to use one.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
