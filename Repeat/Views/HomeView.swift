import SwiftUI
import SwiftData
import Scheduling

/// The launch surface (§6.2): what is due, and one tap to start.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncCoordinator.self) private var sync: SyncCoordinator?
    /// #98. `.task` fires when the view appears and when a tab switch brings it
    /// back, but **not** when the app returns from the background — which is
    /// exactly when the day's cards arrive.
    @Environment(\.scenePhase) private var scenePhase

    /// Switches to the Add tab (§6.2's "Нова картка" link).
    var onAddCard: (() -> Void)?
    /// Reopens onboarding after Settings clears the flag (§6.6).
    var onReplayOnboarding: (() -> Void)?
    /// Set by `repeat://study` (§7.1). A token rather than a Bool so a second tap
    /// while the app is already open still starts a session.
    var studyRequest: UUID?

    @Query private var decks: [Deck]
    @Query private var logs: [ReviewLog]

    @State private var session: StudySession?
    @State private var deckSettings: Deck?
    @State private var showingConnection = false
    @State private var settings = SheetsSettings()
    @State private var app = AppSettings()
    /// Re-read on every appearance and after each session, so the count on the
    /// button is the plan the button will actually run.
    @State private var plan = QueuePlan(cardIds: [], dueReviewCount: 0, newCardCount: 0,
                                        secondsPerCard: 20, studyDay: .now)
    @State private var tick = Date.now
    /// §5.4. Recomputed with the plan, so it follows a session that just turned
    /// a card into a leech.
    @State private var leeches: [Card] = []
    @State private var rewriting: Note?
    @State private var deleting: Note?

    private var summary: HomeSummary {
        HomeSummary.make(decks: decks, plan: plan, logsToday: logsToday, now: tick)
    }

    private var logsToday: [ReviewLog] {
        logs.filter { Calendar.current.isDateInToday($0.reviewedAt) }
    }

    /// §5.3. Derived from the plan on screen rather than stored, so it appears
    /// and disappears with the backlog itself — there is no dismissal flag to get
    /// out of step with reality.
    private var catchUpOffer: CatchUp.Offer? {
        CatchUp.offer(dueReviews: plan.dueReviewCount, logs: logs, now: tick)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                // Defensive, not a fix for anything observed: at
                                // AX5 these two lines come within a few points of
                                // the settings button, and a longer greeting in
                                // another locale would reach it.
                                Text(summary.greeting)
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.onSurfaceMuted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text("Сьогодні")
                                    .font(.largeTitle.bold())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            // Accepts the offered width rather than demanding
                            // its ideal one, which is what lets the two lines
                            // above actually shrink. Replaces the `Spacer` that
                            // used to sit here doing the same job.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // #89: the streak was only ever visible after a
                            // session, on Stats and on the Done screen. It is the
                            // one number on Home that is *earned*, and putting it
                            // where the screen starts is most of what fills the
                            // empty top half.
                            StreakChip(days: streak)
                                .padding(.trailing, 4)
                            Button { showingConnection = true } label: {
                                Image(systemName: "gearshape")
                                    // Fixed size inside a fixed circle, like the
                                    // study screen's bar buttons. As `.title3` it
                                    // scaled with Dynamic Type and at AX5 grew
                                    // straight through the circle behind it — the
                                    // glyph ended up larger than its own button,
                                    // which only became visible once #89 gave the
                                    // button a background to grow out of. 44pt is
                                    // the minimum tap target; 36 was under it.
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Palette.onSurfaceMuted)
                                    .frame(width: 44, height: 44)
                                    .background(Palette.surfaceRaised, in: Circle())
                                    .elevated(.low)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Налаштування")
                        }
                        .padding(.bottom, 18)
                        todayCard
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 22, bottom: 14, trailing: 22))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                NeedsAttentionCard(
                    status: sync?.status ?? .notConfigured,
                    onOpenSettings: { showingConnection = true },
                    leeches: leeches,
                    onRewrite: { rewriting = $0 },
                    onDelete: { deleting = $0 }
                )

                if let catchUpOffer {
                    Section {
                        CatchUpCard(offer: catchUpOffer, onAccept: spreadBacklog)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 14, trailing: 22))
                    }
                }

                Section {
                    deckRows
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Колоди")
                            .font(.headline)
                            .textCase(nil)
                            .foregroundStyle(Palette.onSurface)
                        Spacer()
                        if onAddCard != nil {
                            Button("Нова картка") { onAddCard?() }
                                .font(.subheadline)
                                .textCase(nil)
                                .tint(Palette.accent)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)
                }

                // The line reports how fresh sync is; the section above reports
                // what needs fixing. When the same problem would appear in both,
                // only the actionable one is worth the space.
                if let sync, NeedsAttention.authProblem(status: sync.status) == nil {
                    Section {
                        SyncStatusLine(
                            status: sync.status,
                            lastSyncedAt: sync.lastSyncedAt,
                            now: tick,
                            onOpenSettings: { showingConnection = true }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 24, trailing: 22))
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(8)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .refreshable {
                // §4.2 trigger 2, exempt from the 10-minute throttle by the
                // trigger's own policy — see `SyncTrigger.throttleInterval`.
                await sync?.performAndWait(.pullToRefresh)
                rebuildPlan()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // #98: the plan follows the store, not a list of remembered moments.
        //
        // Two triggers were missing, and the interesting one is not the obvious
        // one. Returning to the Decks tab already re-fires `.task`, so adding a
        // card and coming back was always fine — a test written to prove it broken
        // passed instead. **Foregrounding does not**, and that is where it hurts:
        // a learning card whose timer expires while the app is in the background
        // is due the moment you look at the phone again, and Home went on showing
        // the count from before you put it down. `RepeatApp` also fires §4.2's
        // sync on foreground, so the same gap swallowed every card that sync
        // pulled.
        //
        // Cheap now in a way it was not before: #84 took the queue build from
        // 2.79 s to 0.21 s at ten thousand cards.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { rebuildPlan() }
        }
        // And when a sync lands while the screen is already open — no phase
        // change, no tab switch, cards simply appear underneath.
        .onChange(of: sync?.lastSyncedAt) { _, _ in
            rebuildPlan()
        }
        .onChange(of: studyRequest) { _, request in
            guard request != nil else { return }
            rebuildPlan()
            startSession(decks: decks)
        }
        .task {
            rebuildPlan()
            while !Task.isCancelled {
                tick = .now
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .task { handleLaunchArguments() }
        .sheet(isPresented: $showingConnection) {
            SettingsView(settings: settings, app: app, onReplayOnboarding: { onReplayOnboarding?() })
                .onDisappear { rebuildPlan() }
        }
        .sheet(item: $deckSettings) { deck in
            NavigationStack { DeckSettingsView(deck: deck) }
                .onDisappear { rebuildPlan() }
        }
        // §5.4's Rewrite.
        .sheet(item: $rewriting) { note in
            EditNoteView(note: note, clearsLeech: true)
                .onDisappear { rebuildPlan() }
        }
        // Deleting a card is not undoable from here, and it is a row in someone's
        // spreadsheet — worth one question.
        .confirmationDialog(
            "Видалити картку?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Видалити", role: .destructive) {
                if let note = deleting { try? Leech.delete(note, in: context) }
                deleting = nil
                sync?.trigger(.contentEdited)
                rebuildPlan()
            }
            Button("Скасувати", role: .cancel) { deleting = nil }
        } message: {
            Text("Рядок буде позначено видаленим у Таблиці під час наступної синхронізації.")
        }
        .fullScreenCover(item: $session) { live in
            StudyView(
                session: live,
                streak: streak,
                onClose: {
                    session = nil
                    rebuildPlan()
                },
                onAddCards: {
                    session = nil
                    onAddCard?()
                }
            )
        }
    }

    // MARK: - Today

    /// #89's hero.
    ///
    /// The old one was a dark rectangle holding a very large numeral and a button,
    /// and the number was the only thing on it — which is why the screen below it
    /// read as void. Three additions, all of them information the app already had
    /// and was not showing: a **ring** for how much of today is behind you, the
    /// **new-card share** of what is left, and a gradient so the one surface the
    /// screen is built around is not a flat block.
    @ViewBuilder
    private var todayCard: some View {
        let done = summary.isAllDone
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(summary.dueCount)")
                        .scaledFont(64, weight: .bold, relativeTo: .largeTitle)
                        .kerning(-2)
                        .monospacedDigit()
                        // 64pt scaled to XXL is wide enough for a three-digit
                        // backlog to run off the card. Shrinking beats truncating
                        // for a number.
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        // #98: so a UI test can read the number itself. The deck
                        // row's subtitle is a `@Query` and updates on its own; the
                        // hero is `@State` and is the half that goes stale, so a
                        // test that never reads it cannot see the bug.
                        .accessibilityIdentifier("home.dueCount")
                    Text(done
                         ? "На сьогодні все — до завтра"
                         : "картки до повторення · ≈ \(summary.estimatedMinutes) хв")
                        .font(.subheadline)
                        .foregroundStyle(done ? Palette.onSurfaceMuted : Color.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)

                // Only once there is something to *show* progress on. Drawn on a
                // fresh queue it is an empty circle labelled "0 %" — a scoreboard
                // reporting that you have not started, next to a button asking you
                // to start. It appears with the first graded card.
                if summary.reviewedToday > 0 {
                    ProgressRing(
                        progress: summary.todayProgress,
                        lineWidth: 6,
                        tint: done ? Palette.accent : .white,
                        track: done ? Palette.accent.opacity(0.22) : Color.white.opacity(0.28)
                    ) {
                        Text("\(Int((summary.todayProgress * 100).rounded()))%")
                            .scaledFont(13, weight: .bold, relativeTo: .caption)
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .padding(4)
                            .foregroundStyle(done ? Palette.accent : .white)
                    }
                    .frame(width: 58, height: 58)
                }
            }

            if !done, summary.newCardCount > 0 {
                // Through the catalogue, not as a literal: `Text("\(n) нових")` is
                // a `LocalizedStringKey` with no entry, so it fell back to the
                // Ukrainian source and printed "10 нових" inside an English build.
                // Exactly the failure #38 spent a card removing.
                Text(Localized.string("\(summary.newCardCount) нових"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .padding(.top, 12)
            }

            Button {
                startSession(decks: decks)
            } label: {
                HStack(spacing: 7) {
                    if !done {
                        Image(systemName: "play.fill")
                            .font(.subheadline.weight(.bold))
                    }
                    Text(done ? "Немає що повторювати" : "Почати повторення")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                // #87: fixed white and fixed green while the hero is green, not
                // `surfaceRaised`/`accent`.
                //
                // Content drawn on a **fixed** surface has to be fixed too. The
                // hero's gradient is the brand colour and does not change with the
                // scheme, so a dynamic button on it followed the scheme while its
                // background did not: in dark the primary action turned into a
                // near-black pill punched out of a green card. The `done` branch is
                // dynamic because its surface (`accentSoft`) is dynamic — the rule
                // is that the two must agree, not that either is always right.
                .background(done ? Palette.surfaceRaised : .white,
                            in: .rect(cornerRadius: 15))
                .foregroundStyle(done ? Palette.onSurfaceMuted : Palette.accentFill)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(done)
            // Stable handles for #39's UI tests. Identifiers rather than copy:
            // #38 rewrote every user-facing string in the app, and a UI test
            // keyed on Ukrainian text would have broken on all of them.
            .accessibilityIdentifier("home.startSession")
            .padding(.top, 18)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground(done: done))
        .foregroundStyle(done ? Palette.onSurface : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .elevated(done ? .low : .high)
        .accessibilityElement(children: .contain)
    }

    /// A gradient rather than `Palette.ink`.
    ///
    /// The old hero was the *ink* colour — the same near-black as the body text —
    /// which is why the screen's most important surface read as a void rather than
    /// as the brand. Green ties it to the accent already used everywhere else, and
    /// two stops give it a direction. Both stops are darker than `accent`'s
    /// measured 5.61:1 against white, so the white on top clears AA at every point
    /// of the ramp, not merely on average.
    @ViewBuilder
    private func heroBackground(done: Bool) -> some View {
        if done {
            Palette.accentSoft
        } else {
            LinearGradient(
                colors: [Palette.accentFill, Palette.accentFillDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Decks

    @ViewBuilder
    private var deckRows: some View {
        if summary.decks.isEmpty {
            // #89: the empty state was one grey sentence floating in the void the
            // card complains about. It is the first thing a fresh install sees
            // after onboarding, so it gets a shape and a way out.
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.title)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 56, height: 56)
                    .background(Palette.accentSoft, in: Circle())
                Text("Ще немає колод")
                    .font(.headline)
                    .foregroundStyle(Palette.onSurface)
                Text("Підключіть Google Таблицю, щоб їх завантажити.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Palette.radius))
            .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            .listRowBackground(Color.clear)
        } else {
            ForEach(summary.decks) { row in
                Button { studyDeck(row.id) } label: { DeckRowView(row: row) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                    .listRowSeparator(.hidden)
                    // §6.2: swipe a deck for its settings (#21).
                    .swipeActions(edge: .trailing) {
                        Button("Налаштування") { deckSettings = deck(row.id) }
                            .tint(Palette.accent)
                    }
            }
        }
    }

    private var streak: Int {
        Streak.length(reviewDates: logs.filter { $0.rating != 0 }.map(\.reviewedAt))
    }

    private func deck(_ title: String) -> Deck? {
        decks.first { $0.sheetTitle == title }
    }

    // MARK: - Starting a session

    /// §5.3: moves the safest of today's due reviews out to the next two days.
    ///
    /// Reads the store directly for the same reason `rebuildPlan` does — the
    /// `@Query` has not caught up with anything written this turn — and rebuilds
    /// afterwards so the button's count, the widget and the reminder all agree
    /// with the dates that were just changed.
    private func spreadBacklog() {
        let due = (try? context.fetch(FetchDescriptor<Card>())) ?? []
        let backlog = due.filter { !$0.isSuspended && $0.state != .new && $0.due <= Date.now }
            .filter { $0.note.deletedAt == nil && $0.note.deck.deletedAt == nil }
        let plan = CatchUp.schedule(cards: backlog, scheduler: Scheduler(config: app.schedulerConfig))
        try? CatchUp.apply(plan, in: context)
        rebuildPlan()
    }

    /// Reads the store directly rather than the `@Query`.
    ///
    /// A `@Query` does not refresh within the same turn as the insert that
    /// changed it, so a plan built immediately after a sync — or after the sample
    /// seed — came out empty while the list below it showed the decks.
    private func rebuildPlan() {
        let stored = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let storedLogs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        var generator = SystemRandomNumberGenerator()
        plan = QueueBuilder.plan(
            decks: stored,
            config: app.queueConfig,
            recentLogs: storedLogs,
            logsToday: storedLogs.filter { Calendar.current.isDateInToday($0.reviewedAt) },
            using: &generator
        )
        leeches = Leech.all(in: context, threshold: app.leechThreshold)
        // §7.1: the widget shows Home's number, so it is published from the same
        // plan rather than recomputed from a different definition of "due".
        DueCountPublisher.publish(plan: plan)
        // §7.3: the Share Extension's picker reads this.
        DueCountPublisher.publishDecks(from: context)

        // §7.2: every rebuild is also the moment the reminder could have become
        // false — a finished session, a changed time, a fresh sync.
        let enabled = app.reminderEnabled
        let minutes = app.reminderMinutes
        let config = app.queueConfig
        Task { @MainActor in
            await DailyReminder.refresh(
                in: context, enabled: enabled, reminderMinutes: minutes, queueConfig: config
            )
        }
    }

    /// Hands the session **the plan Home is already showing**, so the count on
    /// the button and the queue behind it cannot drift apart.
    private func startSession(decks studied: [Deck]) {
        guard !plan.isEmpty else { return }
        session = makeSession(plan: plan, decks: studied)
    }

    private func studyDeck(_ title: String) {
        guard let deck = deck(title) else { return }
        var generator = SystemRandomNumberGenerator()
        let scoped = QueueBuilder.plan(
            decks: [deck], config: app.queueConfig,
            recentLogs: logs, logsToday: logsToday, using: &generator
        )
        guard !scoped.isEmpty else { return }
        session = makeSession(plan: scoped, decks: [deck])
    }

    private func makeSession(plan: QueuePlan, decks: [Deck]) -> StudySession {
        // §5.1: the scheduler runs on the effective config, which is the Sheet's
        // `_meta` when it has one and Settings otherwise. Until now every session
        // used the built-in defaults and `_meta` was parsed and discarded.
        let started = StudySession(
            context: context,
            scheduler: Scheduler(config: app.schedulerConfig),
            plan: plan,
            decks: decks,
            leechThreshold: app.leechThreshold
        )
        // §4.2 trigger 4.
        started.onSessionEnded = { [sync] _ in sync?.trigger(.sessionEnded) }
        return started
    }

    private func handleLaunchArguments() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(where: { $0.hasSuffix("OnLaunch") }) else { return }
        if arguments.contains("-openConnectionOnLaunch") { showingConnection = true }
        if arguments.contains("-showConflictsOnLaunch") { seedConflict() }
        if arguments.contains("-openDeckSettingsOnLaunch") {
            SampleData.seedIfEmpty(context)
            deckSettings = (try? context.fetch(FetchDescriptor<Deck>()))?.first
        }
        if arguments.contains("-seedSampleDataOnLaunch") {
            SampleData.seedIfEmpty(context)
            rebuildPlan()
        }
        if arguments.contains("-seedSoonDueOnLaunch") {
            SampleData.seedSoonDue(context)
            rebuildPlan()
        }
        if arguments.contains("-seedGapCardsOnLaunch") {
            SampleData.seedGapCards(context)
            rebuildPlan()
        }
        if arguments.contains("-seedLeechesOnLaunch") {
            SampleData.seedLeeches(context)
            rebuildPlan()
        }
        if arguments.contains("-seedBacklogOnLaunch") {
            SampleData.seedBacklog(context)
            rebuildPlan()
        }
        if arguments.contains("-seedBackupsOnLaunch") {
            SampleData.seedIfEmpty(context)
            SampleData.seedBackups(context)
        }
        if arguments.contains("-spreadBacklogOnLaunch") { spreadBacklog() }
        if arguments.contains("-startSessionOnLaunch") {
            SampleData.seedIfEmpty(context)
            // Flips the per-deck mode so the typed answer and its diff can be
            // screenshotted without tapping through Deck settings first.
            if arguments.contains("-typeAnswerOnLaunch") {
                for deck in (try? context.fetch(FetchDescriptor<Deck>())) ?? [] {
                    deck.typeAnswer = true
                }
                try? context.save()
            }
            rebuildPlan()
            startSession(decks: decks)
            if arguments.contains("-revealOnLaunch") { session?.reveal() }
            if arguments.contains("-finishSessionOnLaunch") {
                while let live = session, live.current != nil {
                    live.reveal(); live.rate(.easy)
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// Seeds one conflict so #19's list can be seen without provoking a real one.
    private func seedConflict() {
        SampleData.seedIfEmpty(context)
        guard let deck = decks.first, let note = deck.notes.first else { return }
        context.insert(SyncConflict(
            noteId: note.id, deckTitle: deck.sheetTitle,
            front: note.front, back: "\(note.back) (моя правка)", example: note.example,
            winningFront: note.front, winningBack: note.back))
        try? context.save()
    }
    #endif
}

/// One deck row (#89).
///
/// Was a 10×38pt colour bar, two lines of text and a pale badge. The colour was
/// the deck's own — the only place in the app it appeared — and at 10pt wide it
/// was doing none of the identifying work it was there for. Now the colour is a
/// filled avatar carrying the deck's initial, so the row is scannable by shape
/// and colour before any of it is read.
private struct DeckRowView: View {
    let row: HomeSummary.DeckRow

    private var tint: Color { Color(hex: row.colorHex) ?? Palette.accent }

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(row.malformedReason == nil
                                     ? Palette.onSurfaceMuted : Palette.again)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            badge

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.separator)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Palette.radius))
        .elevated(.low)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(subtitle), \(badgeLabel)")
    }

    /// The deck's initial on its own colour.
    ///
    /// The circle carries the deck's colour; the **letter does not**. `colorHex`
    /// comes from the owner's spreadsheet and can be any value at all, so a glyph
    /// painted in it is legible or not depending on a cell in a Google Sheet. #89
    /// drew the letter in the deck colour and got away with it on white; #87 made
    /// the failure obvious, because a deck's dark green on a dark card is very
    /// nearly invisible.
    ///
    /// Drawing the letter in `onSurface` and letting the colour do its identifying
    /// work through the fill and the ring is legible in both schemes for *every*
    /// value the owner can type, which the previous version was not in either.
    private var avatar: some View {
        Text(initial)
            .font(.headline.weight(.bold))
            .foregroundStyle(Palette.onSurface)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.22), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var initial: String {
        // `first` on the grapheme, so a deck named with an emoji or a Ukrainian
        // letter gets its actual first character rather than a mangled byte.
        String(row.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var subtitle: String {
        if let reason = row.malformedReason { return reason }
        var parts = [Localized.string("\(row.cardCount) карток")]
        if row.newToday > 0 { parts.append(Localized.string("\(row.newToday) нових сьогодні")) }
        return parts.joined(separator: " · ")
    }

    private var badgeLabel: String {
        row.due > 0 ? Localized.string("до повторення: \(row.due)") : (row.nextDueLabel ?? "")
    }

    @ViewBuilder
    private var badge: some View {
        if row.due > 0 {
            // Solid, not `accentSoft`: this is the number that says "there is work
            // in here", and as pale green on white it was quieter than the card
            // count beside it.
            Text("\(row.due)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.accentFill, in: Capsule())
        } else if let label = row.nextDueLabel {
            Text(label).font(.caption).foregroundStyle(Palette.onSurfaceMuted)
        }
    }
}
