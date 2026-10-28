import SwiftUI
import SwiftData
import Scheduling

/// §6.6 — all configuration in one place, including the escape hatches.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncCoordinator.self) private var sync: SyncCoordinator?

    var settings: SheetsSettings
    @Bindable var app: AppSettings
    var onReplayOnboarding: () -> Void

    /// #21's per-deck allowance, listed here because it is the number that decides
    /// how many new cards a day actually arrive — see `newCards`.
    @Query private var decks: [Deck]
    /// #112's two inputs: freezes earned come from the log, freezes spent are
    /// the rows. Both as queries, so the count corrects itself the moment one is
    /// spent rather than at the next time this screen is opened.
    @Query private var logs: [ReviewLog]
    @Query private var freezes: [StreakFreeze]

    @State private var anthropicKey = ""
    @State private var storedAnthropicKey: String?
    @State private var confirmingRedownload = false
    /// Which long-running action is in flight, if any (#101).
    ///
    /// Was a `String?` compared against Ukrainian literals — `busy == "Синхронізація…"`
    /// — so the app's control flow depended on two copies of a phrase matching, and
    /// the phrases showed up in a localisation audit as strings that were never
    /// translated. They were never *displayed* either: they were state wearing a
    /// string's clothes. An enum says what it is and cannot drift.
    private enum Busy: Equatable { case syncing, redownloading }

    @State private var busy: Busy?
    @State private var result: String?
    @State private var exportURL: URL?
    /// #87. Bound to the defaults rather than to `app`, so the change reaches the
    /// root — which holds a *different* `AppSettings` instance — without a
    /// relaunch. See `Appearance`.
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                GoogleConnectionView(settings: settings)
                googleActions
                appearance
                newCards
                scheduling
                reminder
                streak
                autofill
                BackupSettingsView(app: app)
                general
            }
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task {
                storedAnthropicKey = try? AnthropicKeyStore.load()
                app.refreshOverrides()
            }
            .confirmationDialog(
                "Завантажити все заново?",
                isPresented: $confirmingRedownload,
                titleVisibility: .visible
            ) {
                Button("Завантажити заново", role: .destructive) {
                    Task { await redownload() }
                }
            } message: {
                Text("Картки будуть стерті й прочитані з Таблиці ще раз. Розклад повторень збережеться. Незбережені локальні зміни спочатку відправляться в Таблицю.")
            }
            .sheet(item: $exportURL) { url in
                ShareLink(item: url) { Text("Поділитися базою") }
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - New cards

    /// The decks Settings offers a daily allowance for, in Home's order.
    ///
    /// `sortOrder` then `sheetTitle`, the same two keys Home and `DeckSettings.move`
    /// use — decks arriving from a new tab all start at `sortOrder` 0, so ties are
    /// ordinary rather than exotic, and a list that ordered them arbitrarily would
    /// reshuffle itself between launches.
    ///
    /// A deck whose tab is gone is kept for 30 days so it can be recovered (§4.3),
    /// but it has no queue: a stepper for it would set a number nothing reads.
    static func deckRows(_ decks: [Deck]) -> [Deck] {
        decks
            .filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.sheetTitle) < ($1.sortOrder, $1.sheetTitle) }
    }

    /// One stepper per deck, then the ceiling that applies across all of them.
    ///
    /// The order is the point. `QueueBuilder.plan` takes each deck's own allowance
    /// first and only then trims the total, so the ceiling can lower a day but
    /// never raise one — a single deck left at its default of 15 gives 15 whatever
    /// this section's last row says. That is not obvious from a screen showing only
    /// the ceiling, and the per-deck value lived behind a swipe on Home, so the two
    /// numbers now sit together in the order the queue reads them.
    private var newCards: some View {
        Section("Нові картки на день") {
            let rows = Self.deckRows(decks)
            if rows.isEmpty {
                Text("Колоди зʼявляться після першої синхронізації з Таблицею.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            } else {
                ForEach(rows) { deck in
                    // `DeckSettings.binding` rather than `@Bindable`: the latter
                    // mutates the object and never reaches the store, so the value
                    // was back at 15 after the app was killed.
                    //
                    // `sheetTitle` is a `String`, so this is the verbatim overload:
                    // a deck named "Готово" must not pick up a translation.
                    Stepper(value: DeckSettings.binding(deck, \.newCardsPerDay, in: context),
                            in: DeckSettings.newCardsPerDayRange) {
                        LabeledContent(deck.sheetTitle, value: "\(deck.newCardsPerDay)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: $app.globalNewCardCap, in: AppSettings.newCardCapRange, step: 5) {
                    LabeledContent("Стеля на всі колоди", value: "\(app.globalNewCardCap)")
                }
                Text("Скільки нових карток за день ви побачите щонайбільше — сумарно з усіх колод. Кожна колода спершу віддає свою норму, і тільки потім працює ця межа.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
        }
    }

    // MARK: - Appearance

    /// #87. Segmented rather than a navigation row: three options, all short, and
    /// the whole screen changes colour as you touch them — which is the fastest
    /// possible way to see what the setting does.
    private var appearance: some View {
        Section {
            Picker("Тема", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
        } header: {
            Text("Вигляд")
        } footer: {
            Text("«Система» стежить за налаштуванням телефона, зокрема за автоматичним перемиканням увечері.")
        }
    }

    // MARK: - Google

    private var googleActions: some View {
        Section {
            Button {
                Task {
                    busy = .syncing
                    await sync?.performAndWait(.pullToRefresh)
                    app.refreshOverrides()
                    busy = nil
                    result = Localized.string("Синхронізовано.")
                }
            } label: {
                row("Синхронізувати зараз", busy: busy == .syncing)
            }
            .disabled(!settings.isConfigured || busy != nil)

            Button(role: .destructive) {
                confirmingRedownload = true
            } label: {
                row("Завантажити все заново", busy: busy == .redownloading)
            }
            .disabled(!settings.isConfigured || busy != nil)

            if let result {
                Text(result).font(.footnote).foregroundStyle(Palette.ink2)
            }
        } footer: {
            Text("«Завантажити все заново» стирає картки й читає їх із Таблиці ще раз. Розклад повторень зберігається за ідентифікатором картки.")
        }
    }

    // MARK: - Scheduling

    private var scheduling: some View {
        Section("Розклад") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Цільове запамʼятовування") {
                    Text(app.effectiveRetention, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(
                    value: $app.desiredRetention,
                    in: SchedulerConfig.retentionRange,
                    step: 0.01
                )
                .disabled(app.retentionIsSetBySheet)
                if app.retentionIsSetBySheet {
                    Text("Значення задано в аркуші `_meta` — воно має пріоритет.")
                        .font(.caption)
                        .foregroundStyle(Palette.hard)
                } else {
                    Text("Вище — частіші повторення й менше забувань.")
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                }
            }

            Stepper(value: $app.leechThreshold, in: AppSettings.leechThresholdRange) {
                LabeledContent("Поріг «залипань»", value: "\(app.leechThreshold)")
            }

            LabeledContent("Кроки вивчення",
                           value: SchedulerConfig().learningSteps.joined(separator: ", "))
                .foregroundStyle(Palette.ink2)
            LabeledContent("Крок після помилки",
                           value: SchedulerConfig().relearningSteps.joined(separator: ", "))
                .foregroundStyle(Palette.ink2)
            // §5.1: the step count changes how the library clamps w[17]/w[18], so
            // this is not a free UI knob. Shown, not edited, until the optimizer
            // has run on real `_log` data.
            Text("Кроки поки що незмінні: від їх кількості залежить обмеження параметрів FSRS.")
                .font(.caption)
                .foregroundStyle(Palette.ink2)
        }
    }

    // MARK: - Streak (#112)

    /// How many missed days are still survivable.
    ///
    /// Shown here rather than on Home because it is a fact about the rules, not
    /// about today — Home says what to do now, and §2.2 keeps it calm.
    private var streak: some View {
        Section("Серія") {
            LabeledContent("Заморозки", value: "\(freezesAvailable)")
            Text("Заморозка рятує серію за один пропущений день і витрачається сама. Одна нараховується за кожні 7 днів із повтореннями, і більш ніж дві не накопичуються.")
                .font(.caption)
                .foregroundStyle(Palette.ink2)
        }
    }

    private var freezesAvailable: Int {
        let days = Set(logs.filter { $0.rating != 0 }
            .map { Calendar.current.startOfDay(for: $0.reviewedAt) })
        return Freeze.available(reviewDays: days, spent: freezes.count)
    }

    // MARK: - Reminder

    private var reminder: some View {
        Section("Нагадування") {
            Toggle("Щоденне нагадування", isOn: $app.reminderEnabled)
                .onChange(of: app.reminderEnabled) { _, enabled in
                    // Asked when the owner turns it on, not at launch: a
                    // permission prompt before anyone has studied anything is the
                    // surest way to be refused permanently. This one toggle
                    // governs both evening notifications — §5.5's streak reminder
                    // has no separate switch, so this stays the app's only call
                    // site of `requestAuthorization`.
                    Task {
                        if enabled { _ = await SystemNotificationScheduler().requestAuthorization() }
                        await refreshReminders()
                    }
                }
            if app.reminderEnabled {
                DatePicker(
                    "Час",
                    selection: Binding(
                        get: { Self.date(fromMinutes: app.reminderMinutes) },
                        set: { app.reminderMinutes = Self.minutes(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: app.reminderMinutes) { _, _ in
                    Task { await refreshReminders() }
                }

                DatePicker(
                    "Час нагадування про серію",
                    selection: Binding(
                        get: { Self.date(fromMinutes: app.streakReminderMinutes) },
                        set: { app.streakReminderMinutes = Self.minutes(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: app.streakReminderMinutes) { _, _ in
                    Task { await refreshReminders() }
                }

                Text("Якщо серія під загрозою, увечері прийде тільки одне нагадування — про неї.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
        }
    }

    /// One place, so the two pickers and the toggle cannot drift apart.
    private func refreshReminders() async {
        await EveningReminder.refresh(
            in: context, enabled: app.reminderEnabled,
            reminderMinutes: app.reminderMinutes,
            streakMinutes: app.streakReminderMinutes,
            queueConfig: app.queueConfig
        )
    }

    // MARK: - Autofill

    private var autofill: some View {
        Section {
            Toggle("Автозаповнення відповіді", isOn: $app.autofillEnabled)
            if let storedAnthropicKey {
                LabeledContent("Ключ", value: AnthropicKeyStore.masked(storedAnthropicKey))
                    .font(.footnote)
                Button("Видалити ключ", role: .destructive) {
                    try? AnthropicKeyStore.delete()
                    self.storedAnthropicKey = nil
                }
            } else {
                SecureField("Ключ Anthropic API", text: $anthropicKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Зберегти ключ") {
                    try? AnthropicKeyStore.save(anthropicKey)
                    storedAnthropicKey = try? AnthropicKeyStore.load()
                    anthropicKey = ""
                }
                .disabled(anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Модель", text: $app.autofillModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Автозаповнення")
        } footer: {
            Text("Ключ зберігається лише в Keychain і надсилається тільки в api.anthropic.com.")
        }
    }

    // MARK: - General

    private var general: some View {
        Section {
            Button("Показати вступ ще раз") {
                Onboarding.replay()
                dismiss()
                onReplayOnboarding()
            }
            Button("Експортувати локальну базу") { exportURL = try? ModelStore.storeURL() }
            LabeledContent("Версія", value: Self.version)
                .foregroundStyle(Palette.ink2)
        }
    }

    // MARK: - Actions

    private func redownload() async {
        guard let client = try? settings.makeClient() else { return }
        busy = .redownloading
        do {
            let outcome = try await SheetRedownload(client: client).run(in: context)
            result = Localized.string("Оновлено \(outcome.pull.created) карток; розклад збережено для \(outcome.schedulingRestored).")
        } catch {
            result = String(describing: error)
        }
        busy = nil
    }

    /// `LocalizedStringKey`, not `String` (#93).
    ///
    /// `Text(String)` does not localise — it draws the bytes it is handed. This
    /// helper took a `String`, so its two Ukrainian literals reached the screen
    /// verbatim in every language, and never appeared in the catalogue either,
    /// because extraction only sees `LocalizedStringKey` literals. That is why #38's
    /// sweep of the whole app missed them. Taking the key type makes the mistake a
    /// compile error rather than something you have to notice in a screenshot.
    private func row(_ title: LocalizedStringKey, busy: Bool) -> some View {
        HStack {
            Text(title)
            if busy {
                Spacer()
                ProgressView()
            }
        }
    }

    static var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    static func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now
        ) ?? .now
    }

    static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
