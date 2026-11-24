import SwiftUI
import UIKit
import WidgetKit

/// Mirrors the app's `WidgetContinueRow`; the app writes these into the
/// shared App Group container whenever watch progress changes.
struct WidgetContinueRow: Codable, Hashable {
    let title: String
    let subtitle: String?
    let progress: Double
    let artworkURL: URL?
}

struct WidgetContinueSnapshot: Codable {
    let rows: [WidgetContinueRow]
    let updatedAt: Date
}

enum WidgetShared {
    static let appGroup = "group.com.betterstreamflix.ios"
    static let fileName = "widget-continue-watching.json"

    static func load() -> WidgetContinueSnapshot? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
              let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetContinueSnapshot.self, from: data)
    }
}

struct ContinueWatchingEntry: TimelineEntry {
    struct Row: Identifiable {
        let id = UUID()
        let row: WidgetContinueRow
        let artwork: UIImage?
    }

    let date: Date
    let rows: [Row]
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: Date(), rows: [
            .init(row: WidgetContinueRow(title: "Continue Watching", subtitle: "S1 E2", progress: 0.4, artworkURL: nil), artwork: nil),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        Task { completion(await Self.entry(limit: Self.limit(for: context.family))) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        Task {
            let entry = await Self.entry(limit: Self.limit(for: context.family))
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    private static func limit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: 1
        case .systemLarge: 5
        default: 3
        }
    }

    private static func entry(limit: Int) async -> ContinueWatchingEntry {
        let rows = Array((WidgetShared.load()?.rows ?? []).prefix(limit))
        let images = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask { (index, await artwork(row.artworkURL)) }
            }
            var result: [Int: UIImage] = [:]
            for await (index, image) in group { if let image { result[index] = image } }
            return result
        }
        return ContinueWatchingEntry(
            date: Date(),
            rows: rows.enumerated().map { .init(row: $0.element, artwork: images[$0.offset]) }
        )
    }

    private static func artwork(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 240, height: 360))
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    var body: some View {
        Group {
            if entry.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.title2)
                    Text("Nothing to continue").font(.caption.weight(.semibold))
                    Text("Start a title in BetterStreamflix").font(.caption2).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            } else if family == .systemSmall, let first = entry.rows.first {
                small(first)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue Watching").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(entry.rows) { row(for: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) { Color.black }
        .foregroundStyle(.white)
    }

    private func small(_ item: ContinueWatchingEntry.Row) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let artwork = item.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.row.title).font(.caption.weight(.bold)).lineLimit(2)
                if let subtitle = item.row.subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                ProgressView(value: item.row.progress).tint(.red)
            }
            .padding(10)
        }
    }

    private func row(for item: ContinueWatchingEntry.Row) -> some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = item.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 34, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.row.title).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle = item.row.subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                ProgressView(value: item.row.progress).tint(.red)
            }
        }
    }
}

struct ContinueWatchingWidget: Widget {
    let kind = "ContinueWatching"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Resume movies and episodes where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct BetterStreamflixWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
    }
}
