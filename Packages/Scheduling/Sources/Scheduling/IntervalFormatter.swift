import Foundation

/// Turns an interval into the short label under a rating button (§6.3) and a
/// spoken form, which §8 requires VoiceOver to include.
///
/// Both are locale-aware. The short form used to hardcode Latin abbreviations
/// (`10m`, `15d`) with a note deferring them to #38 — but #38 localised the app
/// target, and this lives in a package with no string catalogue of its own, so
/// the rating buttons still read "15d" under Ukrainian copy. `DateComponents-`
/// `Formatter` already knows every language's abbreviations, which is both
/// smaller than a catalogue here and correct in languages nobody has thought
/// about yet.
public enum IntervalFormatter {

    /// The label drawn on the button.
    public static func short(_ interval: TimeInterval, locale: Locale = .current) -> String {
        let seconds = max(interval, 0)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        // Round to the nearest minute before deciding: FSRS returns a 1-minute
        // step as 59.99…s, and the mockup labels that button "1 хв", not "<1m".
        if minutes < 0.5 { return "<" + format(DateComponents(minute: 1), locale: locale) }
        if minutes < 60 { return format(DateComponents(minute: Int(max(1, minutes.rounded()))), locale: locale) }
        if hours < 24 { return format(DateComponents(hour: Int(hours.rounded())), locale: locale) }
        if days < 30 { return format(DateComponents(day: Int(days.rounded())), locale: locale) }
        if days < 365 { return format(DateComponents(month: Int((days / 30).rounded())), locale: locale) }
        // Whole years only. The previous "%.1fy" carried half-year precision that
        // no localised formatter offers, and an interval past a year is far
        // beyond the point where the exact figure changes a decision.
        return format(DateComponents(year: Int((days / 365).rounded())), locale: locale)
    }

    /// What VoiceOver reads, in full words (§8).
    public static func spoken(_ interval: TimeInterval, locale: Locale = .current) -> String {
        let seconds = max(interval, 60)
        let components: DateComponents = seconds < 3600
            ? DateComponents(minute: Int((seconds / 60).rounded()))
            : (seconds < 86_400
               ? DateComponents(hour: Int((seconds / 3600).rounded()))
               : DateComponents(day: Int((seconds / 86_400).rounded())))
        return format(components, style: .full, locale: locale)
    }

    /// Formats a count of a single unit.
    ///
    /// Takes `DateComponents` rather than a `TimeInterval` on purpose. Neither
    /// seconds overload works here: `string(from: TimeInterval)` cannot express
    /// months or years at all and silently returns zero, and converting back
    /// through a fixed 30-day month and asking the *calendar* how many months
    /// that is gives **"0м" for a 31-day interval** — 30 days from 1 January is
    /// not a whole month. That shipped to the rating buttons and was caught in a
    /// screenshot; every unit test had picked interval values either side of it.
    private static func format(_ components: DateComponents,
                               style: DateComponentsFormatter.UnitsStyle = .abbreviated,
                               locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = [.minute, .hour, .day, .month, .year]
        formatter.maximumUnitCount = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: components) ?? ""
    }
}
