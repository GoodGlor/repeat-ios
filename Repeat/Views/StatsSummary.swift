import Foundation
import SwiftData
import Scheduling

/// Everything §6.5 shows, computed once from local data.
///
/// A value type rather than a view model: the acceptance criterion is that every
/// figure comes from the local `ReviewLog` and `Card` with no network call, and
/// the cleanest way to hold that is for the whole screen to be a function of two
/// arrays.
struct StatsSummary: Equatable {

    struct ForecastDay: Equatable, Identifiable {
        var date: Date
        var due: Int
        var id: Date { date }
    }

    struct DeckLine: Equatable, Identifiable {
        var title: String
        var colorHex: String
        var total: Int
        var due: Int
        var newCards: Int
        var id: String { title }
    }

    var streak: Int
    var reviewsLast7: Int
    var reviewsLast30: Int
    /// (Good + Easy) ÷ all, over the last 30 days. `nil` when there is nothing to
    /// divide — a screen that says "0 %" to someone who has not reviewed
    /// anything yet is telling them they are failing.
    var retention: Double?
    /// Today first, then the next six days.
    var forecast: [ForecastDay]
    var decks: [DeckLine]

    var hasHistory: Bool { reviewsLast30 > 0 || streak > 0 }
    /// The tallest bar, for scaling. At least 1 so a week with nothing due draws
    /// a flat baseline rather than dividing by zero.
    var forecastPeak: Int { max(1, forecast.map(\.due).max() ?? 1) }

    static let forecastDays = 7
    static let retentionWindowDays = 30

    /// Counts every card figure in SQL, without loading a single `Card`.
    ///
    /// The obvious version — walk `deck.notes`, then `note.cards` — measured
    /// **2.4 seconds** on 10k cards against §6.5's 300 ms budget. Prefetching the
    /// relationships barely helped: the breakdown was 0.60 s to fetch the cards
    /// and **1.18 s just to read `card.note.deletedAt` ten thousand times**,
    /// because each one faults a separate object. The card's own properties cost
    /// 0.007 s, which is the tell — it is not the arithmetic that is slow, it is
    /// materialising rows to do it.
    ///
    /// `fetchCount` sends the whole question to SQLite and gets back an integer.
    /// Roughly twenty small counts replace twenty thousand faults.
    static func load(from context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> StatsSummary {
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        return StatsSummary(
            streak: Streak.length(reviewDates: reviewDates(logs), now: now, calendar: calendar),
            reviewsLast7: countReviews(logs, days: 7, now: now, calendar: calendar),
            reviewsLast30: countReviews(logs, days: retentionWindowDays, now: now, calendar: calendar),
            retention: retention(logs, now: now, calendar: calendar),
            forecast: forecast(in: context, now: now, calendar: calendar),
            decks: deckLines(in: context, decks: decks, now: now)
        )
    }

    /// Why `lastReview != nil` and not `state != .new`.
    ///
    /// SwiftData refuses a predicate that captures a `SchedulingState` at all —
    /// *"Captured/constant values of type 'SchedulingState' are not supported"* —
    /// because the enum is declared in another module and is not one of the
    /// schema's known value types. Equality is rejected as flatly as inequality,
    /// so there is no phrasing of the state test that reaches SQL.
    ///
    /// `lastReview` is the stored, queryable equivalent, and exactly equivalent:
    /// a card is `.new` until its first rating, and that rating is what sets
    /// `lastReview`. The two always move together because they are written from
    /// one snapshot — by `rate`, by undo, and by a restore. That is an invariant
    /// rather than a coincidence, so `StatsTests` asserts it directly instead of
    /// leaving this comment to be believed.
    ///
    /// The deck's own `deletedAt` is not a clause either: a deck that disappears
    /// from the Sheet has every one of its cards suspended by the reconciler
    /// (§4.3), so `!isSuspended` already covers it.

    /// The seven day boundaries the forecast buckets against, as plain dates.
    /// Computed once: `Calendar` arithmetic inside a per-card loop is its own
    /// measurable cost.
    static func dayBoundaries(now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0...forecastDays).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
    }

