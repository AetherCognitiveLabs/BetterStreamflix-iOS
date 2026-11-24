import Combine
import Foundation
import WidgetKit

/// Row shown by the Continue Watching widget; mirrored in the widget target.
struct WidgetContinueRow: Codable, Hashable, Sendable {
    var contentID: String? = nil
    let title: String
    let subtitle: String?
    let progress: Double
    let artworkURL: URL?
}

/// Tile shown by the Live Favorites widget; mirrored in the widget target.
struct WidgetLiveRow: Codable, Hashable, Sendable {
    let channelID: String
    let providerID: String
    let title: String
    let logo: URL?
}

struct WidgetLiveSnapshot: Codable, Sendable {
    let rows: [WidgetLiveRow]
    let updatedAt: Date
}

struct WidgetContinueSnapshot: Codable, Sendable {
    let rows: [WidgetContinueRow]
    let updatedAt: Date
}

/// `betterstreamflix://continue?id=<contentID>` links from the widgets. A row
/// resumes that title in the player (like Android's watch deep link); the
/// bare link opens the Library.
enum WidgetDeepLink {
    static let didReceive = Notification.Name("widget.deepLink.didReceive")
    private static let pendingKey = "widget.deepLink.pending.v1"

    enum Target: Equatable {
        case continueWatching(contentID: String?)
        case liveHub
        case liveChannel(id: String, providerID: String)
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == "betterstreamflix" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch url.host?.lowercased() {
        case "continue": return .continueWatching(contentID: value("id"))
        case "live":
            guard let id = value("id"), let provider = value("provider") else { return .liveHub }
            return .liveChannel(id: id, providerID: provider)
        default: return nil
        }
    }

    /// Called from `onOpenURL`; RootView picks the target up via notification,
    /// or from the pending slot when it wasn't on screen yet.
    @MainActor
    static func handle(_ url: URL) -> Bool {
        guard parse(url) != nil else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: pendingKey)
        NotificationCenter.default.post(name: didReceive, object: url.absoluteString)
        return true
    }

    static func consumePending() -> Target? {
        guard let raw = UserDefaults.standard.string(forKey: pendingKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return URL(string: raw).flatMap(parse)
    }
}

/// Writes the newest continue-watching rows into the App Group container for
/// the widget and asks WidgetKit to reload, like Android's WidgetUpdater.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()
    static let appGroup = "group.com.betterstreamflix.ios"
    static let fileName = "widget-continue-watching.json"
    static let widgetKind = "ContinueWatching"
    static let liveFileName = "widget-live-favorites.json"
    static let liveWidgetKind = "LiveFavorites"

    private var cancellable: AnyCancellable?
    private var lastRows: [WidgetContinueRow]?

    func start(library: LibraryStore) {
        guard cancellable == nil else { return }
        writeLiveFavorites()
        cancellable = library.$progress
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self, weak library] _ in
                guard let self, let library else { return }
                self.write(library)
            }
    }

    /// Up to four starred channels; none on Kids profiles, matching Android's
    /// age gate for live tiles.
    func writeLiveFavorites() {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
        let rows = ProfileStore.shared.activeProfile.isKids ? [] : LiveFavoritesStore.shared.favorites.prefix(4).map {
            WidgetLiveRow(channelID: $0.channelID, providerID: $0.providerID, title: $0.name, logo: $0.logo)
        }
        guard let data = try? JSONEncoder().encode(WidgetLiveSnapshot(rows: rows, updatedAt: Date())) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.liveFileName), options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.liveWidgetKind)
    }

    func write(_ library: LibraryStore) {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
        let rows = library.continueWatching
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { progress in
                WidgetContinueRow(
                    contentID: progress.contentID,
                    title: progress.media.title,
                    subtitle: progress.episode.map { episode in
                        ["S\(episode.seasonNumber) E\(episode.number)", progress.episodeDisplayTitle]
                            .compactMap { $0 }.joined(separator: " · ")
                    } ?? progress.resumeLabel,
                    progress: progress.fraction,
                    artworkURL: progress.media.posterURL ?? progress.continueWatchingArtworkURL
                )
            }
        guard rows != lastRows else { return }
        lastRows = rows
        let snapshot = WidgetContinueSnapshot(rows: rows, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
}
