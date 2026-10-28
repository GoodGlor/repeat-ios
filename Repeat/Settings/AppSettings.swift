import Foundation
import Observation
import Scheduling

/// Everything §6.6 lets the owner change, and the effective configuration the
/// rest of the app schedules by.
///
/// The composition matters more than the storage: **the Sheet wins.** §5.1 gives
/// `_meta` the last word on weights and retention so optimizer output can be
/// pasted into the spreadsheet without a rebuild, and the Settings slider then
/// shows what the Sheet decided rather than silently disagreeing with it.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    // MARK: - Stored

    var desiredRetention: Double { didSet { write(.retention, desiredRetention) } }
    /// §5.2's ceiling across all decks; per-deck allowances are #21's.
    var globalNewCardCap: Int { didSet { write(.newCardCap, globalNewCardCap) } }
    /// §5.4. Used by #34.
    var leechThreshold: Int { didSet { write(.leechThreshold, leechThreshold) } }
    var reminderEnabled: Bool { didSet { write(.reminderEnabled, reminderEnabled) } }
    /// Minutes from midnight, local. Stored as a number rather than a `Date` so a
    /// reminder set at 21:00 stays at 21:00 across a timezone change.
    var reminderMinutes: Int { didSet { write(.reminderMinutes, reminderMinutes) } }
    /// §5.5's separate time for the streak-at-risk reminder. Minutes from
    /// midnight, for the reason above: a time set at 20:00 stays at 20:00 across a
    /// timezone change.
    var streakReminderMinutes: Int { didSet { write(.streakReminderMinutes, streakReminderMinutes) } }
    var autofillEnabled: Bool { didSet { write(.autofillEnabled, autofillEnabled) } }
    var autofillModel: String { didSet { write(.autofillModel, autofillModel) } }

    /// Cached from the last sync's `_meta`.
    private(set) var overrides: SchedulingOverrides

    // MARK: - Defaults

    static let defaultRetention = 0.90
    static let defaultNewCardCap = 30
    static let defaultLeechThreshold = 8
    /// 21:00.
    static let defaultReminderMinutes = 21 * 60
    /// 20:00 — deliberately before the due-reminder's 21:00. On an evening both
    /// would fire, §5.5 keeps only this one, and the owner sees it at the earlier
    /// hour rather than losing an hour to a notification that never arrives.
    static let defaultStreakReminderMinutes = 20 * 60
    static let defaultAutofillModel = "claude-sonnet-5"
    static let newCardCapRange = 0...200
    static let leechThresholdRange = 3...20

    private enum Key: String {
        case retention = "settings.desiredRetention"
        case newCardCap = "settings.globalNewCardCap"
        case leechThreshold = "settings.leechThreshold"
        case reminderEnabled = "settings.reminderEnabled"
        case reminderMinutes = "settings.reminderMinutes"
        case streakReminderMinutes = "settings.streakReminderMinutes"
        case autofillEnabled = "settings.autofillEnabled"
        case autofillModel = "settings.autofillModel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than the typed accessors: those return 0/false
        // for a missing key, which would silently replace every default with a
        // nonsense value on first launch.
        desiredRetention = defaults.object(forKey: Key.retention.rawValue) as? Double
            ?? Self.defaultRetention
        globalNewCardCap = defaults.object(forKey: Key.newCardCap.rawValue) as? Int
            ?? Self.defaultNewCardCap
        leechThreshold = defaults.object(forKey: Key.leechThreshold.rawValue) as? Int
            ?? Self.defaultLeechThreshold
        reminderEnabled = defaults.object(forKey: Key.reminderEnabled.rawValue) as? Bool ?? false
        reminderMinutes = defaults.object(forKey: Key.reminderMinutes.rawValue) as? Int
            ?? Self.defaultReminderMinutes
        streakReminderMinutes = defaults.object(forKey: Key.streakReminderMinutes.rawValue) as? Int
            ?? Self.defaultStreakReminderMinutes
        autofillEnabled = defaults.object(forKey: Key.autofillEnabled.rawValue) as? Bool ?? false
        autofillModel = defaults.string(forKey: Key.autofillModel.rawValue)
            ?? Self.defaultAutofillModel
        overrides = SchedulingOverrides.load(defaults: defaults)
    }

    private func write(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
    }

    func refreshOverrides() {
        overrides = SchedulingOverrides.load(defaults: defaults)
    }

    // MARK: - Effective configuration

    /// The Sheet's retention when it has one, otherwise the slider's.
    var effectiveRetention: Double {
        overrides.retention ?? desiredRetention
    }

    /// True when the slider is showing a value the Sheet is overriding — the UI
    /// says so rather than letting the control look broken.
    var retentionIsSetBySheet: Bool { overrides.retention != nil }

    var schedulerConfig: SchedulerConfig {
        var config = SchedulerConfig()
        config.desiredRetention = effectiveRetention
        if let weights = overrides.weights, weights.count == SchedulerConfig.fsrs6WeightCount {
            config.weights = weights
        }
        return config
    }

    var queueConfig: QueueConfig {
        var config = QueueConfig()
        config.globalNewCardCap = globalNewCardCap
        return config
    }

    var reminderTime: DateComponents {
        DateComponents(hour: reminderMinutes / 60, minute: reminderMinutes % 60)
    }
}
