import SwiftUI
import SwiftData
import Scheduling

/// First launch (§6.1): three skippable screens, then the setup sheet.
struct OnboardingView: View {
    @Environment(SyncCoordinator.self) private var sync: SyncCoordinator?

    var settings: SheetsSettings
    var onFinished: () -> Void

    @State private var step: Onboarding.Step = .pages(index: 0)
    @State private var isRevealed = false
    @State private var isSyncing = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            switch step {
            case .pages(let index):
                pages(index)
                    .transition(.opacity)
            case .setup:
                setup
                    .transition(.opacity)
            case .finished:
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .task {
            #if DEBUG
            // `-onboardingPageOnLaunch 2` opens straight on a given page, so each
            // screen can be photographed without tapping through.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-onboardingPageOnLaunch"),
               index + 1 < arguments.count, let page = Int(arguments[index + 1]) {
                step = page >= Onboarding.pageCount ? .setup : .pages(index: max(0, page))
            }
            #endif
        }
    }

    // MARK: - The three screens

    private func pages(_ index: Int) -> some View {
        VStack(spacing: 0) {
            header(index)

            Group {
                switch index {
                case 0: recallStage
                case 1: rateStage
                default: streakStage
                }
            }
            .frame(maxHeight: .infinity)

            Text(title(index))
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            Text(body(index))
                .font(.subheadline)
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 22)

            Button {
                advance()
            } label: {
                Text(index == Onboarding.pageCount - 1 ? "Почати" : "Далі")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            // #87: `onSurface` on a fill of `ink`, not white.
            //
            // `ink` is a *text* colour pressed into service as a button fill. It
            // inverts with the scheme — near-black in light, near-white in dark —
            // while a hardcoded white label does not, so in dark this button was
            // white text on a near-white pill. The label has to invert with it,
            // which is what `surface` is: whatever `ink` is drawn against.
            .background(Palette.ink, in: .rect(cornerRadius: 16))
            .foregroundStyle(Palette.surface)
        }
        .padding(22)
    }

