import SwiftUI
import SwiftData

/// §6.5's Stats tab. Every figure comes from the local store; nothing here
/// touches the network.
struct StatsView: View {
    @Environment(\.modelContext) private var context

    @State private var summary = StatsSummary(
        streak: 0, reviewsLast7: 0, reviewsLast30: 0, retention: nil,
        forecast: [], decks: []
    )

    var body: some View {
        NavigationStack {
            List {
                if summary.hasHistory {
                    headline
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
