import SwiftUI
import SwiftData
import Scheduling

/// The backup section of Settings (§6.6, §8).
///
/// Restoring rewinds every card's schedule, so it asks first and says exactly
/// what it did afterwards — "відновлено 412" is checkable, "готово" is not.
struct BackupSettingsView: View {
    @Environment(\.modelContext) private var context

    var directory: URL = BackupStore.directory
    var app: AppSettings = AppSettings()

    @State private var backups: [URL] = []
    @State private var pendingRestore: URL?
    @State private var message: String?
    @State private var isWorking = false
    @State private var pendingRebuild: LogReplay.Parse?
    @State private var rebuildMessage: String?
    @State private var isRebuilding = false

    var body: some View {
        snapshots
        rebuild
    }

    // MARK: - Snapshots

    private var snapshots: some View {
        Section {
            if backups.isEmpty {
                Text("Копій ще немає. Перша створюється автоматично раз на день.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
            } else {
                ForEach(backups, id: \.self) { url in
                    Button { pendingRestore = url } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(for: url))
                            if let subtitle = Self.subtitle(for: url) {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Palette.ink2)
                            }
                        }
                    }
                }
            }

            Button {
                backUpNow()
            } label: {
                HStack {
                    Text("Створити копію зараз")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
            }
        } header: {
            Text("Резервні копії розкладу")
        } footer: {
            Text("Зберігаються останні \(BackupStore.keepCount) копій. Вони потрапляють у резервну копію iPhone, тож переживають втрату пристрою. Відновлення повертає лише розклад — тексти карток лишаються з Таблиці.")
        }
        .task { reload() }
        .confirmationDialog(
            "Відновити розклад із цієї копії?",
            isPresented: .init(get: { pendingRestore != nil },
                               set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Відновити", role: .destructive) {
                if let url = pendingRestore { restore(url) }
                pendingRestore = nil
            }
            Button("Скасувати", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Поточні дати повторень будуть замінені. Картки, доданої після копії, це не торкнеться.")
        }
    }

    // MARK: - Rebuild from `_log`

    private var rebuild: some View {
        Section {
            // Destructive, and styled like the other destructive action in this
            // screen: "Завантажити все заново" is red, and a rebuild replaces
            // strictly more. A green row here read as an ordinary action.
            Button(role: .destructive) {
                Task { await loadRebuildPreview() }
            } label: {
                HStack {
                    Text("Перебудувати розклад із журналу")
                    if isRebuilding {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRebuilding)

            if let rebuildMessage {
                Text(rebuildMessage)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
            }
        } header: {
            Text("Відновлення з Таблиці")
        } footer: {
            Text("Журнал «_log» у Таблиці містить усю історію повторень, тож розклад можна відтворити з нуля — навіть якщо телефон загублено. Перед заміною автоматично створюється резервна копія.")
        }
        .confirmationDialog(
            "Перебудувати розклад?",
            isPresented: .init(get: { pendingRebuild != nil },
                               set: { if !$0 { pendingRebuild = nil } }),
            titleVisibility: .visible
        ) {
            Button("Перебудувати", role: .destructive) {
                if let parse = pendingRebuild { Task { await applyRebuild(parse) } }
                pendingRebuild = nil
            }
            Button("Скасувати", role: .cancel) { pendingRebuild = nil }
        } message: {
            Text(Self.confirmation(for: pendingRebuild))
        }
    }

    /// Names the count before anything is replaced, because "all local scheduling
    /// state is replaced" is only a fair warning if the owner can see what it is
    /// being replaced *with*. An empty log is the case worth spelling out — it
    /// would silently reset every card to new.
    static func confirmation(for parse: LogReplay.Parse?) -> String {
        guard let parse else { return "" }
        if parse.reviewCount == 0 {
            return Localized.string("У журналі немає жодного повторення. Весь локальний розклад буде скинуто, і всі картки стануть новими.")
        }
        var text = Localized.string("Увесь локальний розклад буде замінено. Повторень для відтворення: \(parse.reviewCount).")
        if parse.malformed > 0 {
            text += Localized.string(" Нечитних рядків: \(parse.malformed) — їх буде пропущено.")
        }
        return text
    }

    private func loadRebuildPreview() async {
        isRebuilding = true
        rebuildMessage = nil
        do {
            let client = try SheetsSettings.makeClient()
            pendingRebuild = try await RebuildScheduling.preview(client: client)
        } catch {
            rebuildMessage = String(describing: error)
        }
        isRebuilding = false
    }

    private func applyRebuild(_ parse: LogReplay.Parse) async {
        isRebuilding = true
        do {
            let report = try await RebuildScheduling.apply(
                parse, in: context, config: app.schedulerConfig
            )
            var parts = [Localized.string("Відтворено карток: \(report.cardsRebuilt)")]
            if report.cardsReset > 0 { parts.append(Localized.string("скинуто до нових: \(report.cardsReset)")) }
            if report.unknownCards > 0 { parts.append(Localized.string("невідомих у Таблиці: \(report.unknownCards)")) }
            rebuildMessage = parts.joined(separator: ", ") + "."
            reload()
        } catch {
            rebuildMessage = String(describing: error)
        }
        isRebuilding = false
    }

    // MARK: - Actions

    private func reload() {
        backups = BackupStore.list(in: directory)
    }

    private func backUpNow() {
        isWorking = true
        defer { isWorking = false }
        do {
            // `run`, not `runIfNeeded`: the owner pressed a button, and "nothing
            // happened because today's already exists" is not an answer.
            let url = try BackupRunner.run(in: context, directory: directory)
            let count = (try? BackupStore.read(url).cardCount) ?? 0
            message = Localized.string("Збережено карток: \(count).")
            reload()
        } catch {
            message = String(describing: error)
        }
    }

    private func restore(_ url: URL) {
        do {
            let backup = try BackupStore.read(url)
            let report = try BackupRunner.restore(backup, in: context)
            var parts = [Localized.string("Відновлено карток: \(report.restored)")]
            if report.missing > 0 { parts.append(Localized.string("зниклих: \(report.missing)")) }
            if report.untouched > 0 { parts.append(Localized.string("новіших залишено: \(report.untouched)")) }
            message = parts.joined(separator: ", ") + "."
        } catch {
            message = String(describing: error)
        }
    }

    // MARK: - Formatting

    /// Unpinned by #38, as its own comment asked for.
    ///
    /// This was `Locale(identifier: "uk_UA")` because the app claimed English in
    /// its bundle while every string was Ukrainian, so `Locale.current` resolved
    /// to `en` and this row read "2 September 2026" under a Ukrainian header.
    /// With `developmentLanguage: uk` and a string catalogue, iOS resolves it —
    /// and a reader whose phone is English now gets English copy *and* English
    /// dates, which is the point of formatting through `Locale` rather than
    /// hardcoding one (§8).
    static func title(for url: URL, locale: Locale = .current) -> String {
        guard let date = BackupStore.date(fromFilename: url.lastPathComponent) else {
            return url.lastPathComponent
        }
        return date.formatted(.dateTime.day().month(.wide).year().locale(locale))
    }

    /// Size rather than card count: counting means decoding every file on every
    /// render of a Form, and a Form body is evaluated a lot.
    static func subtitle(for url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatStyle(style: .file).format(Int64(size))
    }
}
