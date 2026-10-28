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
    /// #112. A `@Query` rather than a fetch, so spending one updates the chip
    /// without waiting for the next rebuild.
    @Query private var freezes: [StreakFreeze]

    @State private var session: StudySession?
    @State private var deckSettings: Deck?
    /// §5.7 (#113): the level this session reached, when it reached a new one.
    @State private var sessionLevelGained: Int?
    /// #121's browse screen, pushed rather than presented: it has a search
    /// field and rows that open a sheet of their own.
    @State private var browsingDeck: Deck?
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
    /// M9 §5.1. Read and written in `rebuildPlan()`, nowhere else, so the cache
    /// has exactly one writer.
    @State private var goalTarget: Int?
    /// §5.2: what the session that just ended beat, for the Done screen. Set by
    /// `onSessionEnded`, cleared when the next session starts.
    @State private var sessionRecord: Records.Kind?
    /// The badges unlocked and **not yet shown** when the session ended — the
    /// Done screen's tiles (#108) show them and mark them shown, so until
    /// something writes the ledger this is everything unlocked so far, not only
    /// what this session earned. Cleared when the next session starts.
    @State private var sessionBadges: [Achievements.Badge] = []
    /// §5.6: whether *this* session closed the day's goal — open when it was
    /// made, closed when it ended. Set with `sessionRecord`, cleared with it.
    @State private var sessionGoalClosed = false

    /// Built **once per body pass** and handed down — #116. As a computed
    /// property it was read in thirteen places, and each read walked every card
    /// of every deck again: 8.4 s for the first pass at ten thousand cards.
    private func buildSummary() -> HomeSummary {
        HomeSummary.make(decks: decks, plan: plan, logsToday: logsToday,
                         cachedTarget: goalTarget, now: tick)
    }

    /// One predicate for "today", two callers: this and the session-end record
    /// arithmetic — see `Self.today(_:)`.
    private var logsToday: [ReviewLog] { Self.today(logs) }

    /// §5.3. Derived from the plan on screen rather than stored, so it appears
    /// and disappears with the backlog itself — there is no dismissal flag to get
    /// out of step with reality.
    private var catchUpOffer: CatchUp.Offer? {
        CatchUp.offer(dueReviews: plan.dueReviewCount, logs: logs, now: tick)
    }

    var body: some View {
        let summary = buildSummary()
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
                        todayCard(summary)
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
                    onDelete: { deleting = $0 },
                    metaProblems: app.overrides.problems
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
                    deckRows(summary)
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
            // Inside the stack, on the List — a `navigationDestination` attached
            // to the `NavigationStack` itself is not seen by it.
            .navigationDestination(item: $browsingDeck) { deck in
                DeckCardsView(deck: deck)
            }
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
                celebration: Celebration.lines(freezeSpent: unnamedFreeze != nil,
                                               goalClosed: sessionGoalClosed,
                                               levelGained: sessionLevelGained,
                                               record: sessionRecord,
                                               badges: sessionBadges),
                markFreezeAnnounced: nameFreeze,
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
    private func todayCard(_ summary: HomeSummary) -> some View {
        let done = summary.isAllDone
        // M9: the goal is met but cards arrived since (or catch-up left some). The
        // surface is the calm one — the day is finished — and the button offers
        // the rest rather than demanding it.
        let closed = summary.goal.isClosed && !done
        let calm = done || closed
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
                         : closed
                             ? "Норму на сьогодні виконано"
                             : "картки до повторення · ≈ \(summary.estimatedMinutes) хв")
                        .font(.subheadline)
                        .foregroundStyle(calm ? Palette.onSurfaceMuted : Color.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)

                // Only once there is something to *show* progress on. Drawn on a
                // fresh queue it is an empty circle labelled "0 %" — a scoreboard
                // reporting that you have not started, next to a button asking you
                // to start. It appears with the first graded card.
                if summary.reviewedToday > 0 {
                    let percent = Int((summary.todayProgress * 100).rounded())
                    ProgressRing(
                        progress: summary.todayProgress,
                        lineWidth: 6,
                        tint: calm ? Palette.accent : .white,
                        track: calm ? Palette.accent.opacity(0.22) : Color.white.opacity(0.28)
                    ) {
                        Group {
                            if summary.goal.isClosed {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                            } else {
                                Text("\(percent)%")
                                    .scaledFont(13, weight: .bold, relativeTo: .caption)
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                            }
                        }
                        .padding(4)
                        .foregroundStyle(calm ? Palette.accent : .white)
                    }
                    .frame(width: 58, height: 58)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Денна норма")
                    .accessibilityValue(Text(verbatim: "\(percent)"))
                    .accessibilityIdentifier("home.goal")
                }
            }

            if !done, summary.newCardCount > 0 {
                // Through the catalogue, not as a literal: `Text("\(n) нових")` is
                // a `LocalizedStringKey` with no entry, so it fell back to the
                // Ukrainian source and printed "10 нових" inside an English build.
                // Exactly the failure #38 spent a card removing.
                Text(Localized.string("\(summary.newCardCount) нових"))
                    .font(.caption.weight(.semibold))
                    // Content on the dynamic `accentSoft` surface takes dynamic
                    // tokens (handoff gotcha 29): the fixed white-on-white pair
                    // below is only legible on the fixed green hero.
                    .foregroundStyle(calm ? Palette.accent : .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(calm ? Palette.accent.opacity(0.12) : Color.white.opacity(0.18), in: Capsule())
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
                    Text(done ? "Немає що повторювати" : closed ? "Ще картки" : "Почати повторення")
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
                .background(calm ? Palette.surfaceRaised : .white,
                            in: .rect(cornerRadius: 15))
                // Not `calm`: the button's colour signals whether it is enabled,
                // and `closed` still is — only `done` disables it.
                .foregroundStyle(closed ? Palette.accent : (done ? Palette.onSurfaceMuted : Palette.accentFill))
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
        .background(heroBackground(done: calm))
        .foregroundStyle(calm ? Palette.onSurface : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Stays on `done`, not `calm`: `closed` still has a button worth
        // pressing ("Ще картки"), so it keeps the higher elevation.
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
    private func deckRows(_ summary: HomeSummary) -> some View {
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
                    .accessibilityIdentifier("home.deck.\(row.id)")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                    .listRowSeparator(.hidden)
                    // §6.2: swipe a deck for its settings (#21), and since #121
                    // for its cards. The tap studies the deck under its own tag
                    // (#153): #144 put a deck screen in between for choosing the
                    // tag, and the owner found a setting more convenient.
                    .swipeActions(edge: .trailing) {
                        Button("Налаштування") { deckSettings = deck(row.id) }
                            .tint(Palette.accent)
                            .accessibilityIdentifier("home.deck.settings")
                        Button("Картки") { browsingDeck = deck(row.id) }
                            .tint(Palette.hard)
                            .accessibilityIdentifier("home.deck.browse")
                    }
            }
        }
    }

    private var streak: Int {
        Streak.length(reviewDates: logs.filter { $0.rating != 0 }.map(\.reviewedAt),
                      frozenDays: Set(freezes.map(\.day)))
    }

    private func deck(_ title: String) -> Deck? {
        decks.first { $0.sheetTitle == title }
    }

    /// #112: a freeze that has been spent and not yet named on a Done screen.
    /// Read from the `@Query` rather than fetched, so this costs nothing in a
    /// body that runs on every tick.
    private var unnamedFreeze: StreakFreeze? {
        freezes.first { $0.announcedAt == nil }
    }

    /// Written when the Done screen is *left*, on the same contract as the badge
    /// ledger: an undo is still reachable until then.
    private func nameFreeze() {
        guard let freeze = unnamedFreeze else { return }
        freeze.announcedAt = .now
        try? context.save()
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
        // The sync actor writes `_meta`'s verdict to defaults off the main actor;
        // this pass already runs after every sync, so it is where Home picks
        // the verdict up — including the values it refused (§5.1).
        app.refreshOverrides()
        let stored = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let storedLogs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        let todayLogs = storedLogs.filter { Calendar.current.isDateInToday($0.reviewedAt) }
        // #112: the one place a freeze is spent. Here because this is the pass
        // that already runs on appear, on foreground and after a sync — so a
        // freeze is settled the first time the owner comes back, which is the
        // only moment it can save anything. Read from the store rather than the
        // `@Query` for the reason the lines above do: the query has not caught up
        // with anything written this turn.
        let realReviews = storedLogs.filter { $0.rating != 0 }
        Freeze.settle(in: context,
                      reviewDays: Set(realReviews
                          .map { Calendar.current.startOfDay(for: $0.reviewedAt) }))
        var generator = SystemRandomNumberGenerator()
        plan = QueueBuilder.plan(
            decks: stored,
            config: app.queueConfig,
            recentLogs: storedLogs,
            logsToday: todayLogs,
            using: &generator
        )
        // M9 §5.1: the target is what today looked like the first time it was
        // built; it grows to cover what was done, and an empty queue brings it
        // down to that instead — see `DailyGoal`.
        let cache = DailyGoalCache()
        let now = Date()
        let cachedTarget = cache.target(on: now)
        let reviewed = HomeSummary.reviewedCount(logsToday: todayLogs, now: now)
        let goal = DailyGoal.make(reviewedToday: reviewed, dueCount: plan.count,
                                  cachedTarget: cachedTarget)
        if goal.target != cachedTarget { cache.store(goal.target, on: now) }
        goalTarget = goal.target
        leeches = Leech.all(in: context, threshold: app.leechThreshold)
        // No badge evaluation here. It used to run on every rebuild for a reader
        // that never arrived: #109 wired the notifier to the background refresh
        // instead, and the Done screen's badges come from `onSessionEnded`'s own
        // evaluation. A rebuild has nowhere to put the answer, so it no longer
        // pays `Facts.make` for one.
        // §7.1: the widget shows Home's numbers, so they are published from the
        // same plan rather than recomputed from a different definition of "due".
        // #111 sends the goal and the streak along the same wire.
        //
        // The streak is computed here from `storedLogs` rather than read off the
        // `streak` property, which is backed by the `@Query`: this pass exists
        // precisely because the query has not caught up with what was written this
        // turn, and a streak one turn behind the count beside it is the drift §7.1
        // forbids. `Freeze.days` is read *after* `settle`, which is what may have
        // created today's row.
        let publishedStreak = Streak.length(
            reviewDates: realReviews.map(\.reviewedAt),
            frozenDays: Freeze.days(in: context),
            now: now
        )
        DueCountPublisher.publish(plan: plan, goal: goal, streak: publishedStreak, now: now)
        // §7.3: the Share Extension's picker reads this.
        DueCountPublisher.publishDecks(from: context)

        // §7.2: every rebuild is also the moment the reminder could have become
        // false — a finished session, a changed time, a fresh sync.
        Task { @MainActor in
            await EveningReminder.refresh(
                in: context, enabled: app.reminderEnabled,
                reminderMinutes: app.reminderMinutes,
                streakMinutes: app.streakReminderMinutes,
                queueConfig: app.queueConfig
            )
        }
    }

    /// Hands the session **the plan Home is already showing**, so the count on
    /// the button and the queue behind it cannot drift apart.
    private func startSession(decks studied: [Deck]) {
        guard !plan.isEmpty else { return }
        session = makeSession(plan: plan, decks: studied)
    }

    /// One deck, under its own tag (#153) — the plan's default.
    ///
    /// Logs are read from the store rather than the `@Query`, for the reason
    /// `rebuildPlan` gives: right after a session the query has not caught up,
    /// and a plan built from it would still offer the new cards just learned.
    private func studyDeck(_ title: String) {
        guard let deck = deck(title) else { return }
        let storedLogs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        var generator = SystemRandomNumberGenerator()
        let scoped = QueueBuilder.plan(
            decks: [deck], config: app.queueConfig,
            recentLogs: storedLogs, logsToday: Self.today(storedLogs), using: &generator
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
        // §5.2: a record is named the moment it is set, which means knowing what
        // the records were before this session. Read the store rather than the
        // `@Query` — at launch the seed and the session start in the same turn,
        // and the query has not caught up (the same reason `spreadBacklog` gives).
        let logsBefore = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        let frozen = Freeze.days(in: context)
        let before = Records.make(reviewDates: StatsSummary.reviewDates(logsBefore), frozenDays: frozen)
        // §5.7 (#113): the level as this session started, so a gain can be told
        // from simply being at a level.
        let levelBefore = XP.level(logs: logsBefore)
        let owedBefore = self.plan.count
        // §5.6: "goal closed" is closed *by this session* — the same target
        // Home's ring uses, before and after.
        let goalCache = DailyGoalCache()
        let closedBefore = DailyGoal.make(
            reviewedToday: HomeSummary.reviewedCount(logsToday: Self.today(logsBefore), now: Date()),
            dueCount: owedBefore, cachedTarget: goalCache.target(on: Date())
        ).isClosed
        sessionRecord = nil
        sessionBadges = []
        sessionGoalClosed = false
        sessionLevelGained = nil
        // §4.2 trigger 4, and the record. `rate` saves before it calls this, so
        // the fetch sees the last grade.
        started.onSessionEnded = { [sync, context] _ in
            sync?.trigger(.sessionEnded)
            let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
            let after = Records.make(reviewDates: StatsSummary.reviewDates(logs), frozenDays: frozen)
            sessionRecord = Records.newlySet(before: before, after: after).first
            let levelAfter = XP.level(logs: logs)
            sessionLevelGained = levelAfter > levelBefore ? levelAfter : nil
            // What this session still leaves owed: a full session ran the whole
            // plan (0); a deck-scoped one leaves the other decks' share, which
            // this over-estimates when the plan moved meanwhile — the rebuild on
            // close evaluates again with the exact number.
            let owedAfter = max(0, owedBefore - plan.count)
            let now = Date()
            let closedAfter = DailyGoal.make(
                reviewedToday: HomeSummary.reviewedCount(logsToday: Self.today(logs), now: now),
                dueCount: owedAfter, cachedTarget: goalCache.target(on: now)
            ).isClosed
            sessionGoalClosed = !closedBefore && closedAfter
            // M9 §5.4: what this session unlocked and has not been shown. The Done
            // screen shows it and writes the ledger.
            sessionBadges = Achievements.evaluate(
                facts: Achievements.Facts.make(in: context, logs: logs, owedToday: owedAfter, now: now),
                ledger: AchievementLedger()
            ).fresh
        }
        return started
    }

    private static func today(_ logs: [ReviewLog]) -> [ReviewLog] {
        logs.filter { Calendar.current.isDateInToday($0.reviewedAt) }
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
        if arguments.contains("-seedRecordHistoryOnLaunch") {
            SampleData.seedRecordHistory(context)
            rebuildPlan()
        }
        if arguments.contains("-seedFullCelebrationOnLaunch") {
            SampleData.seedFullCelebration(context)
            rebuildPlan()
        }
        if arguments.contains("-seedMasteryOnLaunch") {
            SampleData.seedMastery(context)
            rebuildPlan()
        }
        if arguments.contains("-seedBackupsOnLaunch") {
            SampleData.seedIfEmpty(context)
            SampleData.seedBackups(context)
        }
        // #108: the backlog seed's history alone — fourteen days, none today —
        // with no overdue cards, so the sample deck is still a ten-card session
        // a UI test can finish by hand.
        //
        // Twenty a day, not the seed's ten: this fixture must leave the records
        // alone, and the day the fixture's own session makes is bigger than ten.
        // The mastery seed writes six real `_log` rows dated today, and the
        // session adds ten, so a best day of ten would be overtaken and the Done
        // screen would name a record the "one badge alone" screen must not have.
        if arguments.contains("-seedHistoryOnLaunch") {
            SampleData.seedBacklog(context, overdue: 0, historyPerDay: 20)
            rebuildPlan()
        }
        // #108's Done-screen fixtures: "nothing new" needs a ledger that already
        // holds everything the history earned; "one badge" additionally needs
        // one specific badge left fresh, which is what the second flag is for.
        //
        // Marks shown everything the *seeded history* has unlocked so far —
        // everything except the perfect session, which is held back on purpose.
        // The seeded history's twenty-a-day runs *are* perfect sessions, so
        // sweeping everything unlocked would close that badge too and leave the
        // one-badge fixture with nothing to celebrate. The flag below is what
        // closes it, and that is exactly what makes the quiet fixture quiet.
        if arguments.contains("-markHistoryBadgesShownOnLaunch") {
            let logs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
            let facts = Achievements.Facts.make(in: context, logs: logs, owedToday: plan.count)
            AchievementLedger().markShown(Achievements.unlocked(facts).subtracting([.perfectSession]))
        }
        if arguments.contains("-markPerfectSessionShownOnLaunch") {
            AchievementLedger().markShown([.perfectSession])
        }
        // #108's grid fixture: three badges earned on three past days.
        if arguments.contains("-seedBadgesOnLaunch") {
            let ledger = AchievementLedger()
            let calendar = Calendar.current
            for (badge, daysAgo) in [(Achievements.Badge.firstSession, 3), (.streak7, 2), (.reviews100, 1)] {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
                ledger.markShown([badge], on: day)
            }
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
                if row.mastery.total > 0 {
                    MasteryBar(counts: row.mastery)
                        .padding(.top, 6)
                }
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
        .accessibilityLabel([row.title, subtitle, badgeLabel, masteryLabel]
            .filter { !$0.isEmpty }
            .joined(separator: ", "))
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
        // #153: first, because it changes what every number on the row means.
        if let tag = row.filterLabel { parts.insert(tag, at: 0) }
        if row.newToday > 0 { parts.append(Localized.string("\(row.newToday) нових сьогодні")) }
        return parts.joined(separator: " · ")
    }

    private var badgeLabel: String {
        row.due > 0 ? Localized.string("до повторення: \(row.due)") : (row.nextDueLabel ?? "")
    }

    /// The bar in words. The only place on Home the three numbers appear.
    private var masteryLabel: String {
        Localized.string("відомо \(row.mastery.known), вивчається \(row.mastery.learning), нових \(row.mastery.new)")
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
