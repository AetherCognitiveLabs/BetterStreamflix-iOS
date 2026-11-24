import SwiftUI

/// Live channel browser: one provider at a time, channels grouped into
/// sections, searchable, tap to play with the channel's headers.
struct LiveTVView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let providers = LiveTVProviders.all()
    @AppStorage("liveTV.providerID") private var providerID = M3UPlaylistLiveProvider.plutoTVDE.id
    @State private var groups: [LiveChannelGroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var playing: LiveChannel?
    @State private var outageIDs: [String] = []
    @ObservedObject private var favorites = LiveFavoritesStore.shared
    var isTabRoot = false

    private var provider: any LiveTVProvider {
        providers.first { $0.id == providerID } ?? providers[0]
    }

    private var visibleGroups: [LiveChannelGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.name.localizedCaseInsensitiveContains(needle)
                ? group.channels
                : group.channels.filter { $0.name.localizedCaseInsensitiveContains(needle) }
            return matches.isEmpty ? nil : LiveChannelGroup(name: group.name, channels: matches)
        }
    }

    private var allChannels: [LiveChannel] { groups.flatMap(\.channels) }

    /// Featured "On Now" cards: favourites first, then channels with guide data.
    private var featured: [LiveChannel] {
        let favoriteChannels = favorites.favorites.map(\.channel)
        if !favoriteChannels.isEmpty { return Array(favoriteChannels.prefix(6)) }
        let withGuide = allChannels.filter { $0.programNow != nil }
        return Array((withGuide.isEmpty ? allChannels : withGuide).prefix(6))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header
                AppInlineSearchField(text: $query, prompt: "Search channels")
                    .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                providerChips
                if !outageIDs.isEmpty {
                    outageNotice.padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                }
                if groups.isEmpty {
                    statusView
                } else if query.isEmpty {
                    if !featured.isEmpty { featuredCarousel }
                    if !favorites.favorites.isEmpty {
                        channelShelf("Favorites", channels: favorites.favorites.map(\.channel))
                    }
                    ForEach(groups) { group in
                        channelShelf(group.name, channels: group.channels)
                    }
                } else {
                    searchResults
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isTabRoot ? .hidden : .automatic, for: .navigationBar)
        .task(id: providerID) { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $playing) { channel in
            let provider = providers.first { $0.id == channel.providerID } ?? provider
            LivePlayerView(channel: channel) { try await provider.resolve(channel) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live TV")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 3)
            Text(groups.isEmpty ? provider.displayName : "\(allChannels.count) channels · \(provider.displayName)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        .padding(.top, 4)
    }

    private var providerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providers, id: \.id) { source in
                    let selected = source.id == providerID
                    Button {
                        DesignTokens.Haptics.selection()
                        withAnimation(DesignTokens.Motion.soft) { providerID = source.id }
                    } label: {
                        Text(source.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color(hex: 0x11141C) : .white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if selected {
                                    Capsule().fill(environment.theme.accentBright)
                                } else {
                                    Capsule().fill(AppTheme.surface).overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        }
    }

    private var featuredCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(favorites.favorites.isEmpty ? "On Now" : "Your Channels")
                .font(DesignTokens.Typography.shelfTitle)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(featured) { channel in
                        channelButton(channel) {
                            LiveFeaturedCard(channel: channel, accent: environment.theme.accent)
                        }
                        .containerRelativeFrame(.horizontal) { width, _ in width - 2 * DesignTokens.Spacing.screenHorizontal }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, DesignTokens.Spacing.screenHorizontal, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func channelShelf(_ title: String, channels: [LiveChannel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(DesignTokens.Typography.shelfTitle).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text("\(channels.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(environment.theme.accentBright)
            }
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(channels) { channel in
                        channelButton(channel) {
                            LiveChannelTile(channel: channel, isFavorite: favorites.isFavorite(channel))
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            }
        }
    }

    private var searchResults: some View {
        let matches = visibleGroups.flatMap(\.channels)
        return Group {
            if matches.isEmpty {
                emptyState(symbol: "magnifyingglass", title: "No channels for “\(query)”", message: nil)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                    ForEach(matches.prefix(200)) { channel in
                        channelButton(channel) {
                            LiveChannelTile(channel: channel, isFavorite: favorites.isFavorite(channel), width: nil)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            }
        }
    }

    private func channelButton<Label: View>(_ channel: LiveChannel, @ViewBuilder label: () -> Label) -> some View {
        let isFavorite = favorites.isFavorite(channel)
        return Button {
            DesignTokens.Haptics.selection()
            playing = channel
        } label: { label() }
            .buttonStyle(PressablePosterButtonStyle())
            .contextMenu {
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                    favorites.toggle(channel)
                }
            }
    }

    @ViewBuilder
    private var statusView: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading \(provider.displayName)…").font(DesignTokens.Typography.caption).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)
        } else if let errorMessage {
            emptyState(symbol: "antenna.radiowaves.left.and.right.slash", title: "No signal", message: errorMessage, retry: true)
        }
    }

    private func emptyState(symbol: String, title: String, message: String?, retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(environment.theme.accentBright)
            Text(title).font(.headline).foregroundStyle(.white)
            if let message {
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            }
            if retry {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.accent, minHeight: 44, verticalPadding: 10))
                    .frame(width: 180)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 32)
    }

    private var outageNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(outageIDs.count == 1 ? "Provider unavailable" : "\(outageIDs.count) providers unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(outageIDs.map(displayName(for:)).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                withAnimation(DesignTokens.Motion.soft) {
                    ProviderOutagePolicy.dismiss()
                    outageIDs = []
                }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
    }

    private func displayName(for id: String) -> String {
        providers.first { $0.id == id }?.displayName ?? id
    }

    private func load() async {
        let provider = provider
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        var loadedChannels: [LiveChannel] = []
        do {
            let channels = try await ProviderHealth.shared.guarded(provider.id) { try await provider.channels() }
            guard !Task.isCancelled else { return }
            groups = LiveChannelGroup.grouping(channels)
            loadedChannels = channels
            if channels.isEmpty {
                errorMessage = await ProviderHealth.shared.isAvailable(provider.id)
                    ? "\(provider.displayName) has no channels right now."
                    : "\(provider.displayName) is paused after repeated failures. Try again in a few minutes."
            }
        } catch is CancellationError {
            return
        } catch {
            groups = []
            errorMessage = "Couldn't load \(provider.displayName).\n\(error.localizedDescription)"
        }
        await refreshOutage()
        isLoading = false
        guard !loadedChannels.isEmpty, LiveEPG.hasGuide(provider.id) else { return }
        let annotated = await LiveEPG.shared.annotate(loadedChannels, providerID: provider.id)
        guard !Task.isCancelled, provider.id == providerID, annotated != loadedChannels else { return }
        groups = LiveChannelGroup.grouping(annotated)
    }

    private func refreshOutage() async {
        let down = await ProviderHealth.shared.outageProviderIDs()
        let relevant = ProviderOutagePolicy.relevantOutageIDs(
            outageIDs: down,
            currentProviderID: providerID,
            enabledProviderIDs: Set(providers.map(\.id))
        )
        outageIDs = ProviderOutagePolicy.shouldShow(relevantIDs: relevant) ? relevant : []
    }
}

/// Channel logo on a dark glass tile, the live-TV counterpart of a poster card.
private struct LiveChannelTile: View {
    let channel: LiveChannel
    var isFavorite = false
    var width: CGFloat? = 156

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LiveLogoPlate(channel: channel, logoPadding: 18)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(width: width)
                .overlay(alignment: .topLeading) {
                    if channel.programNow != nil { LiveBadge().padding(8) }
                }
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.yellow)
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(channel.programNow ?? channel.group ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
    }
}

/// Wide featured card: blurred logo glow, big logo, now/next.
private struct LiveFeaturedCard: View {
    let channel: LiveChannel
    let accent: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [accent.opacity(0.55), AppTheme.surface], startPoint: .topTrailing, endPoint: .bottomLeading)
            LiveLogoImage(url: channel.logo)
                .frame(width: 150, height: 84)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(22)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                LiveBadge()
                Text(channel.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let now = channel.programNow {
                    Text(now).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                if let next = channel.programNext {
                    Text("Next · \(next)").font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .padding(18)
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sheet, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.sheet, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
    }
}

private struct LiveLogoPlate: View {
    let channel: LiveChannel
    var logoPadding: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x1D2230), Color(hex: 0x10131B)], startPoint: .top, endPoint: .bottom))
            .overlay { LiveLogoImage(url: channel.logo).padding(logoPadding) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct LiveLogoImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 5, height: 5)
            Text("LIVE").font(.system(size: 10, weight: .heavy)).tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: 0xE5383B)))
    }
}
