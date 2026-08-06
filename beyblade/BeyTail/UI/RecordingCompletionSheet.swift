import SwiftUI
import AVKit
import AVFoundation
import Combine
import UIKit

struct RecordingCompletionSheet: View {

    @ObservedObject var vm: MainViewModel

    let videoURL: URL

    @StateObject private var playerModel: RecordingPreviewPlayerModel
    @State private var deviceOrientation: UIDeviceOrientation = .portrait

    private let screenEdgeSpacing: CGFloat = 10
    private let previewControlSpacing: CGFloat = 5

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
        GeometryReader { geometry in
            let screenSize = geometry.size
            let availableSize = CGSize(
                width: max(screenSize.width - screenEdgeSpacing * 2, 1),
                height: max(screenSize.height - screenEdgeSpacing * 2, 1)
            )
            let rotatedContentSize = contentSize(
                for: availableSize,
                orientation: deviceOrientation
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                pageContent(size: rotatedContentSize)
                    .frame(
                        width: rotatedContentSize.width,
                        height: rotatedContentSize.height
                    )
                    .rotationEffect(rotationAngle)
                    .position(
                        x: screenSize.width / 2,
                        y: screenSize.height / 2
                    )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateDeviceOrientation(UIDevice.current.orientation)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification
            )
        ) { _ in
            updateDeviceOrientation(UIDevice.current.orientation)
        }
        .onDisappear {
            playerModel.stop()
        }
    }

    private func pageContent(size: CGSize) -> some View {
        let isLandscape = size.width > size.height
        let controlHeight = controlPanelHeight(
            for: size,
            isLandscape: isLandscape
        )
        let previewHeight = max(
            size.height - controlHeight - previewControlSpacing,
            1
        )

        return VStack(spacing: previewControlSpacing) {
            videoPreview
                .frame(
                    width: size.width,
                    height: previewHeight
                )

            controlPanel(isLandscape: isLandscape)
                .frame(
                    width: size.width,
                    height: controlHeight
                )
        }
    }

    private var videoPreview: some View {
        VideoPlayer(player: playerModel.player)
            .background(Color.black)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .stroke(
                    Color.white.opacity(0.10),
                    lineWidth: 1
                )
            }
            .overlay(alignment: .topLeading) {
                Label(
                    "錄影完成",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.68))
                )
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    playerModel.stop()
                    vm.dismissRecordingResult()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.68))
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.recordingSaveState == .saving)
                .opacity(
                    vm.recordingSaveState == .saving
                        ? 0.45
                        : 1.0
                )
                .padding(8)
            }
    }

    @ViewBuilder
    private func controlPanel(isLandscape: Bool) -> some View {
        if isLandscape {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    playbackControls
                        .frame(maxWidth: .infinity)

                    actionButtons
                        .frame(maxWidth: 330)
                }

                recordingStatusView
                    .frame(height: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(controlPanelBackground)
        } else {
            VStack(spacing: 6) {
                playbackControls

                Divider()
                    .overlay(Color.white.opacity(0.10))

                actionButtons

                recordingStatusView
                    .frame(height: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(controlPanelBackground)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button {
                playerModel.togglePlayback()
            } label: {
                Image(
                    systemName: playerModel.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(accentColor)
                )
            }
            .buttonStyle(.plain)

            Text(formatTime(playerModel.currentTime))
                .font(
                    .system(
                        size: 10,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .foregroundColor(.white.opacity(0.70))
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        playerModel.currentTime
                    },
                    set: {
                        playerModel.updateScrubPosition($0)
                    }
                ),
                in: 0...max(
                    max(
                        playerModel.duration,
                        playerModel.currentTime
                    ),
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
            .tint(accentColor)

            Text(formatTime(playerModel.duration))
                .font(
                    .system(
                        size: 10,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .foregroundColor(.white.opacity(0.70))
                .frame(width: 40, alignment: .leading)
        }
        .frame(minHeight: 40)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            ShareLink(item: videoURL) {
                actionButtonLabel(
                    icon: "square.and.arrow.up",
                    title: "分享"
                )
            }
            .buttonStyle(.plain)

            Button {
                vm.saveCompletedRecording()
            } label: {
                actionButtonLabel(
                    icon: downloadIcon,
                    title: downloadTitle
                )
            }
            .buttonStyle(.plain)
            .disabled(
                vm.recordingSaveState == .saving ||
                vm.recordingSaveState == .saved
            )
            .opacity(
                vm.recordingSaveState == .saving ||
                vm.recordingSaveState == .saved
                    ? 0.60
                    : 1.0
            )

            Button {
                playerModel.stop()
                vm.rerecordCompletedVideo()
            } label: {
                actionButtonLabel(
                    icon: "arrow.counterclockwise",
                    title: "重新錄製",
                    destructive: true
                )
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 54)
    }

    private func actionButtonLabel(
        icon: String,
        title: String,
        destructive: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundColor(
            destructive
                ? .red
                : accentColor
        )
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
            .fill(Color.white.opacity(0.065))
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
            .stroke(
                Color.white.opacity(0.08),
                lineWidth: 1
            )
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: 11,
                style: .continuous
            )
        )
    }

    private var controlPanelBackground: some View {
        RoundedRectangle(
            cornerRadius: 14,
            style: .continuous
        )
        .fill(Color(white: 0.045))
        .overlay {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .stroke(
                Color.white.opacity(0.10),
                lineWidth: 1
            )
        }
    }

    private var accentColor: Color {
        Color(
            red: 0.0,
            green: 174.0 / 255.0,
            blue: 239.0 / 255.0
        )
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
            Color.clear

        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)

                Text("正在儲存到照片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.70))
            }

        case .saved:
            Label(
                "影片已儲存到照片",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.green)

        case .failed(let message):
            Label(
                message,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.red)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
        }
    }

    private func controlPanelHeight(
        for size: CGSize,
        isLandscape: Bool
    ) -> CGFloat {
        if isLandscape {
            return min(
                max(size.height * 0.25, 88),
                104
            )
        }

        return min(
            max(size.height * 0.20, 142),
            160
        )
    }

    private var rotationAngle: Angle {
        switch deviceOrientation {
        case .portrait:
            return .degrees(0)

        case .portraitUpsideDown:
            return .degrees(180)

        case .landscapeLeft:
            return .degrees(90)

        case .landscapeRight:
            return .degrees(-90)

        default:
            return .degrees(0)
        }
    }

    private func contentSize(
        for availableSize: CGSize,
        orientation: UIDeviceOrientation
    ) -> CGSize {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            return CGSize(
                width: availableSize.height,
                height: availableSize.width
            )

        default:
            return availableSize
        }
    }

    private func updateDeviceOrientation(
        _ orientation: UIDeviceOrientation
    ) {
        switch orientation {
        case .portrait,
             .portraitUpsideDown,
             .landscapeLeft,
             .landscapeRight:
            deviceOrientation = orientation

        default:
            break
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0 else {
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
            forInterval: CMTime(
                seconds: 0.1,
                preferredTimescale: 600
            ),
            queue: .main
        ) { [weak self] time in
            guard let self else {
                return
            }

            let durationSeconds =
                self.player.currentItem?.duration.seconds ?? 0

            if durationSeconds.isFinite,
               durationSeconds > 0 {
                self.duration = durationSeconds
            }

            let currentSeconds = time.seconds

            if !self.isSeeking,
               currentSeconds.isFinite,
               currentSeconds >= 0 {
                self.currentTime = min(
                    currentSeconds,
                    max(
                        self.duration,
                        currentSeconds
                    )
                )
            }

            self.isPlaying = self.player.rate != 0
        }

        playbackEndedObserver =
            NotificationCenter.default.addObserver(
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
            NotificationCenter.default.removeObserver(
                playbackEndedObserver
            )
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
        currentTime = min(
            max(seconds, 0),
            max(duration, 0)
        )
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
