import SwiftUI

extension Achievements.Badge {
    /// The card's names (#107's catalogue), capitalised for a tile.
    var title: String {
        switch self {
        case .firstSession: Localized.string("Перша сесія")
        case .streak7: Localized.string("Серія 7")
        case .streak30: Localized.string("Серія 30")
        case .streak100: Localized.string("Серія 100")
        case .reviews100: Localized.string("100 повторень")
        case .reviews1000: Localized.string("1 000 повторень")
        case .reviews10000: Localized.string("10 000 повторень")
        case .perfectSession: Localized.string("Ідеальна сесія")
        case .earlyBird: Localized.string("Рання пташка")
        case .nightOwl: Localized.string("Сова")
        case .allDecksGreen: Localized.string("Усі колоди зелені")
        case .words100: Localized.string("100 слів вивчено")
        }
    }

    /// What it takes, in one clause — the locked tile's subtitle. The numbers
    /// are `Achievements`' constants spelled out; change both together.
    var condition: String {
        switch self {
        case .firstSession: Localized.string("Завершіть першу сесію")
        case .streak7: Localized.string("7 днів поспіль")
        case .streak30: Localized.string("30 днів поспіль")
        case .streak100: Localized.string("100 днів поспіль")
        case .reviews100: Localized.string("100 повторень загалом")
        case .reviews1000: Localized.string("1 000 повторень загалом")
        case .reviews10000: Localized.string("10 000 повторень загалом")
        case .perfectSession: Localized.string("Сесія з 10 і більше карток без «Знову»")
        case .earlyBird: Localized.string("Сесія, завершена між 4:00 і 8:00")
        case .nightOwl: Localized.string("Сесія, завершена після 23:00")
        case .allDecksGreen: Localized.string("Після сесії в жодній колоді нічого не лишилось на сьогодні")
        case .words100: Localized.string("100 вивчених слів")
        }
    }

    /// The title as a notification says it (#109). The streaks spell out their
    /// unit: "Серія 30" on a lock screen has no grid around it to explain
    /// itself. The rest are their grid title — same key, one catalogue entry.
    ///
    /// Unlike `accessibilityText`'s `locale`, which governs only the date and
    /// the casing, this `locale` governs the string itself — `body(for:locale:)`
    /// interpolates the result into another localized string, so both have to
    /// resolve in the same language or the sentence would be a mix of two.
    func notificationTitle(locale: Locale = .current) -> String {
        switch self {
        case .firstSession: Localized.string("Перша сесія", locale: locale)
        case .streak7: Localized.string("Серія 7 днів", locale: locale)
        case .streak30: Localized.string("Серія 30 днів", locale: locale)
        case .streak100: Localized.string("Серія 100 днів", locale: locale)
        case .reviews100: Localized.string("100 повторень", locale: locale)
        case .reviews1000: Localized.string("1 000 повторень", locale: locale)
        case .reviews10000: Localized.string("10 000 повторень", locale: locale)
        case .perfectSession: Localized.string("Ідеальна сесія", locale: locale)
        case .earlyBird: Localized.string("Рання пташка", locale: locale)
        case .nightOwl: Localized.string("Сова", locale: locale)
        case .allDecksGreen: Localized.string("Усі колоди зелені", locale: locale)
        case .words100: Localized.string("100 слів вивчено", locale: locale)
        }
    }

    var symbol: String {
        switch self {
        case .firstSession: "flag.fill"
        case .streak7, .streak30, .streak100: "flame.fill"
        case .reviews100, .reviews1000, .reviews10000: "rectangle.on.rectangle"
        case .perfectSession: "star.fill"
        case .earlyBird: "sunrise.fill"
        case .nightOwl: "moon.stars.fill"
        case .allDecksGreen: "checkmark.seal.fill"
        case .words100: "book.fill"
        }
    }
}

/// One badge, earned or locked (§5.4). `grid` is the Stats tile — symbol,
/// title, and either the day it was earned or the condition; `compact` is the
/// Done screen's small tile, the record capsule's look.
///
/// Earned is the palette's amber, the colour the records already own; locked
/// is outline only. Nothing here has a fixed height: at AX5 the text wraps and
/// the tile grows (handoff, *things that were wrong*).
struct BadgeTile: View {
    enum Style { case grid, compact }

    let badge: Achievements.Badge
    var earnedOn: Date? = nil
    var style: Style = .grid
    var identifierPrefix: String = "badge"

    private var earned: Bool { earnedOn != nil }

    var body: some View {
        Group {
            switch style {
            case .grid: gridTile
            case .compact: compactTile
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(for: badge, earnedOn: earnedOn))
        .accessibilityIdentifier("\(identifierPrefix).\(badge.rawValue)")
    }

    private var gridTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                symbolDisc
                Text(badge.title)
                    .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(earned ? Palette.ink : Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(subtitle)
                .scaledFont(12, relativeTo: .caption)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(earned ? Palette.paper : Color.clear, in: .rect(cornerRadius: Palette.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Palette.radius)
                .stroke(earned ? Palette.streak.opacity(0.35) : Palette.line, lineWidth: 1)
        )
    }

    private var compactTile: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.symbol)
                .scaledFont(13, weight: .semibold, relativeTo: .caption)
            Text(badge.title)
                .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                .multilineTextAlignment(.leading)
                // #108 review: `lineLimit(2)` truncated a three-word title in an
                // AX5 grid column. The capsule grows instead.
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.streak)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.streakSoft, in: Capsule())
    }

    private var symbolDisc: some View {
        Image(systemName: badge.symbol)
            .scaledFont(14, weight: .bold, relativeTo: .caption)
            .foregroundStyle(earned ? Palette.streak : Palette.ink2)
            .frame(width: 34, height: 34)
            .background(
                Circle().fill(earned ? Palette.streakSoft : Color.clear)
            )
            .overlay(Circle().stroke(earned ? Color.clear : Palette.line, lineWidth: 1))
    }

    private var subtitle: String {
        if let earnedOn { return Self.earnedLine(earnedOn) }
        return badge.condition
    }

    /// "здобуто 5 січ. 2027 р." — the grid's subtitle and half of VoiceOver's sentence.
    static func earnedLine(_ date: Date, locale: Locale = .current) -> String {
        Localized.string("здобуто \(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))",
                         locale: locale)
    }

    /// "<name>, здобуто <date>" or "<name>, <condition>" (card #108's acceptance).
    ///
    /// `locale` governs the **date and the casing only**. The words come from
    /// `badge.title` and `badge.condition`, which call `Localized.string` without
    /// a locale and so resolve through the app's own bundle language. Passing
    /// `en_US` here therefore gives an English date and an English lowercasing
    /// rule inside Ukrainian copy — enough to pin a format in a test, and not a
    /// translation.
    static func accessibilityText(for badge: Achievements.Badge, earnedOn: Date?, locale: Locale = .current) -> String {
        let name = badge.title
        if let earnedOn { return "\(name), \(earnedLine(earnedOn, locale: locale))" }
        let condition = badge.condition
        let lowered = condition.prefix(1).lowercased(with: locale) + condition.dropFirst()
        return "\(name), \(lowered)"
    }
}
