import Foundation

/// Everything in this package reaches the network through here, so tests can
/// drive auth and the Sheets client without a live account, and so §8's
/// "network calls only to googleapis.com" has one place to hold.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.transport("Відповідь без HTTP-статусу")
        }
        return (data, http)
    }
}

public enum GoogleAuthError: Error, Equatable, CustomStringConvertible {
    /// The service account was rejected — usually a revoked or wrong key.
    case rejected(reason: String)
    /// The sheet is not shared with the service account, or the scope is missing.
    case forbidden
    case malformedTokenResponse
    case signingFailed(String)
    case transport(String)

    public var description: String {
        switch self {
        case .rejected(let reason):
            "Google відхилив ключ службового акаунта: \(reason)"
        case .forbidden:
            "Доступ заборонено. Поділіться таблицею зі службовим акаунтом як редактором."
        case .malformedTokenResponse:
            "Google повернув неочікувану відповідь на запит токена."
        case .signingFailed(let reason):
            "Не вдалося підписати запит: \(reason)"
        case .transport(let reason):
            "Немає звʼязку з Google: \(reason)"
        }
    }

    /// §4.6 shows a banner linking to Settings only when the credential itself is
    /// the problem — a network blip must not send the owner to re-paste a key
    /// that is perfectly fine.
    public var needsSettingsAttention: Bool {
        switch self {
        case .rejected, .forbidden, .signingFailed: true
        case .malformedTokenResponse, .transport: false
        }
    }
}
