import SwiftUI
import SwiftData

/// §6.5's Stats tab. Every figure comes from the local store; nothing here
/// touches the network.
struct StatsView: View {
    @Environment(\.modelContext) private var context

    @State private var summary = StatsSummary(
        streak: 0, reviewsLast7: 0, reviewsLast30: 0, retention: nil,
        forecast: [], decks: [], records: .empty, heatmap: Heatmap.make(reviewDates: []),
        learnedThisMonth: [], achievements: []
    )

    var body: some View {
        NavigationStack {
            List {
                if summary.hasHistory {
                    headline
                    heatmapSection
                    recordsSection
                    learnedSection
                    achievementsSection
                    forecastSection
                } else {
                    empty
                }
                deckSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.bg.ignoresSafeArea())
            .navigationTitle("Статистика")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Recomputed on each appearance rather than driven by `@Query`: this
        // screen reads every card in the store, and doing that on every
        // insert during a sync would make the whole app stutter.
        .task { reload() }
    }

    private func reload() {
        summary = StatsSummary.load(from: context)
    }

    // MARK: - Headline numbers

    private var headline: some View {
        Section {
            VStack(spacing: 14) {
                // §5.7 (#113). Hidden until something has been earned: "Рівень 0"
                // is a true answer and a useless one, and #89's whole point was
                // that the app does not talk when it has nothing to say.
                if summary.xp > 0 {
                    levelChip
                }
                HStack(spacing: 10) {
                    metric(title: Localized.string("Серія"), value: StatsSummary.dayCount(summary.streak),
                           tint: Palette.accent)
                    metric(title: Localized.string("Памʼятається"),
                           value: summary.retention.map(StatsSummary.percent) ?? "—",
                           tint: Palette.good)
                }
                HStack(spacing: 10) {
                    metric(title: Localized.string("За 7 днів"), value: "\(summary.reviewsLast7)", tint: Palette.ink)
                    metric(title: Localized.string("За 30 днів"), value: "\(summary.reviewsLast30)", tint: Palette.ink)
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 22, bottom: 6, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Small on purpose. §5.7 is the one part of M9 that measures taps rather
    /// than vocabulary, so it gets a chip rather than one of the metric tiles —
    /// it should not look like it is telling you how much you know.
    private var levelChip: some View {
        let progress = XP.progress(xp: summary.xp)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.up.circle.fill")
                .font(.caption)
            Text("Рівень \(XP.level(xp: summary.xp))")
                .font(.caption.weight(.semibold))
            Text("\(progress.into) / \(progress.outOf)")
                .font(.caption2)
                .foregroundStyle(Palette.ink2)
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.accentSoft, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.level")
        .accessibilityLabel(Localized.string("Рівень \(XP.level(xp: summary.xp))")
                            + ", \(progress.into) / \(progress.outOf)")
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.ink2)
            Text(value)
                .scaledFont(26, weight: .bold, relativeTo: .title2)
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
    }

    // MARK: - The year

    private var heatmapSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Активність за рік")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                HeatmapView(heatmap: summary.heatmap)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Records

    private var recordsSection: some View {
        Section {
            VStack(spacing: 0) {
                recordRow(Localized.string("Найдовша серія"),
                          value: StatsSummary.dayCount(summary.records.longestStreak),
                          detail: nil,
                          id: "stats.record.streak")
                Divider().overlay(Palette.line).padding(.leading, 16)
                recordRow(Localized.string("Найкращий день"),
                          value: summary.records.bestDay.map { StatsSummary.cardCount($0.count) } ?? "—",
                          detail: summary.records.bestDay.map {
                              $0.start.formatted(date: .abbreviated, time: .omitted)
                          },
                          id: "stats.record.day")
                Divider().overlay(Palette.line).padding(.leading, 16)
                recordRow(Localized.string("Найкращий тиждень"),
                          value: summary.records.bestWeek.map { StatsSummary.cardCount($0.count) } ?? "—",
                          detail: summary.records.bestWeek.map { StatsSummary.weekSpan(from: $0.start) },
                          id: "stats.record.week")
            }
            .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Рекорди")
                .font(.headline)
                .textCase(nil)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 22)
        }
    }

    /// One record. The value is in the streak's colour — the palette's "earned"
    /// amber, measured on `paper` in both schemes — and VoiceOver hears the row
    /// as one thing, which is also what a UI test reads.
    private func recordRow(_ title: String, value: String, detail: String?, id: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                }
            }
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.streak)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
        .accessibilityIdentifier(id)
    }

    // MARK: - Learned this month

