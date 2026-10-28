import XCTest
@testable import Repeat

/// #109: a tap on one of our notifications routes by its payload. The payload
/// is the only testable part — `UNNotificationResponse` cannot be constructed.
final class NotificationRouterTests: XCTestCase {
    func testTheStatsPayloadRoutesToStats() {
        XCTAssertEqual(NotificationRouter.destination(from: [NotificationRouter.userInfoKey: DeepLink.stats]), .stats)
    }

    func testTheReminderPayloadRoutesToStudy() {
        // What `DailyReminder` has always written and nothing ever read.
        XCTAssertEqual(NotificationRouter.destination(from: ["url": DeepLink.study]), .study)
    }

    func testAnUnknownPayloadRoutesNowhere() {
        XCTAssertNil(NotificationRouter.destination(from: [:]))
        XCTAssertNil(NotificationRouter.destination(from: ["url": "https://example.com"]))
        XCTAssertNil(NotificationRouter.destination(from: ["url": 42]))
    }
    // MARK: - #141: the owner's third crash report

    /// *"when i tap on notification app dosen open"* — it did open, and aborted.
    ///
    /// `userNotificationCenter(_:didReceive:)` satisfies an `@objc` requirement, so
    /// it is nonisolated: `async` there runs on the cooperative pool. The post
    /// landed on a background thread, `RootTabView.onReceive` delivered on that
    /// thread, SwiftUI updated from it, and UIKit asserted — `SIGABRT` before the
    /// first frame.
    ///
    /// Driven from a **detached** task on purpose: that is what reproduces the
    /// delegate's isolation. Without `@MainActor` on `deliver`, the observer below
    /// records `false` and this fails, which is how it was watched fail.
    func testTheRouteIsAnnouncedOnTheMainThread() async throws {
        let observed = MainThreadProbe()
        let token = NotificationCenter.default.addObserver(
            forName: NotificationRouter.routeRequested, object: nil, queue: nil
        ) { _ in observed.record(Thread.isMainThread) }
        defer { NotificationCenter.default.removeObserver(token) }

        await Task.detached {
            await NotificationRouter.shared.deliver(.study)
        }.value

        XCTAssertEqual(observed.values, [true],
                       "the route was announced off the main thread — UIKit aborts there")
    }

    /// The route still reaches `PendingRoute`, which is what `RootTabView` consumes
    /// when it was not already on screen to hear the announcement.
    func testTheRouteIsAlsoLeftForALaunchingApp() async throws {
        let suite = "router-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        PendingRoute.request(.study, defaults: defaults)

        XCTAssertEqual(PendingRoute.consume(defaults: defaults), .study)
        XCTAssertNil(PendingRoute.consume(defaults: defaults), "reading clears it")
    }
}

/// Records what thread something ran on, across actor boundaries.
private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ isMain: Bool) { lock.lock(); recorded.append(isMain); lock.unlock() }
}
