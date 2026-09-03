import Foundation
import Scheduling

/// What the Sheet's `_meta` tab said at the last sync (§5.1, §3.1).
///
/// Persisted rather than held in memory because the app has to schedule correctly
/// offline, and `_meta` is only readable when the network is. Written by the sync
/// actor, which runs off the main actor — hence a plain value in `UserDefaults`
/// rather than a property on the `@Observable` settings object.
struct SchedulingOverrides: Equatable, Codable, Sendable {
    var retention: Double?
    var weights: [Double]?

    static let key = "scheduling.metaOverrides"

    static func load(defaults: UserDefaults = .standard) -> SchedulingOverrides {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(SchedulingOverrides.self, from: data)
        else { return SchedulingOverrides() }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
