import Foundation
import Network

/// Notifies when the phone comes back online.
///
/// Behind a protocol because §4.5's "airplane mode for a day, then reconnect
/// drains the queue" is the one sync behaviour that cannot be provoked in a test
/// otherwise — `NWPathMonitor` reports the real device's real network.
protocol NetworkReachability: AnyObject, Sendable {
    /// `onReconnect` fires on each unsatisfied → satisfied transition, never on
    /// the first reading: a normal launch is already covered by `appActive`, and
    /// firing here too would double every cold start's sync.
    func start(onReconnect: @escaping @Sendable () -> Void)
    func stop()
}

final class PathReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.goodglor.repeat.reachability")
    private var wasSatisfied: Bool?

    func start(onReconnect: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            defer { self.wasSatisfied = satisfied }
            // Only a transition counts. `NWPathMonitor` re-reports the same status
            // whenever an interface changes — Wi-Fi to cellular on the same
            // journey would otherwise fire a sync each time.
            guard let previous = self.wasSatisfied, !previous, satisfied else { return }
            onReconnect()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