    private func header(_ index: Int) -> some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<Onboarding.pageCount, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Palette.ink : Palette.line)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("Крок \(index + 1) з \(Onboarding.pageCount)")
            Spacer()
            Button("Пропустити") { withAnimation { step = Onboarding.skip(from: step) } }
                .font(.subheadline)
                .tint(Palette.ink2)
        }
        .padding(.bottom, 8)
    }

    /// `LocalizedStringKey`, not `String` (#101).
    ///
    /// `Text(String)` draws the bytes it is handed, and extraction only ever sees
    /// `LocalizedStringKey` literals — so as `String` these three never localised
    /// *and* never reached the catalogue, which is why #93's sweep over the English
    /// table could not see them. #93 fixed two helpers of exactly this shape and
    /// missed these two, because the audit grepped for `Text(title)` and these read
    /// `Text(title(index))`.
    private func title(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0: "Тут не вчать. Тут згадують."
        case 1: "Чесно оціни, як згадалось"
        default: "10 хвилин щодня"
        }
    }

    private func body(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0:
            "Бачиш питання — згадуєш відповідь — торкаєшся картки, щоб перевірити. Саме зусилля згадати і закріплює памʼять."
        case 1:
            "Не згадав — «Знову». Згадав легко — «Легко». Далі застосунок сам вирішує, коли показати картку наступного разу."
        default:
            "Картки, які ви забуваєте, приходитимуть частіше; ті, що знаєте — рідше. Головне — не пропускати дні: пропуски накопичують борг."
        }
    }

    // MARK: - Stage 1: a real card

    private var recallStage: some View {
        VStack(spacing: 14) {
            Text(isRevealed ? "Ось так виглядає відповідь" : "Спочатку спробуйте згадати самі")
                .font(.footnote)
                .foregroundStyle(Palette.ink2)

            // The study screen's own card view, not a picture of one (§6.1).
            FlashcardFace(
                front: "ubiquitous",
                back: "повсюдний",
                example: "The app became ubiquitous within a year.",
                isRevealed: isRevealed,
                // Through the card rather than as an outer `.frame(height:)`,
                // which now only pads around a content-sized surface.
                minHeight: 260
            )
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { withAnimation { isRevealed.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Торкніться, щоб побачити відповідь")
        }
    }

    // MARK: - Stage 2: the real intervals

    private var rateStage: some View {
        VStack(spacing: 18) {
            FlashcardFace(front: "ubiquitous", back: "повсюдний", isRevealed: true,
                          minHeight: 190)
                .frame(maxWidth: .infinity)

            // The study screen's own rating row, drawn the same way it is drawn
            // there. §6.1 asks for "a real card component" rather than a picture
            // of one, and the same argument applies to the buttons: #89 made
            // these solid, and an onboarding that still showed the old pale chips
            // would be teaching a control the app no longer has.
            HStack(spacing: 8) {
                ForEach(Grade.allCases, id: \.self) { grade in
                    VStack(spacing: 5) {
                        Image(systemName: grade.symbolName)
                            .font(.subheadline.weight(.bold))
                            .frame(height: 18)
                        Text(grade.title)
                            .font(.subheadline.weight(.semibold))
                        Text(Self.previews[grade]?.label ?? "—")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(grade.fill, in: .rect(cornerRadius: 16))
                    .foregroundStyle(grade.onFill)
                    .elevated(.low)
                }
            }

            Text("Під кнопкою — коли картка повернеться")
                .font(.footnote)
                .foregroundStyle(Palette.ink2)
        }
    }

    /// The app's own numbers for a brand-new card, not invented ones. If the
    /// scheduler's answer changes, this screen changes with it.
    private static let previews: [Grade: GradePreview] = {
        (try? Scheduler().preview(for: CardSchedulingSnapshot())) ?? [:]
    }()

    // MARK: - Stage 3: the streak

    private var streakStage: some View {
        VStack(spacing: 12) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<14, id: \.self) { index in
                    let isPast = index < 10
                    let isToday = index == 10
                    Text(Self.weekdays[index % 7])
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isPast ? Palette.accentFill
                                : (isToday ? Palette.accentSoft : Palette.paper),
                            in: .rect(cornerRadius: 10)
                        )
                        .foregroundStyle(isPast ? .white : (isToday ? Palette.accent : Palette.line))
                }
            }
            // Illustrative: a first launch has no history to draw, and drawing an
            // empty fortnight would sell the idea badly.
            Text("Приклад: десять днів поспіль")
                .font(.footnote)
                .foregroundStyle(Palette.ink2)
        }
        .accessibilityElement()
        .accessibilityLabel("Приклад календаря: десять днів поспіль")
    }

    /// The week's letters, from the calendar rather than from a list (#101).
    ///
    /// This was `["пн", "вт", "ср", …]`, which hardcoded two things: the language,
    /// and a Monday start. `Calendar` knows both, and knows that a US phone begins
    /// its week on Sunday — so the illustration was wrong in a second way that no
    /// translation would have fixed.
    ///
    /// Rotated by `firstWeekday` because `veryShortWeekdaySymbols` always starts at
    /// Sunday regardless of locale; the calendar's own `firstWeekday` is what says
    /// where the row should begin.
    private static var weekdays: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1        // 1-based, Sunday == 1
        return Array(symbols[first...] + symbols[..<first])
    }

    // MARK: - Setup

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Картки живуть у вашій Google Таблиці. Вставте ключ службового акаунта і посилання на таблицю — і застосунок завантажить їх.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                }
                GoogleConnectionView(settings: settings)
                Section {
                    Button {
                        Task { await finishWithSync() }
                    } label: {
                        HStack {
                            Text(settings.isConfigured ? "Завантажити картки" : "Пропустити поки що")
                                .font(.headline)
                            if isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing)
                } footer: {
                    Text(settings.isConfigured
                         ? "Перша синхронізація може зайняти кілька секунд."
                         : "Це можна зробити пізніше в Налаштуваннях.")
                }
            }
            .navigationTitle("Підключення")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Flow

    private func advance() {
        withAnimation { step = Onboarding.next(after: step) }
    }

    /// §6.1's "first sync". Awaited so Home opens on real decks rather than
    /// briefly claiming there are none.
    private func finishWithSync() async {
        if settings.isConfigured, let sync {
            isSyncing = true
            // Pull-to-refresh rather than app-active: the 10-minute throttle
            // would otherwise be free to swallow the one sync that matters most.
            await sync.performAndWait(.pullToRefresh)
            isSyncing = false
        }
        Onboarding.markCompleted()
        step = .finished
        onFinished()
    }
}