    /// §5.3. For a vocabulary app this list is the honest reward; the header
    /// counts the month, the rows name it, newest first, and a long month is
    /// cut at `Mastery.listLimit` with the remainder counted rather than drawn.
    private var learnedSection: some View {
        let words = summary.learnedThisMonth
        let shown = Array(words.prefix(Mastery.listLimit))
        let rest = words.count - shown.count
        return Section {
            VStack(spacing: 0) {
                if words.isEmpty {
                    // "three weeks" is `Mastery.knownStability`; change both together.
                    Text("Поки нічого. Слово стає вивченим, коли інтервал між повтореннями сягає трьох тижнів.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(shown) { word in
                        learnedRow(word)
                        if word.id != shown.last?.id {
                            Divider().overlay(Palette.line).padding(.leading, 16)
                        }
                    }
                    if rest > 0 {
                        Divider().overlay(Palette.line).padding(.leading, 16)
                        Text(Localized.string("і ще \(rest)"))
                            .font(.caption)
                            .foregroundStyle(Palette.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            HStack {
                Text("Вивчено цього місяця")
                Spacer()
                if !words.isEmpty {
                    Text("\(words.count)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.streak)
                        .accessibilityIdentifier("stats.learned.count")
                }
            }
            .font(.headline)
            .textCase(nil)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 22)
        }
    }

    private func learnedRow(_ word: Mastery.LearnedWord) -> some View {
        HStack(spacing: 12) {
            Text(word.front)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            Text(word.learnedAt.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption)
                .foregroundStyle(Palette.ink2)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.learned.\(word.front)")
    }

    // MARK: - Achievements

    /// §5.4. Earned tiles carry the day they were first shown; locked ones say
    /// what it takes. Two columns on a phone, one at the accessibility sizes —
    /// the grid adapts and the tiles have no fixed height.
    private var achievementsSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(summary.achievements) { item in
                    BadgeTile(badge: item.badge, earnedOn: item.earnedOn, style: .grid)
                }
            }
            .accessibilityIdentifier("stats.badges")
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            HStack {
                Text("Досягнення")
                Spacer()
                Text(Localized.string("\(summary.earnedCount) з \(summary.achievements.count)"))
                    .monospacedDigit()
                    .foregroundStyle(Palette.streak)
                    .accessibilityIdentifier("stats.badges.count")
            }
            .font(.headline)
            .textCase(nil)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 22)
        }
    }

    // MARK: - Forecast

    /// Hand-drawn rather than Swift Charts: seven bars is less code than
    /// configuring a chart to stop looking like a chart, and it keeps the palette
    /// consistent with the rest of the app.
    private var forecastSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Наступні 7 днів")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)

                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(summary.forecast.enumerated()), id: \.element.id) { index, day in
                        bar(day, isToday: index == 0)
                    }
                }
                .frame(height: 128)

                Text("Сьогодні сюди входить усе прострочене.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func bar(_ day: StatsSummary.ForecastDay, isToday: Bool) -> some View {
        VStack(spacing: 6) {
            Text("\(day.due)")
                .font(.caption2)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geometry in
                VStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isToday ? Palette.accentFill : Palette.accentSoft)
                        // A day with nothing due still draws a sliver, so the
                        // axis reads as seven days rather than four.
                        .frame(height: max(3, geometry.size.height
                                           * CGFloat(day.due) / CGFloat(summary.forecastPeak)))
                }
            }
            Text(StatsSummary.weekdayInitial(day.date))
                .font(.caption2.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Palette.ink : Palette.ink2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.due)")
    }

    // MARK: - Decks

    @ViewBuilder
    private var deckSection: some View {
        if !summary.decks.isEmpty {
            Section {
                VStack(spacing: 0) {
                    ForEach(summary.decks) { deck in
                        deckRow(deck)
                        if deck.id != summary.decks.last?.id {
                            Divider().overlay(Palette.line).padding(.leading, 16)
                        }
                    }
                }
                .background(Palette.paper, in: .rect(cornerRadius: Palette.radius))
                .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 24, trailing: 22))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Колоди")
                    .font(.headline)
                    .textCase(nil)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 22)
            }
        }
    }

    private func deckRow(_ deck: StatsSummary.DeckLine) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: deck.colorHex) ?? Palette.accent)
                .frame(width: 5, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text("\(deck.total) карток · \(deck.newCards) нових")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            Spacer()
            Text("\(deck.due)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(deck.due > 0 ? Palette.accent : Palette.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(deck.due > 0 ? Palette.accentSoft : Palette.bg, in: .capsule)
        }
        .padding(16)
    }

    // MARK: - Nothing yet

    private var empty: some View {
        Section {
            ContentUnavailableView(
                "Ще немає даних",
                systemImage: "chart.bar",
                description: Text("Проведи першу сесію — і тут зʼявляться серія, відсоток запамʼятовування та прогноз на тиждень.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
