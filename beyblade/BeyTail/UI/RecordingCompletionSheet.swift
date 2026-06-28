import SwiftUI
import AVKit
import AVFoundation
import Combine

// BEYTAIL_FEEDBACK_PATCH 2026.06.28-1
struct RecordingCompletionSheet: View {

    @ObservedObject var vm: MainViewModel

    let videoURL: URL

    @StateObject private var playerModel: RecordingPreviewPlayerModel

    init(
        vm: MainViewModel,
        videoURL: URL
    ) {
        self.vm = vm
        self.videoURL = videoURL
        _playerModel = StateObject(
            wrappedValue: RecordingPreviewPlayerModel(url: videoURL)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                videoPreview
                playbackControls

                HStack(spacing: 12) {
                    ShareLink(item: videoURL) {
                        actionCard(
                            icon: "square.and.arrow.up",
                            title: "分享",
                            subtitle: "分享影片"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        vm.saveCompletedRecording()
                    } label: {
                        actionCard(
                            icon: downloadIcon,
                            title: downloadTitle,
                            subtitle: "儲存到照片"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        vm.recordingSaveState == .saving ||
                        vm.recordingSaveState == .saved
                    )

                    Button {
                        playerModel.stop()
                        vm.rerecordCompletedVideo()
                    } label: {
                        actionCard(
                            icon: "arrow.counterclockwise",
                            title: "重新錄製",
                            subtitle: "捨棄目前影片",
                            destructive: true
                        )
                    }
                    .buttonStyle(.plain)
                }

                recordingStatusView
                    .frame(minHeight: 22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            playerModel.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("錄影完成")
                    .font(.system(size: 19, weight: .bold))

                Text("可播放影片並拖曳進度條確認內容")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var videoPreview: some View {
        VideoPlayer(player: playerModel.player)
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                playerModel.togglePlayback()
            } label: {
                Image(
                    systemName: playerModel.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(Color(red: 0.0, green: 174.0 / 255.0, blue: 239.0 / 255.0))
                )
            }
            .buttonStyle(.plain)

            Text(formatTime(playerModel.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { playerModel.currentTime },
                    set: { playerModel.updateScrubPosition($0) }
                ),
                in: 0...max(
                    max(playerModel.duration, playerModel.currentTime),
                    0.1
                ),
                onEditingChanged: { isEditing in
                    if isEditing {
                        playerModel.beginSeeking()
                    } else {
                        playerModel.endSeeking()
                    }
                }
            )
            .tint(Color(red: 0.0, green: 174.0 / 255.0, blue: 239.0 / 255.0))

            Text(formatTime(playerModel.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }

    private var downloadIcon: String {
        switch vm.recordingSaveState {
        case .saving:
            return "arrow.down.circle"

        case .saved:
            return "checkmark.circle.fill"

        case .idle, .failed:
            return "arrow.down.to.line"
        }
    }

    private var downloadTitle: String {
        switch vm.recordingSaveState {
        case .saving:
            return "下載中"

        case .saved:
            return "已下載"

        case .idle, .failed:
            return "下載"
        }
    }

    @ViewBuilder
    private var recordingStatusView: some View {
        switch vm.recordingSaveState {
        case .idle:
            Text("向下滑動可關閉")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("正在儲存到照片...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

        case .saved:
            Label(
                "影片已儲存到照片",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.green)

        case .failed(let message):
            Label(
                message,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.red)
        }
    }

    private func actionCard(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(
                    destructive
                        ? .red
                        : Color(red: 0.0, green: 174.0 / 255.0, blue: 239.0 / 255.0)
                )

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(
                    destructive ? .red : .primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 105)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(
            RoundedRectangle(cornerRadius: 16)
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "00:00"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(
            format: "%02d:%02d",
            minutes,
            remainingSeconds
        )
    }
}

private final class RecordingPreviewPlayerModel: ObservableObject {

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false

    let player: AVPlayer

    private var periodicTimeObserver: Any?
    private var playbackEndedObserver: NSObjectProtocol?
    private var isSeeking = false
    private var shouldResumeAfterSeeking = false

    init(url: URL) {
        player = AVPlayer(url: url)

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else {
                return
            }

            let durationSeconds = self.player.currentItem?.duration.seconds ?? 0

            if durationSeconds.isFinite, durationSeconds > 0 {
                self.duration = durationSeconds
            }

            let currentSeconds = time.seconds

            if !self.isSeeking,
               currentSeconds.isFinite,
               currentSeconds >= 0 {
                self.currentTime = min(
                    currentSeconds,
                    max(self.duration, currentSeconds)
                )
            }

            self.isPlaying = self.player.rate != 0
        }

        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    deinit {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }

        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
        }
    }

    func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
            return
        }

        if duration > 0,
           currentTime >= duration - 0.1 {
            player.seek(to: .zero)
            currentTime = 0
        }

        player.play()
        isPlaying = true
    }

    func beginSeeking() {
        shouldResumeAfterSeeking = player.rate != 0
        isSeeking = true
        player.pause()
        isPlaying = false
    }

    func updateScrubPosition(_ seconds: Double) {
        currentTime = min(max(seconds, 0), max(duration, 0))
    }

    func endSeeking() {
        let target = CMTime(
            seconds: currentTime,
            preferredTimescale: 600
        )

        player.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.isSeeking = false

            if self.shouldResumeAfterSeeking {
                self.player.play()
                self.isPlaying = true
            }

            self.shouldResumeAfterSeeking = false
        }
    }

    func stop() {
        player.pause()
        isPlaying = false
    }
}
