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
    /// What `_meta` said that the app refused to apply — a 20-weight paste, a
    /// retention outside 0.80–0.95 (§5.1). Carried here rather than in the sync
    /// report because Home has to show it until the next sync clears it, and
    /// the report is gone by then. Empty when the last sync applied everything.
    var problems: [String] = []

    init(retention: Double? = nil, weights: [Double]? = nil, problems: [String] = []) {
        self.retention = retention
        self.weights = weights
        self.problems = problems
    }

    /// Hand-written for one reason: a synthesized `init(from:)` ignores the
    /// default on `problems` and throws `keyNotFound` on the blob every device
    /// already has — and `load` turns that into "no overrides", which would
    /// silently drop the Sheet's retention and weights (gotcha 69, third time).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retention = try container.decodeIfPresent(Double.self, forKey: .retention)
        weights = try container.decodeIfPresent([Double].self, forKey: .weights)
        problems = try container.decodeIfPresent([String].self, forKey: .problems) ?? []
    }

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