    /// §6.5's chart, as `forecastDays` SQL counts.
    ///
    /// Today's bucket has no lower bound, so everything already owed lands there
    /// however overdue — a three-week-old backlog is due today, and drawing it on
    /// its original date would put it off the left of the chart.
    static func forecast(
        in context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ForecastDay] {
        let bounds = dayBoundaries(now: now, calendar: calendar)
        guard bounds.count > forecastDays else { return [] }

        return (0..<forecastDays).map { index in
            let upper = bounds[index + 1]
            let lower = index == 0 ? Date.distantPast : bounds[index]
            let descriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { card in
                card.due >= lower
                    && card.due < upper
                    && !card.isSuspended
                    && card.lastReview != nil
                    && card.note.deletedAt == nil
            })
            return ForecastDay(date: bounds[index], due: (try? context.fetchCount(descriptor)) ?? 0)
        }
    }

    /// Three counts per deck, matched on the worksheet name — the identity used
    /// everywhere else in the app.
    static func deckLines(
        in context: ModelContext,
        decks: [Deck],
        now: Date = .now
    ) -> [DeckLine] {
        decks
            .filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
            .map { deck in
                let title = deck.sheetTitle
                let base = #Predicate<Card> { card in
                    !card.isSuspended
                        && card.note.deletedAt == nil
                        && card.note.deck.sheetTitle == title
                }
                let fresh = #Predicate<Card> { card in
                    !card.isSuspended
                        && card.note.deletedAt == nil
                        && card.note.deck.sheetTitle == title
                        && card.lastReview == nil
                }
                let due = #Predicate<Card> { card in
                    !card.isSuspended
                        && card.note.deck.sheetTitle == title
                        && card.lastReview != nil
                        && card.due <= now
                }
                func count(_ predicate: Predicate<Card>) -> Int {
                    (try? context.fetchCount(FetchDescriptor<Card>(predicate: predicate))) ?? 0
                }
                return DeckLine(title: title, colorHex: deck.colorHex,
                                total: count(base), due: count(due), newCards: count(fresh))
            }
    }

    // MARK: - Log arithmetic

    /// Rating 0 marks an undo of an already-uploaded review (§5.5). It is not a
    /// review: counting it would inflate the streak and dilute retention.
    static func reviewDates(_ logs: [ReviewLog]) -> [Date] {
        logs.filter { $0.rating != 0 }.map(\.reviewedAt)
    }

    static func countReviews(_ logs: [ReviewLog], days: Int, now: Date, calendar: Calendar) -> Int {
        let cutoff = since(days, now: now, calendar: calendar)
        return logs.filter { $0.rating != 0 && $0.reviewedAt >= cutoff }.count
    }

    /// (Good + Easy) ÷ all, over the last 30 days.
    static func retention(_ logs: [ReviewLog], now: Date, calendar: Calendar) -> Double? {
        let cutoff = since(retentionWindowDays, now: now, calendar: calendar)
        let window = logs.filter { $0.rating != 0 && $0.reviewedAt >= cutoff }
        guard !window.isEmpty else { return nil }
        let remembered = window.filter {
            $0.rating == Grade.good.rawValue || $0.rating == Grade.easy.rawValue
        }
        return Double(remembered.count) / Double(window.count)
    }

    private static func since(_ days: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }

    // MARK: - Formatting

    /// Ukrainian plurals. "1 днів" is the kind of detail that makes an app feel
    /// machine-made.
    ///
    /// The singular is the catalogue *key*; `Localizable.xcstrings` carries the
    /// one / few / many variants, so the 11–14 exception and the 21-is-singular
    /// rule come from CLDR rather than from arithmetic here. That is the whole
    /// point of #38 — the rule was implemented by hand in three places, and one
    /// of them had it wrong.
    /// `locale` defaults to the device's. It is a parameter only so a test can
    /// pin a language: the app is localised now, so "what does this say" has no
    /// answer without one.
    static func dayCount(_ days: Int, locale: Locale = .current) -> String {
        Localized.string("\(days) день", locale: locale)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    /// Single letter, so seven of them fit without wrapping on the narrowest
    /// iPhone.
    static func weekdayInitial(_ date: Date, calendar: Calendar = .current) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }
}
