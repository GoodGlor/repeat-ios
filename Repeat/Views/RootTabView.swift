import SwiftUI

/// §6.2's tab bar: Decks · Add · Stats.
struct RootTabView: View {
    enum Tab: Hashable { case decks, add, stats }

    @State private var tab: Tab = .decks
    @State private var showingOnboarding = Self.initialOnboarding
    @State private var settings = SheetsSettings()
    @State private var studyRequest: UUID?
    @Environment(\.scenePhase) private var scenePhase

    /// Routes a `repeat://` URL (§7.1, §7.4).
    ///
    /// Handled here rather than in `RepeatApp` because this view owns the state a
    /// link has to change — the selected tab, and the token that starts a session.
    private func open(_ url: URL) {
        guard let destination = DeepLink.destination(for: url) else { return }
        route(to: destination)
    }

    /// The one place a destination becomes a screen. A widget tap arrives as a
    /// URL and an App Intent as a `PendingRoute`; both end up here, so the two
    /// cannot land in different places.
    private func route(to destination: DeepLink.Destination) {
        switch destination {
        case .study:
            tab = .decks
            // Onboarding would otherwise sit on top of the session the widget
            // asked for.
            showingOnboarding = false
            studyRequest = UUID()
        case .add:
            showingOnboarding = false
            tab = .add
        case .stats:
            // #109: a notification's link. Onboarding would otherwise cover it.
            showingOnboarding = false
            tab = .stats
        }
    }

    /// §7.4: `StartReviewIntent` runs before this view exists, so it leaves the
    /// destination behind rather than setting it.
    private func consumePendingRoute() {
        if let destination = PendingRoute.consume() { route(to: destination) }
    }

    /// A debug entry point names the screen it wants, so it wants to land past
    /// onboarding. Decided as the *initial* value rather than switched off in a
    /// `task`: presenting the cover and then dismissing it races whatever sheet
    /// the argument asked for, and the sheet loses.
    private static var initialOnboarding: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-showOnboardingOnLaunch") { return true }
        if arguments.contains(where: { $0.hasSuffix("OnLaunch") }) { return false }
        #endif
        return Onboarding.shouldPresent()
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(
                onAddCard: { tab = .add },
                onReplayOnboarding: { showingOnboarding = true },
                studyRequest: studyRequest
            )
                .tabItem { Label("Колоди", systemImage: "rectangle.on.rectangle") }
                .tag(Tab.decks)

            // Rebuilt on each visit: the form should open focused and empty, and
            // `id` is the least surprising way to say so.
            AddCardView(onDone: { tab = .decks })
                .id(tab == .add)
                .tabItem { Label("Додати", systemImage: "plus.circle") }
                .tag(Tab.add)

            StatsView()
                .tabItem { Label("Статистика", systemImage: "chart.bar") }
                .tag(Tab.stats)
        }
        .tint(Palette.accent)
        .onOpenURL { open($0) }
        // #109: a notification tapped while this view is already up. Cold
        // launches are covered by `.task`, foregrounds by the scene-phase change;
        // this is the third case, and the only one neither of those sees.
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.routeRequested)
                    .receive(on: RunLoop.main)) { _ in
            consumePendingRoute()
        }
        // Full screen: §6.1 is the first thing a fresh install sees, and it ends
        // with the connection that makes the app non-empty.
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView(settings: settings) { showingOnboarding = false }
        }
        .onChange(of: scenePhase) { _, phase in
            // An intent performed while the app is already open leaves its route
            // behind too — foreground is when it gets read.
            if phase == .active { consumePendingRoute() }
        }
        .task {
            consumePendingRoute()
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-openAddTabOnLaunch") { tab = .add }
            if arguments.contains("-openStatsTabOnLaunch") { tab = .stats }
            if arguments.contains("-showOnboardingOnLaunch") { showingOnboarding = true }
            // Feeds a URL through the same routing a widget tap uses.
            // `simctl openurl` always goes via Springboard's "Open in…" prompt,
            // which no widget tap shows and no script can dismiss.
            if let index = arguments.firstIndex(of: "-openURLOnLaunch"),
               index + 1 < arguments.count, let url = URL(string: arguments[index + 1]) {
                open(url)
            }
            #endif
        }
    }
}
