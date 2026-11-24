import SwiftUI
import UIKit
import WidgetKit

/// Mirrors the app's `WidgetLiveRow` (favorite live channels).
struct WidgetLiveRow: Codable, Hashable {
    let channelID: String
    let providerID: String
    let title: String
    let logo: URL?
}

struct WidgetLiveSnapshot: Codable {
    let rows: [WidgetLiveRow]
    let updatedAt: Date
}

enum LiveWidgetLinks {
    static let hub = URL(string: "betterstreamflix://live")!

    static func channel(_ row: WidgetLiveRow) -> URL {
        var components = URLComponents(string: "betterstreamflix://live")
        components?.queryItems = [
            URLQueryItem(name: "id", value: row.channelID),
            URLQueryItem(name: "provider", value: row.providerID),
        ]
        return components?.url ?? hub
    }
}

struct LiveFavoritesEntry: TimelineEntry {
    struct Tile: Identifiable {
        let id = UUID()
        let row: WidgetLiveRow
        let logo: UIImage?
    }

    let date: Date
    let tiles: [Tile]
}

struct LiveFavoritesProvider: TimelineProvider {
    static let fileName = "widget-live-favorites.json"

    func placeholder(in context: Context) -> LiveFavoritesEntry {
        LiveFavoritesEntry(date: Date(), tiles: [
            .init(row: WidgetLiveRow(channelID: "1", providerID: "pluto", title: "Live Channel", logo: nil), logo: nil),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveFavoritesEntry) -> Void) {
        Task { completion(await Self.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveFavoritesEntry>) -> Void) {
        Task {
            let entry = await Self.entry()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
        }
    }

    private static func entry() async -> LiveFavoritesEntry {
        var rows: [WidgetLiveRow] = []
        if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroup),
           let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
           let snapshot = try? JSONDecoder().decode(WidgetLiveSnapshot.self, from: data) {
            rows = Array(snapshot.rows.prefix(4))
        }
        let logos = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask {
                    guard let url = row.logo,
                          let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)) else { return (index, nil) }
                    return (index, UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 240, height: 240)))
                }
            }
            var result: [Int: UIImage] = [:]
            for await (index, image) in group { if let image { result[index] = image } }
            return result
        }
        return LiveFavoritesEntry(date: Date(), tiles: rows.enumerated().map { .init(row: $0.element, logo: logos[$0.offset]) })
    }
}

struct LiveFavoritesWidgetView: View {
    let entry: LiveFavoritesEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Favorites").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if entry.tiles.isEmpty {
                Spacer(minLength: 0)
                Text("Star channels in Live TV to pin them here.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(entry.tiles) { tile in
                        Link(destination: LiveWidgetLinks.channel(tile.row)) { tileView(tile) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.black }
        .widgetURL(LiveWidgetLinks.hub)
    }

    private func tileView(_ tile: LiveFavoritesEntry.Tile) -> some View {
        HStack(spacing: 6) {
            Group {
                if let logo = tile.logo {
                    Image(uiImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "tv").foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 22)
            Text(tile.row.title).font(.caption2.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
    }
}

struct LiveFavoritesWidget: Widget {
    let kind = "LiveFavorites"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiveFavoritesProvider()) { entry in
            LiveFavoritesWidgetView(entry: entry)
        }
        .configurationDisplayName("Live Favorites")
        .description("Your starred live TV channels.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
