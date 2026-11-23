import SwiftUI

/// Live channel browser: one provider at a time, channels grouped into
/// sections, searchable, tap to play with the channel's headers.
struct LiveTVView: View {
    private let providers = LiveTVProviders.all()
    @AppStorage("liveTV.providerID") private var providerID = M3UPlaylistLiveProvider.plutoTVDE.id
    @State private var groups: [LiveChannelGroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var playing: LiveChannel?
    @State private var outageIDs: [String] = []

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

    var body: some View {
        List {
            if !outageIDs.isEmpty {
                Section { outageNotice }
            }
            ForEach(visibleGroups) { group in
                Section("\(group.name) · \(group.channels.count)") {
                    ForEach(group.channels) { channel in
                        Button { playing = channel } label: { LiveChannelRow(channel: channel) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { statusOverlay }
        .searchable(text: $query, prompt: "Search channels")
        .navigationTitle("Live TV")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Provider", selection: $providerID) {
                        ForEach(providers, id: \.id) { Text($0.displayName).tag($0.id) }
                    }
                } label: {
                    Label(provider.displayName, systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .task(id: providerID) { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $playing) { channel in
            let provider = provider
            LivePlayerView(channel: channel) { try await provider.resolve(channel) }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if groups.isEmpty {
            if isLoading {
                ProgressView("Loading \(provider.displayName)…")
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.largeTitle)
                    Text(errorMessage).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }

    private var outageNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(outageIDs.count == 1 ? "Provider unavailable" : "\(outageIDs.count) providers unavailable")
                    .font(.subheadline.weight(.semibold))
                Text(outageIDs.map(displayName(for:)).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss") {
                ProviderOutagePolicy.dismiss()
                outageIDs = []
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func displayName(for id: String) -> String {
        providers.first { $0.id == id }?.displayName ?? id
    }

    private func load() async {
        let provider = provider
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let channels = try await ProviderHealth.shared.guarded(provider.id) { try await provider.channels() }
            guard !Task.isCancelled else { return }
            groups = LiveChannelGroup.grouping(channels)
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

private struct LiveChannelRow: View {
    let channel: LiveChannel

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: channel.logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv").foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.body.weight(.medium)).lineLimit(1)
                if let now = channel.programNow {
                    Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
