import Combine
import Foundation
import WidgetKit

/// Row shown by the Continue Watching widget; mirrored in the widget target.
struct WidgetContinueRow: Codable, Hashable, Sendable {
    let title: String
    let subtitle: String?
    let progress: Double
    let artworkURL: URL?
}

struct WidgetContinueSnapshot: Codable, Sendable {
    let rows: [WidgetContinueRow]
    let updatedAt: Date
}

/// Writes the newest continue-watching rows into the App Group container for
/// the widget and asks WidgetKit to reload, like Android's WidgetUpdater.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()
    static let appGroup = "group.com.betterstreamflix.ios"
    static let fileName = "widget-continue-watching.json"
    static let widgetKind = "ContinueWatching"

    private var cancellable: AnyCancellable?
    private var lastRows: [WidgetContinueRow]?

    func start(library: LibraryStore) {
        guard cancellable == nil else { return }
        cancellable = library.$progress
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self, weak library] _ in
                guard let self, let library else { return }
                self.write(library)
            }
    }

    func write(_ library: LibraryStore) {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
        let rows = library.continueWatching
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { progress in
                WidgetContinueRow(
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
