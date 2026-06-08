import SwiftUI
import AVFoundation
import UIKit

struct VideoPlayerView: UIViewRepresentable {

    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.attachPlayer(player)
        view.setVideoGravity(videoGravity)
        return view
    }

    func updateUIView(
        _ uiView: PlayerView,
        context: Context
    ) {
        uiView.attachPlayer(player)
        uiView.setVideoGravity(videoGravity)
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(
        _ uiView: PlayerView,
        coordinator: ()
    ) {
        uiView.detachPlayer()
    }
}

final class PlayerView: UIView {

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            fatalError("PlayerView layer is not AVPlayerLayer")
        }

        return layer
    }

    func attachPlayer(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = videoGravity
    }

    func detachPlayer() {
        playerLayer.player = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
