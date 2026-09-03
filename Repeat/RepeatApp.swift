import SwiftUI
import SwiftData
import GoogleSheets

@main
struct RepeatApp: App {
    private let container: ModelContainer
    @State private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// #87. `@AppStorage` rather than `AppSettings` — see `Appearance` for why.
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.system.rawValue

    init() {
        let container: ModelContainer
        do {
            container = try ModelStore.container()
        } catch {
            // The local store holds the only copy of scheduling state (§8), so
            // silently falling back to a fresh one would look like data loss.
            fatalError("Could not open the local store: \(error)")
        }
        self.container = container

        // §7.4: an App Intent runs in this process and needs the same store.
        // Registered here so it never opens a second container on one file.
        MainActor.assumeIsolated { IntentStore.register(container) }

        #if DEBUG
        // A simulator wipe is the only way to retest first launch, and it also
        // clears the Keychain — but not always in the same order, so allow the
        // marker to be cleared explicitly (#78).
        if ProcessInfo.processInfo.arguments.contains("-resetDefaultConnectionOnLaunch") {
            DefaultConnection.forgetSeeding()
            try? CredentialStore.delete()
            UserDefaults.standard.removeObject(forKey: "google.spreadsheetId")
        }
        #endif

        // #78: before anything reads the connection. `SyncCoordinator` below
        // builds its client from the Keychain, so seeding after it would leave
        // the first sync of a fresh install unconfigured.
        DefaultConnection.seedIfNeeded()

        #if DEBUG
        // §6.4 with a canned answer: enough to see the button, the spinner and
        // the failure line without a key or a network.
        if ProcessInfo.processInfo.arguments.contains("-autofillDemoOnLaunch") {
            AppSettings().autofillEnabled = true
            try? AnthropicKeyStore.save("sk-ant-demo-key-0000")
            AutofillClient.debugTransport = CannedAutofillTransport(
                failing: ProcessInfo.processInfo.arguments.contains("-autofillFailsOnLaunch")
            )
        }

        // #39/#86: the store has to reach its final shape BEFORE any view exists.
        //
        // These used to run from `HomeView.task`, and with `-openAddTabOnLaunch`
        // the Add tab had already resolved and captured a `Deck` by then. The
        // wipe deleted it underneath, the new note attached to a tombstoned deck,
        // and the card vanished — a save that reported success and lost the work.
        // It looked exactly like a product bug for half an hour. Ordering, not
        // SwiftData.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetStoreOnLaunch") {
            MainActor.assumeIsolated { SampleData.eraseEverything(container.mainContext) }
        }
        if arguments.contains("-seedSampleDataOnLaunch") {
            MainActor.assumeIsolated { SampleData.seedIfEmpty(container.mainContext) }
        }

        // #86: §8's "every screen works with no network", made observable. The
        // simulator has no airplane mode, so without this the offline path could
        // only be reasoned about.
        if ProcessInfo.processInfo.arguments.contains("-offlineOnLaunch") {
            SheetsSettings.debugTransport = OfflineTransport()
        }

        // Stands in for an intent performed before the UI exists — the same
        // write `StartReviewIntent` makes, at the same moment. Verifies the
        // seam, which is where this app's bugs have actually lived.
        if let index = arguments.firstIndex(of: "-requestRouteOnLaunch"), index + 1 < arguments.count {
            if arguments[index + 1] == "study" { PendingRoute.request(.study) }
            if arguments[index + 1] == "add" { PendingRoute.request(.add) }
        }
        #endif

        let coordinator = SyncCoordinator(container: container)
        _sync = State(initialValue: coordinator)
        // Registration has to happen before launch finishes (§4.2 trigger 5).
        BackgroundRefresh.register { coordinator } afterSync: {
            // §8: the day's snapshot must happen even if the app is never opened.
            try? BackupRunner.runIfNeeded(in: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(sync)
                // #87. Applied at the root so it reaches the sheets and the
                // full-screen study cover too — those are separate presentations
                // and would otherwise keep the system scheme while the rest of the
                // app changed. `nil` for "Система", which is the default and the
                // only value that goes on following the phone afterwards.
                .preferredColorScheme(Appearance(rawValue: appearanceRaw)?.colorScheme)
                .task {
                    AppGroup.prepare()
                    // §8, the other trigger: the first foreground of a new day.
                    // `runIfNeeded` is idempotent per day, so this and the
                    // background task cannot double up.
                    try? BackupRunner.runIfNeeded(in: container.mainContext)
                    // §7.3: the Share Extension is a separate process and cannot
                    // touch SwiftData, so its file drops are ingested here.
                    try? InboxIngest.run(in: container.mainContext)
                    sync.startMonitoring()
                    BackgroundRefresh.schedule()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // §4.2 trigger 1. Throttling lives in the actor, so flipping in and
            // out of the app costs nothing here.
            if phase == .active {
                sync.trigger(.appActive)
                // Sharing happens while this app is backgrounded, so foreground
                // is the moment a capture actually arrives — waiting for the next
                // cold launch would strand it (§7.3).
                try? InboxIngest.run(in: container.mainContext)
            }
        }
    }
}


#if DEBUG
/// A network that is not there (#86).
///
/// Throws the error a real device throws with no route, so `SyncActor.isOffline`
/// classifies it the same way — the point is to exercise that decision, not to
/// bypass it.
private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A fixed reply, so the autofill UI can be screenshotted deterministically.
private struct CannedAutofillTransport: AutofillTransport {
    let failing: Bool

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let status = failing ? 401 : 200
        let body = failing
            ? #"{"error":{"message":"invalid x-api-key"}}"#
            : #"{"content":[{"type":"text","text":"{\"back\":\"неохочий\",\"example\":\"He was reluctant to answer.\"}"}]}"#
        let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}
#endif
