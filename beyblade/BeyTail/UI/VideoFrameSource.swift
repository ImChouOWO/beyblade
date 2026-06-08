import AVFoundation
import UIKit

@MainActor
final class VideoFrameSource: NSObject {

    let player = AVPlayer()

    var hasActiveItem: Bool {
        player.currentItem != nil
    }

    var onFrame: (@MainActor (CMSampleBuffer) -> Void)?
    var onEnded: (@MainActor () -> Void)?

    private var playerItem: AVPlayerItem?
    private var observedEndItem: AVPlayerItem?

    private var loadTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?

    private var currentAsset: AVURLAsset?
    private var currentVideoURL: URL?

    private var loadToken = UUID()
    private var shouldAutoPlay = false

    // MARK: - Load

    func load(
        url: URL,
        autoPlay: Bool,
        onReady: (@MainActor () -> Void)? = nil,
        onFailed: (@MainActor (String) -> Void)? = nil
    ) {
        let token = UUID()
        loadToken = token
        shouldAutoPlay = autoPlay

        let oldURL = currentVideoURL

        cancelLoadTasks()
        stopRuntimeOnly(removeCurrentItem: true)

        deleteTemporaryVideoIfNeeded(oldURL)

        currentVideoURL = url

        loadTask = Task { @MainActor [weak self, url, token, autoPlay] in
            guard let self else {
                return
            }

            let asset = AVURLAsset(url: url)
            self.currentAsset = asset

            do {
                let isPlayable = try await asset.load(.isPlayable)

                guard self.isCurrentLoad(token) else {
                    return
                }

                guard isPlayable else {
                    onFailed?("asset is not playable")
                    return
                }

                self.installAsset(
                    asset,
                    token: token,
                    autoPlay: autoPlay,
                    onReady: onReady,
                    onFailed: onFailed
                )

            } catch {
                guard self.isCurrentLoad(token) else {
                    return
                }

                onFailed?(error.localizedDescription)
            }
        }
    }

    private func installAsset(
        _ asset: AVURLAsset,
        token: UUID,
        autoPlay: Bool,
        onReady: (@MainActor () -> Void)?,
        onFailed: (@MainActor (String) -> Void)?
    ) {
        guard isCurrentLoad(token) else {
            return
        }

        stopRuntimeOnly(removeCurrentItem: true)

        let item = AVPlayerItem(asset: asset)

        playerItem = item
        observedEndItem = item
        shouldAutoPlay = autoPlay

        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        player.isMuted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        waitUntilReady(
            token: token,
            onReady: onReady,
            onFailed: onFailed
        )
    }

    private func waitUntilReady(
        token: UUID,
        onReady: (@MainActor () -> Void)?,
        onFailed: (@MainActor (String) -> Void)?
    ) {
        readyTask?.cancel()

        readyTask = Task { @MainActor [weak self, token] in
            guard let self else {
                return
            }

            try? await Task.sleep(for: .milliseconds(80))

            guard self.isCurrentLoad(token) else {
                return
            }

            guard let item = self.player.currentItem else {
                onFailed?("player currentItem is nil")
                return
            }

            if let error = item.error {
                onFailed?(error.localizedDescription)
                return
            }

            let didSeek = await self.player.seek(
                to: .zero,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )

            guard self.isCurrentLoad(token) else {
                return
            }

            guard didSeek else {
                onFailed?("player seek failed")
                return
            }

            if let error = item.error {
                onFailed?(error.localizedDescription)
                return
            }

            onReady?()

            if self.shouldAutoPlay {
                self.play()
            }
        }
    }

    // MARK: - Playback

    func play() {
        guard player.currentItem != nil else {
            return
        }

        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        let oldURL = currentVideoURL

        loadToken = UUID()
        shouldAutoPlay = false

        cancelLoadTasks()
        stopRuntimeOnly(removeCurrentItem: true)

        currentAsset?.cancelLoading()
        currentAsset = nil
        currentVideoURL = nil

        deleteTemporaryVideoIfNeeded(oldURL)
    }

    func forceResetAfterFailedLoad() {
        stop()
    }

    // MARK: - Cleanup

    private func cancelLoadTasks() {
        loadTask?.cancel()
        loadTask = nil

        readyTask?.cancel()
        readyTask = nil
    }

    private func stopRuntimeOnly(removeCurrentItem: Bool) {
        player.pause()
        player.cancelPendingPrerolls()

        removeEndObserver()

        playerItem = nil

        if removeCurrentItem {
            player.replaceCurrentItem(with: nil)
        }
    }

    private func removeEndObserver() {
        if let observedEndItem {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemDidPlayToEndTime,
                object: observedEndItem
            )

            self.observedEndItem = nil
        }
    }

    private func deleteTemporaryVideoIfNeeded(_ url: URL?) {
        guard let url else {
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
        let target = url.standardizedFileURL

        guard target.path.hasPrefix(tempDir.path) else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        } catch {
            // ignore temporary file cleanup failure
        }
    }

    private func isCurrentLoad(_ token: UUID) -> Bool {
        loadToken == token && !Task.isCancelled
    }

    // MARK: - End

    @objc private func playerItemDidEnd(_ notification: Notification) {
        guard let endedItem = notification.object as? AVPlayerItem else {
            return
        }

        guard observedEndItem === endedItem else {
            return
        }

        print("[VIDEO] player item did end")

        player.pause()
        player.cancelPendingPrerolls()

        shouldAutoPlay = false

        removeEndObserver()

        onEnded?()
    }
}
