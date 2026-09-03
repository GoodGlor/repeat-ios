import Foundation
import Observation
import GoogleSheets

/// The Google connection as Settings sees it (§6.6).
///
/// The spreadsheet id lives in `UserDefaults`: it is an identifier, not a secret,
/// it appears in the sheet's own URL, and keeping it out of the Keychain means a
/// key rotation and an id change are independent operations.
@Observable
final class SheetsSettings {
    enum Status: Equatable {
        case notConfigured
        case configured(accountSummary: String)
        case failed(String)
    }

    private let defaults: UserDefaults
    private static let spreadsheetIdKey = "google.spreadsheetId"

    private(set) var status: Status = .notConfigured
    var spreadsheetId: String {
        didSet { defaults.set(spreadsheetId, forKey: Self.spreadsheetIdKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.spreadsheetId = defaults.string(forKey: Self.spreadsheetIdKey) ?? ""
        refreshStatus()
    }

    var isConfigured: Bool {
        if case .configured = status { return !trimmedSpreadsheetId.isEmpty }
        return false
    }

    var trimmedSpreadsheetId: String {
        spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts a pasted key. The error is surfaced verbatim because every case
    /// names what is actually wrong (§4.6).
    func saveKey(json: String) -> Result<ServiceAccount, Error> {
        do {
            let account = try CredentialStore.save(json: json)
            status = .configured(accountSummary: account.maskedSummary)
            return .success(account)
        } catch {
            status = .failed(String(describing: error))
            return .failure(error)
        }
    }

    func removeKey() {
        try? CredentialStore.delete()
        status = .notConfigured
    }

    func refreshStatus() {
        do {
            if let account = try CredentialStore.load() {
                status = .configured(accountSummary: account.maskedSummary)
            } else {
                status = .notConfigured
            }
        } catch {
            status = .failed(String(describing: error))
        }
    }

    enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case noKey
        case noSpreadsheetId
        case implausibleSpreadsheetId

        var description: String {
            switch self {
            case .noKey: Localized.string("Спочатку додайте ключ службового акаунта.")
            case .noSpreadsheetId: Localized.string("Вкажіть ID таблиці.")
            case .implausibleSpreadsheetId: Localized.string("Це не схоже на ID таблиці Google.")
            }
        }
    }

    /// Everything that can be checked without the network (§6.6).
    ///
    /// The key parses, its PEM imports as an RSA key, and the spreadsheet id is
    /// plausible. Reaching the API — and so distinguishing "not shared with the
    /// service account" from "offline" — needs the client from #12, which
    /// extends this check rather than replacing it.
    func validateLocally() -> Result<String, Error> {
        do {
            guard let account = try CredentialStore.load() else { throw ConfigurationError.noKey }
            _ = try PrivateKeyImporter.rsaPrivateKey(fromPEM: account.privateKeyPEM)

            let id = trimmedSpreadsheetId
            guard !id.isEmpty else { throw ConfigurationError.noSpreadsheetId }
            // Google's ids are long opaque base64url-ish strings; anything short
            // is almost always a pasted title or a truncated copy.
            guard id.count >= 20, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { throw ConfigurationError.implausibleSpreadsheetId }

            return .success(Localized.string("Ключ дійсний. Поділіться таблицею з \(account.clientEmail) як редактором."))
        } catch {
            return .failure(error)
        }
    }

    /// Builds a client for the stored credential, or throws saying what is
    /// missing.
    func makeClient() throws -> SheetsClient {
        try Self.makeClient(defaults: defaults)
    }

    /// The same, without an instance.
    ///
    /// #18's `SyncActor` runs off the main actor and must not capture this
    /// `@Observable` object, so it reads the stored id and key on each run — which
    /// also means a key or spreadsheet id changed in Settings takes effect on the
    /// next sync rather than the next launch.
    static func makeClient(defaults: UserDefaults = .standard) throws -> SheetsClient {
        guard let account = try CredentialStore.load() else { throw ConfigurationError.noKey }
        let id = (defaults.string(forKey: spreadsheetIdKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ConfigurationError.noSpreadsheetId }
        #if DEBUG
        if let transport = debugTransport {
            return SheetsClient(spreadsheetId: id,
                                tokens: GoogleTokenProvider(account: account, transport: transport),
                                transport: transport)
        }
        #endif
        return SheetsClient(spreadsheetId: id, tokens: GoogleTokenProvider(account: account))
    }

    #if DEBUG
    /// Swaps the network out from under a *real* client (#86).
    ///
    /// The simulator has no airplane mode, so §8's "every screen works with no
    /// network" was unobservable: the sync layer's offline path is covered by
    /// `AddCardTests`, but nobody had ever seen what Home says. Injecting here
    /// rather than faking a status keeps the real `SyncActor.isOffline`
    /// classification in the loop — which is the part that decides between
    /// "changes will sync later" and "go look at Settings".
    ///
    /// Mirrors `AutofillClient.debugTransport`.
    nonisolated(unsafe) static var debugTransport: HTTPTransport?
    #endif

    /// The full check §6.6 asks for: reach the spreadsheet and report precisely
    /// why if it cannot. Completes what `validateLocally` could only guess at —
    /// "not shared with the service account" and "offline" are indistinguishable
    /// without a round trip, and they need opposite responses from the owner.
    func checkConnection() async -> Result<String, Error> {
        switch validateLocally() {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        do {
            let sheets = try await makeClient().checkAccess()
            let decks = sheets.filter { !$0.isReserved }
            return .success(decks.isEmpty
                ? Localized.string("Доступ є, але жодного аркуша з картками не знайдено.")
                : Localized.string("Доступ є. Аркушів із картками: \(decks.count)."))
        } catch {
            return .failure(error)
        }
    }

    /// Owners paste the whole sheet URL as often as the bare id.
    static func extractSpreadsheetId(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("docs.google.com") else { return trimmed }
        guard let range = trimmed.range(of: "/spreadsheets/d/") else { return trimmed }
        let rest = trimmed[range.upperBound...]
        return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }
}
