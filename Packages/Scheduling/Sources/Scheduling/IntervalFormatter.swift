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
        // Months and years carry one decimal, as Anki's buttons do. Whole months
        // cannot keep the rating buttons apart: FSRS puts Hard at 0.7–0.87 of
        // Good, so 30 and 44 days both rounded to "1mo", and on a harder card 90
        // and 104 days would both have read "3mo" — two buttons making one
        // promise. With a tenth of a month the pair is always at least a step
        // apart, which `RatingLabelTests` sweeps every review card to prove.
        // Months run to two years, not one: a tenth of a year is 36 days, and
        // just past a year Hard trails Good by less than that on a hard card
        // (384 and 419 days would both have read "1.1y").
        if days < 730 { return format(fraction: days / 30, of: .month, locale: locale) }
        return format(fraction: days / 365, of: .year, locale: locale)
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
    ///
    /// `allowedUnits` is narrowed to the one unit the components carry. Left at
    /// the full set, the formatter normalises on its own — `day: 45` comes back
    /// as "1mo" whatever the caller decided — which is how raising the day
    /// threshold above changed nothing at all until this line was written.
    private static func format(_ components: DateComponents,
                               style: DateComponentsFormatter.UnitsStyle = .abbreviated,
                               locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = unit(of: components)
        formatter.maximumUnitCount = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: components) ?? ""
    }

    /// "3.5mo" / "3,5 міс." — a decimal count of one unit, in the locale's words.
    ///
    /// No system formatter renders a fractional month or year, so this borrows
    /// the unit word from the one that renders whole ones: it formats the whole
    /// count, then swaps that count's digits for the decimal. The plural form is
    /// therefore the whole count's, which in the abbreviated style is invariant
    /// in every language the app ships in. If the digits cannot be found — a
    /// locale that writes the count in a script `NumberFormatter` does not — the
    /// whole-unit label stands rather than an empty button.
    private static func format(fraction value: Double, of unit: NSCalendar.Unit,
                               locale: Locale) -> String {
        let tenths = (value * 10).rounded() / 10
        let whole = max(1, Int(tenths.rounded(.down)))
        var components = DateComponents()
        switch unit {
        case .year: components.year = whole
        default: components.month = whole
        }
        let label = format(components, locale: locale)

        let decimals = NumberFormatter()
        decimals.locale = locale
        decimals.minimumFractionDigits = 1
        decimals.maximumFractionDigits = 1
        let integers = NumberFormatter()
        integers.locale = locale
        integers.maximumFractionDigits = 0
        guard let decimal = decimals.string(from: tenths as NSNumber),
              let digits = integers.string(from: whole as NSNumber),
              let range = label.range(of: digits)
        else { return label }
        return label.replacingCharacters(in: range, with: decimal)
    }

    private static func unit(of components: DateComponents) -> NSCalendar.Unit {
        if components.year != nil { return .year }
        if components.month != nil { return .month }
        if components.day != nil { return .day }
        if components.hour != nil { return .hour }
        return .minute
    }
}
