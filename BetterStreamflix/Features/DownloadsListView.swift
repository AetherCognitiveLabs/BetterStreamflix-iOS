import SwiftUI

/// Library segment listing offline copies with progress, size and retry/delete.
struct DownloadsListView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @ObservedObject private var mangaDownloads = MangaDownloadManager.shared
    @State private var mangaReader: MangaReaderTarget?
    var onPlay: (PlaybackRequest) -> Void

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Group {
            if manager.items.isEmpty && mangaDownloads.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        storageCard
                        if !manager.items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Movies & Series").font(DesignTokens.Typography.shelfTitle).foregroundStyle(.white)
                                VStack(spacing: 0) {
                                    ForEach(Array(manager.items.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 { Divider().overlay(AppTheme.border).padding(.leading, 82) }
                                        row(item)
                                    }
                                }
                                .appSurface(cornerRadius: DesignTokens.Radius.card)
                            }
                        }
                        MangaDownloadsSection(reader: $mangaReader)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
            }
        }
        .fullScreenCover(item: $mangaReader) { target in
            MangaReaderView(manga: target.manga, chapterIndex: target.chapterIndex, startPage: target.page)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x262B3A), Color(hex: 0x141824)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
                        .frame(width: 70, height: 105)
                        .rotationEffect(.degrees(Double(index - 1) * 12))
                        .offset(x: CGFloat(index - 1) * 38, y: index == 1 ? -6 : 4)
                        .zIndex(index == 1 ? 1 : 0)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(hex: 0x11141C))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(environment.theme.accentBright))
                    .shadow(color: environment.theme.accent.opacity(0.6), radius: 16)
                    .offset(y: 46)
                    .zIndex(2)
            }
            .frame(height: 170)
            Text("Nothing downloaded yet").font(.title3.weight(.bold)).foregroundStyle(.white)
            Text("Choose Download in the player's settings menu to keep a movie or episode offline. Manga chapters download from a title's chapter list.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var storageCard: some View {
        let video = manager.totalBytesOnDisk
        let manga = mangaDownloads.totalBytesOnDisk
        let total = max(video + manga, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ON THIS DEVICE").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.5))
                    Text(Self.size(video + manga)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                Spacer()
                Text("\(manager.items.count + mangaDownloads.items.count) items")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    Capsule().fill(environment.theme.accentBright)
                        .frame(width: max(video > 0 ? 6 : 0, proxy.size.width * CGFloat(video) / CGFloat(total)))
                    Capsule().fill(Color(hex: 0x765BFF))
                        .frame(width: max(manga > 0 ? 6 : 0, proxy.size.width * CGFloat(manga) / CGFloat(total) - 3))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Capsule().fill(.white.opacity(0.07)))
            HStack(spacing: 16) {
                legend("Video · \(Self.size(video))", color: environment.theme.accentBright)
                legend("Manga · \(Self.size(manga))", color: Color(hex: 0x765BFF))
            }
        }
        .padding(18)
        .appSurface(cornerRadius: DesignTokens.Radius.card)
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        Button {
            if item.state == .completed { onPlay(item.request) }
        } label: {
            HStack(spacing: 14) {
                CachedRemoteImage(url: item.request.media.posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack { AppTheme.surface; Image(systemName: "film").foregroundStyle(.white.opacity(0.3)) }
                }
                .frame(width: 54, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    status(item)
                }
                Spacer(minLength: 8)
                trailing(item)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Download", systemImage: "trash", role: .destructive) { manager.remove(item.id) }
        }
    }

    @ViewBuilder
    private func status(_ item: DownloadItem) -> some View {
        switch item.state {
        case .queued:
            Text("Queued").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.5))
        case .downloading:
            DownloadProgressBar(progress: item.progress, color: environment.theme.accentBright)
            Text(progressText(item)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        case .completed:
            Text("\(Self.size(item.bytesOnDisk)) · \(item.providerName)")
                .font(.caption2).foregroundStyle(.white.opacity(0.5))
        case .failed:
            Text(item.errorMessage ?? "Download failed").font(.caption2).foregroundStyle(Color(hex: 0xFF6B6B)).lineLimit(2)
        }
    }

    @ViewBuilder
    private func trailing(_ item: DownloadItem) -> some View {
        switch item.state {
        case .completed:
            DownloadCircleIcon(systemImage: "play.fill", filled: true, color: environment.theme.accentBright)
        case .failed:
            Button { manager.retry(item.id) } label: { DownloadCircleIcon(systemImage: "arrow.clockwise", filled: false, color: .white) }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry download")
        case .queued, .downloading:
            Button { manager.cancel(item.id) } label: { DownloadCircleIcon(systemImage: "xmark", filled: false, color: .white) }
                .buttonStyle(.plain)
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

struct DownloadProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 4)
    }
}

struct DownloadCircleIcon: View {
    let systemImage: String
    let filled: Bool
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(filled ? Color(hex: 0x11141C) : color)
            .frame(width: 34, height: 34)
            .background(Circle().fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(Color.white.opacity(0.08))))
    }
}
