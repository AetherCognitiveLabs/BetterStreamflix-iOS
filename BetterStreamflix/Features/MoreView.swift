import SwiftUI

/// Premium hub for Settings, support, and updates — Search opens as a standalone cover.
struct MoreView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var path = NavigationPath()
    @AppStorage(TabBarSlots.storageKey) private var tabSlotsRaw = TabBarSlots.defaultValue
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var showCredits = false
    @State private var showLanguagePicker = false
    @State private var playbackLanguage = AppSetupStore.activePlaybackLanguageGroup
    @State private var languageConfirmation: String?
    var onOpenSearch: (() -> Void)? = nil

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageTitleHeader(title: "More", ignoresTopSafeArea: true)

                    exploreCards
                        .padding(.horizontal, 20)

                    tabBarCard
                        .padding(.horizontal, 20)

                    hubCard {
                        hubRow(
                            title: "Search",
                            subtitle: "Find movies and series",
                            systemImage: "magnifyingglass"
                        ) {
                            onOpenSearch?()
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Playback language",
                            subtitle: "\(playbackLanguage.flagEmoji) \(playbackLanguage.title) · \(playbackLanguage.providerCount) providers",
                            systemImage: "globe"
                        ) {
                            showLanguagePicker = true
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Settings",
                            subtitle: "Subtitles, captions, player, backup",
                            systemImage: "gearshape.fill"
                        ) {
                            path.append(MoreRoute.settings)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Library",
                            subtitle: "Continue, watchlist, watched",
                            systemImage: "bookmark.fill"
                        ) {
                            path.append(MoreRoute.library)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Profiles",
                            subtitle: "\(ProfileStore.shared.activeProfile.displayName) · switch, Kids, PIN",
                            systemImage: "person.2.fill"
                        ) {
                            path.append(MoreRoute.profiles)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Cloud Sync",
                            subtitle: CloudSyncManager.shared.email ?? "Supabase watchlist & history sync",
                            systemImage: "icloud.fill"
                        ) {
                            path.append(MoreRoute.cloudSync)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Year in Review",
                            subtitle: "Hours, top series & longest binge",
                            systemImage: "chart.bar.fill"
                        ) {
                            path.append(MoreRoute.yearReview)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Provider Diagnostics",
                            subtitle: "Smoke-test providers & health",
                            systemImage: "stethoscope"
                        ) {
                            path.append(MoreRoute.diagnostics)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Stremio",
                            subtitle: addonHubSubtitle,
                            systemImage: "puzzlepiece.extension.fill"
                        ) {
                            path.append(MoreRoute.stremioHub)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Manage plugins",
                            subtitle: "Install, reorder, health",
                            systemImage: "slider.horizontal.3"
                        ) {
                            path.append(MoreRoute.stremioSettings)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Debrid",
                            subtitle: debridHubSubtitle,
                            systemImage: "key.horizontal.fill"
                        ) {
                            path.append(MoreRoute.stremioDebrid)
                        }
                    }
                    .padding(.horizontal, 20)

                    StremioStatusStripView()
                        .padding(.horizontal, 20)

                    if let languageConfirmation {
                        Text(languageConfirmation)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(environment.theme.accentBright)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Support")
                            .font(DesignTokens.Typography.shelfTitle)
                            .padding(.horizontal, 20)
                        SupportCTAStack()
                            .padding(.horizontal, 20)
                    }

                    hubCard {
                        Button {
                            Task { await checkForUpdates() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(environment.theme.accentBright)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isCheckingForUpdates ? "Checking…" : "Check for updates")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Text(appVersionLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isCheckingForUpdates {
                                    ProgressView()
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingForUpdates)

                        Divider().opacity(0.35)

                        Link(destination: SupportLinks.githubRepository) {
                            hubLabel(
                                title: "GitHub",
                                subtitle: "Source and releases",
                                systemImage: "chevron.left.forwardslash.chevron.right"
                            )
                        }

                        Divider().opacity(0.35)

                        Button {
                            showCredits = true
                        } label: {
                            hubLabel(
                                title: "Credits",
                                subtitle: "TMDB, open source, community",
                                systemImage: "star.bubble"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)

                    Text("BetterStreamflix does not host media. Use it only for content you are authorized to access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
                .background {
                    AppScreenBackground()
                        .padding(.vertical, -400)
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background { AppScreenBackground() }
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .tabBar)
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView(showsInlineTitle: true)
                case .library:
                    LibraryView(showsInlineTitle: true)
                case .stremioHub:
                    StremioCatalogHubView()
                case .stremioSettings:
                    StremioAddonsSettingsView()
                case .stremioDebrid:
                    StremioDebridSettingsView()
                case .liveTV:
                    LiveTVView()
                case .manga:
                    MangaHomeView()
                case .profiles:
                    ProfilesView()
                case .cloudSync:
                    CloudSyncView()
                case .yearReview:
                    YearReviewView()
                case .diagnostics:
                    ProviderDiagnosticsView()
                }
            }
            .sheet(item: $updateCheckResult) { result in
                UpdateCheckSheet(result: result)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showCredits) {
                CreditsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLanguagePicker) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("The player only uses sources from the language you pick.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PlaybackLanguagePickerGrid(
                                selected: playbackLanguage,
                                onSelect: { group in
                                    playbackLanguage = group
                                    AppSetupStore.setActivePlaybackLanguageGroup(group)
                                    DesignTokens.Haptics.primaryAction()
                                    languageConfirmation = group.confirmationMessage
                                    showLanguagePicker = false
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.8))
                                        if languageConfirmation == group.confirmationMessage {
                                            languageConfirmation = nil
                                        }
                                    }
                                }
                            )
                        }
                        .padding(20)
                    }
                    .background { AppScreenBackground() }
                    .navigationTitle("Playback language")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLanguagePicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(environment)
            }
            .onAppear {
                playbackLanguage = AppSetupStore.activePlaybackLanguageGroup
                consumeShortcutRoute()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppSetupStore.languageDidChangeNotification)) { _ in
                playbackLanguage = AppSetupStore.activePlaybackLanguageGroup
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("stremio.shortcut.moreRoute"))) { note in
                applyShortcutRoute(note.object as? String)
            }
        }
    }

    private func consumeShortcutRoute() {
        let raw = UserDefaults.standard.string(forKey: "stremio.shortcut.moreRoute.v1")
        UserDefaults.standard.removeObject(forKey: "stremio.shortcut.moreRoute.v1")
        applyShortcutRoute(raw)
    }

    private func applyShortcutRoute(_ raw: String?) {
        let named: [String: MoreRoute] = [
            "liveTV": .liveTV, "manga": .manga, "profiles": .profiles, "cloudSync": .cloudSync,
            "yearReview": .yearReview, "diagnostics": .diagnostics, "library": .library, "settings": .settings,
        ]
        if let raw, let route = named[raw] {
            UserDefaults.standard.removeObject(forKey: "stremio.shortcut.moreRoute.v1")
            if path.isEmpty { path.append(route) }
            return
        }
        guard let raw, let route = StremioShortcutBridge.Route(rawValue: raw) else { return }
        switch route {
        case .hub:
            path.append(MoreRoute.stremioHub)
        case .debrid:
            path.append(MoreRoute.stremioDebrid)
        case .addons:
            path.append(MoreRoute.stremioSettings)
        case .resume:
            break
        }
    }

    private var exploreCards: some View {
        HStack(spacing: 12) {
            exploreCard(
                title: "Live TV",
                subtitle: "\(LiveTVProviders.all().count) sources · Pluto, Vavoo, IPTV",
                systemImage: "dot.radiowaves.left.and.right",
                colors: [Color(hex: 0xE5383B), Color(hex: 0x5A1220)]
            ) { path.append(MoreRoute.liveTV) }
            exploreCard(
                title: "Manga",
                subtitle: "\(MangaCatalog.all.count) sources · read offline",
                systemImage: "book.pages.fill",
                colors: [Color(hex: 0x765BFF), Color(hex: 0x241A5C)]
            ) { path.append(MoreRoute.manga) }
        }
    }

    private func exploreCard(
        title: String,
        subtitle: String,
        systemImage: String,
        colors: [Color],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: colors, startPoint: .topTrailing, endPoint: .bottomLeading)
                    Image(systemName: systemImage)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.22))
                        .rotationEffect(.degrees(-8))
                        .offset(x: 10, y: -4)
                        .padding(14)
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: colors[0].opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(PressablePosterButtonStyle())
    }

    private var tabBarCard: some View {
        let slots = TabBarSlots.parse(tabSlotsRaw)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tab Bar").font(.headline.weight(.semibold)).foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text("\(slots.count) of \(TabBarSlots.maxSlots)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(TabBarDestination.allCases) { destination in
                    let selected = slots.contains(destination)
                    let full = !selected && slots.count >= TabBarSlots.maxSlots
                    Button {
                        DesignTokens.Haptics.selection()
                        withAnimation(DesignTokens.Motion.soft) {
                            tabSlotsRaw = TabBarSlots.toggled(destination, in: tabSlotsRaw)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: destination.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                            Text(destination.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? Color(hex: 0x11141C) : .white.opacity(full ? 0.3 : 0.8))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? AnyShapeStyle(environment.theme.accentBright) : AnyShapeStyle(Color.white.opacity(0.06)))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(full)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("Pick three destinations to show between Home and More.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func hubCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func hubRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            hubLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func hubLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(environment.theme.accentBright)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.6"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "Installed \(version) (\(build))"
    }

    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        let outcome = await UpdateCheckService().evaluate(
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )
        switch outcome {
        case .newerRelease(let info):
            updateCheckResult = .updateAvailable(info)
        case .upToDate(let version, let build):
            updateCheckResult = .upToDate(version: version, build: build)
        case .unavailable(let version, let build):
            updateCheckResult = .unavailable(version: version, build: build)
        }
    }
}

private enum MoreRoute: Hashable {
    case settings, library, stremioHub, stremioSettings, stremioDebrid, liveTV, manga, profiles, cloudSync, yearReview, diagnostics
}

private extension MoreView {
    var addonHubSubtitle: String {
        let store = StremioAddonStore.shared
        let count = store.enabledAddons.count
        if count == 0 { return "Community catalogs & streams" }
        return "\(count) plugins · catalogs & streams"
    }

    var debridHubSubtitle: String {
        let debrid = StremioDebridStore.shared
        if let profile = debrid.preferredProfile {
            return "\(profile.service.title) · ready for HTTP streams"
        }
        return "Real-Debrid / AllDebrid / Premiumize / TorBox"
    }
}
