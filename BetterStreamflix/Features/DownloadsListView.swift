import SwiftUI

/// Library segment listing offline copies with progress, size and retry/delete.
struct DownloadsListView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @ObservedObject private var mangaDownloads = MangaDownloadManager.shared
    @State private var mangaReader: MangaReaderTarget?
    var onPlay: (PlaybackRequest) -> Void

    var body: some View {
        if manager.items.isEmpty && mangaDownloads.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("No downloads yet").font(.headline).foregroundStyle(AppTheme.primaryText)
                Text("Start a title, then choose Download in the player's settings menu. Manga chapters download from a title's chapter list (swipe a chapter).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !manager.items.isEmpty {
                Section {
                    ForEach(manager.items) { item in
                        row(item)
                            .swipeActions {
                                Button(role: .destructive) { manager.remove(item.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("\(Self.size(manager.totalBytesOnDisk)) on this device")
                }
                }
                MangaDownloadsSection(reader: $mangaReader)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .fullScreenCover(item: $mangaReader) { target in
                MangaReaderView(manga: target.manga, chapterIndex: target.chapterIndex, startPage: target.page)
            }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        Button {
            if item.state == .completed { onPlay(item.request) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline).foregroundStyle(AppTheme.primaryText).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status(item)
                }
                Spacer(minLength: 8)
                trailing(item)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func status(_ item: DownloadItem) -> some View {
        switch item.state {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            ProgressView(value: item.progress)
            Text(progressText(item)).font(.caption2).foregroundStyle(.secondary)
        case .completed:
            Text("Downloaded · \(Self.size(item.bytesOnDisk)) · \(item.providerName)")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text(item.errorMessage ?? "Download failed").font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private func trailing(_ item: DownloadItem) -> some View {
        switch item.state {
        case .completed:
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
        case .failed:
            Button { manager.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry download")
        case .queued, .downloading:
            Button { manager.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel download")
        }
    }

    private func progressText(_ item: DownloadItem) -> String {
        var parts = ["\(Int(item.progress * 100))%"]
        if item.bytesOnDisk > 0 {
            parts.append(item.expectedBytes > 0
                ? "\(Self.size(item.bytesOnDisk)) of \(Self.size(item.expectedBytes))"
                : Self.size(item.bytesOnDisk))
        }
        return parts.joined(separator: " · ")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
