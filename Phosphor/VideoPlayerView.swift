import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let asset: ImmichAsset

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            if let player {
                AVPlayerControllerRepresentable(player: player)
                    .ignoresSafeArea()
                    .accessibilityLabel("Video: \(asset.originalFileName)")
            } else {
                ProgressView().tint(.phosphorPrimary)
            }
        }
        .onAppear {
            setupIfNeeded()
            player?.play()
        }
        .onDisappear {
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
        }
    }

    private func setupIfNeeded() {
        guard player == nil,
              let url = ImmichAPI.shared.videoPlaybackURL(for: asset.id)
        else { return }

        let playerItem: AVPlayerItem
        if let key = KeychainManager.get(forKey: ImmichAPI.KeychainKey.apiKey) {
            playerItem = makeAuthenticatedPlayerItem(for: url, apiKey: key)
        } else if let token = KeychainManager.get(forKey: ImmichAPI.KeychainKey.accessToken) {
            let avAsset = AVURLAsset(
                url: url,
                options: [AVURLAssetHTTPHeaderFieldsKey: ["Authorization": "Bearer \(token)"]]
            )
            playerItem = AVPlayerItem(asset: avAsset)
        } else {
            return
        }

        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .pause
        self.player = player

        // Loop only short clips (< 30s); duration loads asynchronously.
        Task {
            guard let item = player.currentItem,
                  let duration = try? await item.asset.load(.duration),
                  duration.seconds > 0,
                  duration.seconds < 30
            else { return }

            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
    }
}

private struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
