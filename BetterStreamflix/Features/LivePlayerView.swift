import AVKit
import SwiftUI

/// Minimal full-screen player for endless live streams. The VOD player is
/// built around discovery requests; live channels only need a URL plus the
/// per-channel headers, passed to AVFoundation via the asset options.
struct LivePlayerView: View {
    let channel: LiveChannel
    let resolve: @Sendable () async throws -> PlaybackSource
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                LivePlayerController(player: player)
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(errorMessage).multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding()
            } else {
                ProgressView(channel.name).tint(.white).foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(.white)
            .padding()
            .accessibilityLabel("Close")
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        errorMessage = nil
        do {
            let source = try await resolve()
            let item = AVPlayerItem(asset: await Self.asset(for: source))
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            player.play()
        } catch {
            errorMessage = "Couldn't start \(channel.name).\n\(error.localizedDescription)"
        }
    }

    static func asset(for source: PlaybackSource) async -> AVURLAsset {
        // Live hosters key their playlists and segments on Referer, which
        // AVURLAssetHTTPHeaderFieldsKey does not forward to HLS subrequests,
        // so remote streams always go through the loopback header proxy.
        if let proxied = await HLSProxyServer.shared.proxiedURL(for: source.url, headers: source.headers) {
            return AVURLAsset(url: proxied)
        }
        guard !source.headers.isEmpty else { return AVURLAsset(url: source.url) }
        return AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
    }
}

private struct LivePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
