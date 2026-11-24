import Combine
import Foundation

/// A starred live channel, stored with everything needed to play it again
/// (stream URL and headers) so the widget and the Live screen can open it
/// without reloading the provider's list.
struct FavoriteLiveChannel: Codable, Hashable, Identifiable, Sendable {
    let channelID: String
    let providerID: String
    let name: String
    let logo: URL?
    let group: String?
    let streamURL: URL
    let headers: [String: String]
    let epgID: String?

    var id: String { Self.key(providerID: providerID, channelID: channelID) }

    static func key(providerID: String, channelID: String) -> String { "\(providerID)|\(channelID)" }

    init(_ channel: LiveChannel) {
        channelID = channel.id
        providerID = channel.providerID
        name = channel.name
        logo = channel.logo
        group = channel.group
        streamURL = channel.streamURL
        headers = channel.headers
        epgID = channel.epgID
    }

    var channel: LiveChannel {
        LiveChannel(
            id: channelID,
            providerID: providerID,
            name: name,
            logo: logo,
            group: group,
            streamURL: streamURL,
            headers: headers,
            epgID: epgID
        )
    }
}

/// Favorite live channels per profile, feeding the Live Favorites widget like
/// Android's LiveHubCatalog favorites.
@MainActor
final class LiveFavoritesStore: ObservableObject {
    static let shared = LiveFavoritesStore()

    @Published private(set) var favorites: [FavoriteLiveChannel] = []
    private var profileID: String
    private var profileObserver: AnyCancellable?

    private init() {
        profileID = ProfileStore.shared.activeProfileID
        load()
        profileObserver = ProfileStore.shared.$activeProfileID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] id in
                self?.profileID = id
                self?.load()
                WidgetSnapshotWriter.shared.writeLiveFavorites()
            }
    }

    func isFavorite(_ channel: LiveChannel) -> Bool {
        let key = FavoriteLiveChannel.key(providerID: channel.providerID, channelID: channel.id)
        return favorites.contains { $0.id == key }
    }

    func favorite(providerID: String, channelID: String) -> FavoriteLiveChannel? {
        let key = FavoriteLiveChannel.key(providerID: providerID, channelID: channelID)
        return favorites.first { $0.id == key }
    }

    func toggle(_ channel: LiveChannel) {
        let entry = FavoriteLiveChannel(channel)
        if favorites.contains(where: { $0.id == entry.id }) {
            favorites.removeAll { $0.id == entry.id }
        } else {
            favorites.insert(entry, at: 0)
        }
        persist()
        WidgetSnapshotWriter.shared.writeLiveFavorites()
    }

    private var storageKey: String { "liveTV.favorites.v1.\(profileID)" }

    private func load() {
        favorites = UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([FavoriteLiveChannel].self, from: $0) } ?? []
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: storageKey)
    }
}
