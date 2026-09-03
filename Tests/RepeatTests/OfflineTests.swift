import XCTest
import SwiftData
import GoogleSheets
@testable import Repeat

/// #86 — what the app says and does with no network.
///
/// §4.6 draws a line the code cares about: "offline" means do nothing and it will
/// sort itself out, "failed" means go and look at Settings. Getting them the
/// wrong way round sends someone to re-paste a key that was never the problem.
final class OfflineTests: XCTestCase {

    /// Refuses every request the way a phone with no route does.
    private struct DeadNetwork: HTTPTransport {
        let error: any Error
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw error
        }
    }

    private func makeActor(_ transport: some HTTPTransport,
                           container: ModelContainer) throws -> SyncActor {
        let object: [String: Any] = [
            "type": "service_account", "project_id": "p",
            "private_key": try RepeatTestKeys.makePEM(),
            "client_email": "a@b.iam.gserviceaccount.com",
        ]
        let account = try ServiceAccount.parse(
            json: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        let client = SheetsClient(
            spreadsheetId: "sheet",
            tokens: GoogleTokenProvider(account: account, transport: transport),
            transport: transport
        )
        return SyncActor(container: container, makeClient: { client })
    }

    private func seededContainer() throws -> ModelContainer {
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        context.insert(Deck(sheetTitle: "Verbs", sheetId: 0))
        try context.save()
        return container
    }

    // MARK: - The classification

    /// The bug this card found, and the reason it was invisible: the token
    /// request is the FIRST call of every sync and there is no cached token on a
    /// cold launch, so with no signal the error that surfaces comes from the auth
    /// path. `SheetsClient` rethrows it as `.auth`, and the app read that as a
    /// credential problem — showing "Не вдалося синхронізувати" and pointing at
    /// Settings when nothing was wrong but the network.
    ///
    /// Every unit test before this injected `SheetsError.transport` directly and
    /// so never went through the token request at all.
    func testNoNetworkReportsOfflineRatherThanASettingsProblem() async throws {
        let container = try seededContainer()
        let actor = try makeActor(DeadNetwork(error: URLError(.notConnectedToInternet)),
                                  container: container)

        let report = await actor.sync(.appActive)

        guard case .failed(_, let needsSettingsAttention, let isOffline) = report.verdict else {
            return XCTFail("expected a failure, got \(report.verdict)")
        }
        XCTAssertTrue(isOffline, "a request that never arrived was read as a credential problem")
        XCTAssertFalse(needsSettingsAttention, "offline must not send the owner to Settings")
    }

    /// The other failures a dead network produces.
    func testEveryTransportFailureShapeReadsAsOffline() async throws {
        for error in [URLError(.notConnectedToInternet), URLError(.timedOut),
                      URLError(.networkConnectionLost), URLError(.cannotFindHost)] {
            let actor = try makeActor(DeadNetwork(error: error), container: try seededContainer())
            let report = await actor.sync(.appActive)
            guard case .failed(_, _, let isOffline) = report.verdict else {
                return XCTFail("expected a failure for \(error.code)")
            }
            XCTAssertTrue(isOffline, "\(error.code) was not read as offline")
        }
    }

    /// The line still has to hold in the other direction: a real refusal from
    /// Google is *not* offline, and must keep pointing at Settings.
    func testARefusedKeyIsStillASettingsProblem() async throws {
        struct Refusing: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let body = #"{"error":"invalid_grant","error_description":"bad key"}"#
                return (Data(body.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 400,
                                        httpVersion: nil, headerFields: nil)!)
            }
        }
        let actor = try makeActor(Refusing(), container: try seededContainer())

        let report = await actor.sync(.appActive)

        guard case .failed(_, _, let isOffline) = report.verdict else {
            return XCTFail("expected a failure, got \(report.verdict)")
        }
        XCTAssertFalse(isOffline, "a rejected key is not a network outage")
    }

    // MARK: - What the reader sees

    func testTheStatusLineSaysChangesWillSyncLater() {
        let line = SyncStatusFormatter.line(status: .offline, lastSyncedAt: nil, now: .now)
        XCTAssertTrue(line.text.contains("Офлайн"), line.text)
        XCTAssertFalse(line.text.contains("Не вдалося"), line.text)
    }

    // MARK: - Work is kept, not lost

    /// §8's promise, at the layer that has to keep it: an edit made with no
    /// network stays queued rather than being dropped or silently marked sent.
    func testAnEditMadeOfflineStaysQueued() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        let deck = try XCTUnwrap(try context.fetch(FetchDescriptor<Deck>()).first)
        let note = try AddCardComposer.save(
            .init(front: "reluctant", back: "неохочий"), to: deck, in: context)
        try context.save()
        XCTAssertTrue(note.pendingUpload)

        let actor = try makeActor(DeadNetwork(error: URLError(.notConnectedToInternet)),
                                  container: container)
        _ = await actor.sync(.contentEdited)

        let after = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(after.count, 1, "the note was dropped")
        XCTAssertTrue(after[0].pendingUpload, "the note was marked sent without being sent")
    }
}
