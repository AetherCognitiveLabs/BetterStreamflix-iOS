import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case home, movies, series, library, live, manga, more
    }

    @EnvironmentObject private var environment: AppEnvironment
    /// Middle tab-bar slots, picked on the More screen (see `TabBarSlots`).
    @AppStorage(TabBarSlots.storageKey) private var tabSlotsRaw = TabBarSlots.defaultValue
    private var tabSlots: [TabBarDestination] { TabBarSlots.parse(tabSlotsRaw) }
    @EnvironmentObject private var watchlistToast: WatchlistToastStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var homeTitleTransitionNamespace
    @Namespace private var movieTitleTransitionNamespace
    @Namespace private var seriesTitleTransitionNamespace
    @Namespace private var libraryTitleTransitionNamespace
    @Namespace private var moreTitleTransitionNamespace
    @StateObject private var homeTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var movieTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var seriesTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var libraryTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var moreTitleTransitionSelection = TitleTransitionSelection()
    @State private var selectedTab: Tab = .home
    @State private var isSearchPresented = false
    @State private var isHomeReady = false
    @State private var hasCompletedSetup = AppSetupStore.isCompleted
    @State private var pendingAutomaticUpdate: AppUpdateInfo?
    @State private var automaticUpdateRelease: AppUpdateInfo?
    @State private var pendingStremioInstallURL: String?
    @State private var shortcutResumePlayback: PlaybackRequest?
    @State private var widgetLiveChannel: LiveChannel?
    @AppStorage("updates.skippedReleaseTag") private var skippedUpdateTag = ""

    var body: some View {
        ZStack {
            AppScreenBackground()

            if hasCompletedSetup {
                mainTabs
            } else {
                FirstLaunchSetupView {
                    withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
                        hasCompletedSetup = true
                    }
                }
                .transition(.opacity)
                .zIndex(50)
            }

            if hasCompletedSetup, !isHomeReady {
                SplashScreen()
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchPresentationView()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            await environment.refreshContinueWatchingForNewEpisodes()
        }
        .task(id: isHomeReady) {
            guard isHomeReady else { return }
            await environment.preloadPrimaryNavigationArtwork()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            await checkForUpdatesAtLaunch()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            showHome()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasCompletedSetup else { return }
            Task { await environment.refreshContinueWatchingForNewEpisodes() }
            Task { await StremioForegroundHealthSweep.runIfNeeded() }
        }
        .onChange(of: isHomeReady) { _, isReady in
            guard isReady, let release = pendingAutomaticUpdate else { return }
            pendingAutomaticUpdate = nil
            automaticUpdateRelease = release
        }
        .onReceive(NotificationCenter.default.publisher(for: StremioInstallDeepLink.didReceiveNotification)) { note in
            if let raw = note.object as? String {
                pendingStremioInstallURL = raw
            } else if let pending = StremioInstallDeepLink.peekPending() {
                pendingStremioInstallURL = pending
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: StremioShortcutBridge.didReceiveNotification)) { note in
            handleShortcut(routeRaw: note.object as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: WidgetDeepLink.didReceive)) { _ in
            if let target = WidgetDeepLink.consumePending() { handleWidgetLink(target) }
        }
        .onAppear {
            if pendingStremioInstallURL == nil,
               let pending = StremioInstallDeepLink.peekPending() {
                pendingStremioInstallURL = pending
            }
            if let pending = StremioShortcutBridge.consumePending() {
                handleShortcut(routeRaw: pending.rawValue)
            }
            if let target = WidgetDeepLink.consumePending() {
                handleWidgetLink(target)
            }
            #if DEBUG
            applyDebugLaunchRoute()
            #endif
        }
        .fullScreenCover(item: $widgetLiveChannel) { channel in
            let provider = LiveTVProviders.all().first { $0.id == channel.providerID }
            LivePlayerView(channel: channel) {
                if let provider { return try await provider.resolve(channel) }
                return channel.playbackSource
            }
        }
        .fullScreenCover(item: $shortcutResumePlayback) { request in
            PlayerScreen(request: request, nextRequest: nil)
                .environmentObject(environment)
                .environmentObject(environment.library)
        }
        .sheet(item: $automaticUpdateRelease) { info in
            UpdateCheckSheet(
                result: .updateAvailable(info),
                onSkipUpdate: {
                    skippedUpdateTag = info.tagName
                    automaticUpdateRelease = nil
                },
                onRemindLater: {
                    automaticUpdateRelease = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(isPresented: Binding(
            get: { pendingStremioInstallURL != nil },
            set: { if !$0 { pendingStremioInstallURL = nil } }
        )) {
            if let pendingStremioInstallURL {
                StremioInstallPromptSheet(
                    rawURL: pendingStremioInstallURL,
                    onDismiss: {
                        _ = StremioInstallDeepLink.consumePending()
                        self.pendingStremioInstallURL = nil
                    },
                    onInstalled: {
                        selectedTab = .more
                    }
                )
                .environmentObject(environment)
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(onInitialLoadCompleted: showHome) }
                .environment(\.titleTransitionNamespace, homeTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, homeTitleTransitionSelection)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            if tabSlots.contains(.movies) {
            NavigationStack {
                CatalogView(
                    kind: .movie,
                    onOpenSearch: { isSearchPresented = true }
                )
            }
            .environment(\.titleTransitionNamespace, movieTitleTransitionNamespace)
            .environment(\.titleTransitionSelection, movieTitleTransitionSelection)
            .tabItem { Label("Movies", systemImage: "film.fill") }
            .tag(Tab.movies)
            }

            if tabSlots.contains(.series) {
            NavigationStack {
                CatalogView(
                    kind: .series,
                    onOpenSearch: { isSearchPresented = true }
                )
            }
            .environment(\.titleTransitionNamespace, seriesTitleTransitionNamespace)
            .environment(\.titleTransitionSelection, seriesTitleTransitionSelection)
            .tabItem { Label("Series", systemImage: "tv.fill") }
            .tag(Tab.series)
            }

            if tabSlots.contains(.library) {
                NavigationStack { LibraryView() }
                    .environment(\.titleTransitionNamespace, libraryTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, libraryTitleTransitionSelection)
                    .tabItem { Label(TabBarDestination.library.title, systemImage: TabBarDestination.library.systemImage) }
                    .tag(Tab.library)
            }

            if tabSlots.contains(.live) {
                NavigationStack { LiveTVView(isTabRoot: true) }
                    .tabItem { Label(TabBarDestination.live.title, systemImage: TabBarDestination.live.systemImage) }
                    .tag(Tab.live)
            }

            if tabSlots.contains(.manga) {
                NavigationStack { MangaHomeView(isTabRoot: true) }
                    .tabItem { Label(TabBarDestination.manga.title, systemImage: TabBarDestination.manga.systemImage) }
                    .tag(Tab.manga)
            }

            MoreView(onOpenSearch: { isSearchPresented = true })
                .environment(\.titleTransitionNamespace, moreTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, moreTitleTransitionSelection)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(Tab.more)
        }
        .tint(environment.theme.accent)
        .toolbar(.visible, for: .tabBar)
        .overlay(alignment: .top) {
            SourceLookupStatusOverlay()
                .safeAreaPadding(.top, 8)
                .zIndex(100)
        }
        .overlay(alignment: .bottom) {
            WatchlistToastBanner(toast: watchlistToast.toast)
                .padding(.horizontal, 20)
                .safeAreaPadding(.bottom, 10)
                .padding(.bottom, 56)
                .animation(DesignTokens.Motion.toast, value: watchlistToast.toast)
                .zIndex(110)
        }
    }

    private func showHome() {
        guard !isHomeReady else { return }
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
            isHomeReady = true
        }
    }

    private func handleWidgetLink(_ target: WidgetDeepLink.Target) {
        switch target {
        case .continueWatching(let contentID):
            if let contentID,
               let progress = environment.library.continueWatching.first(where: { $0.contentID == contentID }) {
                shortcutResumePlayback = PlaybackRequest(media: progress.media, episode: progress.episode)
            } else {
                selectedTab = .library
            }
        case .liveChannel(let id, let providerID):
            if !ProfileStore.shared.activeProfile.isKids,
               let favorite = LiveFavoritesStore.shared.favorite(providerID: providerID, channelID: id) {
                widgetLiveChannel = favorite.channel
            } else {
                openLiveHub()
            }
        case .liveHub:
            openLiveHub()
        }
    }

    #if DEBUG
    /// `-openTab <name>` / `-openMore <route>` launch arguments, used to reach
    /// screens for simulator screenshots.
    private func applyDebugLaunchRoute() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        switch value("-openTab") {
        case "home": selectedTab = .home
        case "movies": selectedTab = .movies
        case "series": selectedTab = .series
        case "library": selectedTab = .library
        case "live": selectedTab = .live
        case "manga": selectedTab = .manga
        case "more": selectedTab = .more
        default: break
        }
        if let route = value("-openMore") {
            selectedTab = .more
            UserDefaults.standard.set(route, forKey: "stremio.shortcut.moreRoute.v1")
            NotificationCenter.default.post(name: Notification.Name("stremio.shortcut.moreRoute"), object: route)
        }
    }
    #endif

    private func openLiveHub() {
        if tabSlots.contains(.live) {
            selectedTab = .live
            return
        }
        selectedTab = .more
        UserDefaults.standard.set("liveTV", forKey: "stremio.shortcut.moreRoute.v1")
        NotificationCenter.default.post(name: Notification.Name("stremio.shortcut.moreRoute"), object: "liveTV")
    }

    private func handleShortcut(routeRaw: String?) {
        guard let raw = routeRaw,
              let route = StremioShortcutBridge.Route(rawValue: raw) else { return }
        switch route {
        case .resume:
            if let progress = environment.library.continueWatching.first {
                shortcutResumePlayback = PlaybackRequest(
                    media: progress.media,
                    episode: progress.episode
                )
            } else {
                selectedTab = .library
            }
        case .hub, .debrid, .addons:
            selectedTab = .more
            UserDefaults.standard.set(raw, forKey: "stremio.shortcut.moreRoute.v1")
            NotificationCenter.default.post(
                name: Notification.Name("stremio.shortcut.moreRoute"),
                object: raw
            )
        }
    }

    private func checkForUpdatesAtLaunch() async {
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        do {
            let info = try await PublicUpdateFeedClient().latest()
            guard UpdateCheckService.shouldOfferUpdate(
                info: info,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                skippedTagName: skippedUpdateTag
            ) else { return }

            if isHomeReady {
                automaticUpdateRelease = info
            } else {
                pendingAutomaticUpdate = info
            }
        } catch {
            // Launch continues normally when the public feed cannot be queried.
        }
    }
}

/// Destinations that can occupy the middle tab-bar slots between Home and More.
enum TabBarDestination: String, CaseIterable, Identifiable {
    case movies, series, library, live, manga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: "Movies"
        case .series: "Series"
        case .library: "Library"
        case .live: "Live"
        case .manga: "Manga"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: "film.fill"
        case .series: "tv.fill"
        case .library: "bookmark.fill"
        case .live: "dot.radiowaves.left.and.right"
        case .manga: "book.pages.fill"
        }
    }
}

/// iPhone tab bars overflow into a system "More" tab past five items, so
/// Home + More leave three configurable slots.
enum TabBarSlots {
    static let storageKey = "tabBar.slots.v1"
    static let maxSlots = 3
    static let defaultValue = "movies,series,library"

    static func parse(_ raw: String) -> [TabBarDestination] {
        let picked = raw.split(separator: ",").compactMap { TabBarDestination(rawValue: String($0)) }
        let ordered = TabBarDestination.allCases.filter(picked.contains)
        return Array(ordered.prefix(maxSlots))
    }

    static func toggled(_ destination: TabBarDestination, in raw: String) -> String {
        var slots = parse(raw)
        if let index = slots.firstIndex(of: destination) {
            slots.remove(at: index)
        } else if slots.count < maxSlots {
            slots.append(destination)
        }
        return slots.map(\.rawValue).joined(separator: ",")
    }
}
