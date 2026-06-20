import AVFoundation
import UIKit
import CoreMedia
import CoreImage

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

    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var lastCopiedItemTime = CMTime.invalid
    private var videoOutputFrameCount = 0

    private var loadTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?

    private var currentAsset: AVURLAsset?
    private var currentVideoURL: URL?

    private var loadToken = UUID()
    private var shouldAutoPlay = false

    /*
     目標：
     - HDR / HLG / Dolby Vision 影片不要過曝。
     - 維持原先影片色調，不額外調 saturation / contrast / brightness。
     - 不在這支程式做 bbox 旋轉。
     - 不在這支程式手動旋轉 pixelBuffer。
    */
    private let enableHDRToneMapping = true

    /*
     CIToneMapHeadroom 參數：
     - targetHeadroom = 1.0 代表輸出到 SDR headroom。
     - sourceHeadroom 是 fallback 估值，讓 HDR 高亮區域被壓回 SDR。
    */
    private let targetHeadroom: Float = 1.0
    private let sourceHeadroomFallback: Float = 4.0

    /*
     如果裝置或系統不支援 CIToneMapHeadroom，才使用這個 fallback。
     inputHighlightAmount 越小，亮部壓得越多。
     不調飽和度、不調對比，避免改變原色調。
    */
    private let fallbackHighlightAmount: Float = 0.35

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

                await self.installAsset(
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
    ) async {
        guard isCurrentLoad(token) else {
            return
        }

        stopRuntimeOnly(removeCurrentItem: true)

        let item = AVPlayerItem(asset: asset)

        if enableHDRToneMapping {
            do {
                item.videoComposition = try await makeHDRToneMappedVideoComposition(
                    asset: asset
                )

                print(
                    "[VIDEO_HDR]",
                    "AVPlayerItem.videoComposition HDR tone mapping enabled",
                    "targetHeadroom:", targetHeadroom,
                    "sourceHeadroomFallback:", sourceHeadroomFallback,
                    "fallbackHighlight:", fallbackHighlightAmount
                )

            } catch {
                print(
                    "[VIDEO_HDR]",
                    "HDR tone mapping composition failed:",
                    error.localizedDescription
                )
            }
        }

        guard isCurrentLoad(token) else {
            return
        }

        let output = makeVideoOutput()
        item.add(output)

        playerItem = item
        observedEndItem = item
        videoOutput = output
        shouldAutoPlay = autoPlay
        lastCopiedItemTime = .invalid
        videoOutputFrameCount = 0

        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        print("[VIDEO_OUTPUT] installed AVPlayerItemVideoOutput")

        waitUntilReady(
            token: token,
            onReady: onReady,
            onFailed: onFailed
        )
    }

    private func makeVideoOutput() -> AVPlayerItemVideoOutput {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        return AVPlayerItemVideoOutput(
            pixelBufferAttributes: pixelBufferAttributes
        )
    }

    // MARK: - HDR Tone Mapping

    private func makeHDRToneMappedVideoComposition(
        asset: AVAsset
    ) async throws -> AVVideoComposition {
        let targetHeadroom = self.targetHeadroom
        let sourceHeadroom = self.sourceHeadroomFallback
        let fallbackHighlightAmount = self.fallbackHighlightAmount

        let filterHandler: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            let sourceExtent = request.sourceImage.extent
            var image = request.sourceImage.cropped(to: sourceExtent)

            /*
             重要：
             - 只做 HDR tone mapping。
             - 不做 rotation。
             - 不做 affine transform。
             - 不改 saturation / contrast / brightness。
            */
            if let toneMapped = VideoFrameSource.applySystemLikeToneMapping(
                to: image,
                sourceHeadroom: sourceHeadroom,
                targetHeadroom: targetHeadroom
            ) {
                image = toneMapped
            } else {
                image = VideoFrameSource.applyHighlightFallbackToneMapping(
                    to: image,
                    highlightAmount: fallbackHighlightAmount
                )
            }

            image = image.cropped(to: sourceExtent)

            request.finish(
                with: image,
                context: nil
            )
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVVideoComposition, Error>) in

            AVVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: filterHandler
            ) { composition, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let composition else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "VideoFrameSource",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "AVVideoComposition creation returned nil"
                            ]
                        )
                    )
                    return
                }

                continuation.resume(returning: composition)
            }
        }
    }

    /*
     必須是 nonisolated：
     VideoFrameSource 是 @MainActor class，
     若 static func 沒標 nonisolated，Swift 會把它視為 MainActor-isolated。
     但 AVVideoComposition 的 filter handler 是 @Sendable nonisolated callback，
     不能同步呼叫 MainActor-isolated method。
    */
    private nonisolated static func applySystemLikeToneMapping(
        to image: CIImage,
        sourceHeadroom: Float,
        targetHeadroom: Float
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIToneMapHeadroom") else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)

        if filter.inputKeys.contains("inputSourceHeadroom") {
            filter.setValue(
                NSNumber(value: sourceHeadroom),
                forKey: "inputSourceHeadroom"
            )
        }

        if filter.inputKeys.contains("inputTargetHeadroom") {
            filter.setValue(
                NSNumber(value: targetHeadroom),
                forKey: "inputTargetHeadroom"
            )
        }

        return filter.outputImage
    }

    private nonisolated static func applyHighlightFallbackToneMapping(
        to image: CIImage,
        highlightAmount: Float
    ) -> CIImage {
        image.applyingFilter(
            "CIHighlightShadowAdjust",
            parameters: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": 0.0
            ]
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

            self.lastCopiedItemTime = .invalid

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

            self.videoOutput?.requestNotificationOfMediaDataChange(
                withAdvanceInterval: 0.03
            )

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

        lastCopiedItemTime = .invalid
        startDisplayLink()

        player.play()

        print("[VIDEO] play")
    }

    func pause() {
        player.pause()
        stopDisplayLink()

        print("[VIDEO] pause")
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

    // MARK: - DisplayLink / Frame Extraction

    private func startDisplayLink() {
        guard displayLink == nil else {
            return
        }

        let link = CADisplayLink(
            target: self,
            selector: #selector(displayLinkTick(_:))
        )

        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 15,
            maximum: 60,
            preferred: 30
        )

        link.add(to: .main, forMode: .common)
        displayLink = link

        print("[VIDEO_OUTPUT] displayLink started")
    }

    private func stopDisplayLink() {
        guard let displayLink else {
            return
        }

        displayLink.invalidate()
        self.displayLink = nil

        print("[VIDEO_OUTPUT] displayLink stopped")
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard let output = videoOutput,
              player.currentItem != nil else {
            return
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        guard itemTime.isValid,
              itemTime.seconds.isFinite else {
            return
        }

        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            return
        }

        if lastCopiedItemTime.isValid,
           CMTimeCompare(itemTime, lastCopiedItemTime) == 0 {
            return
        }

        var itemTimeForDisplay = CMTime.invalid

        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &itemTimeForDisplay
        ) else {
            return
        }

        lastCopiedItemTime = itemTime

        let presentationTime = itemTimeForDisplay.isValid
            ? itemTimeForDisplay
            : itemTime

        guard let sampleBuffer = Self.makeSampleBuffer(
            from: pixelBuffer,
            presentationTime: presentationTime
        ) else {
            return
        }

        videoOutputFrameCount += 1

        if videoOutputFrameCount % 30 == 0 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            print(
                "[VIDEO_OUTPUT_FRAME]",
                "count:", videoOutputFrameCount,
                "size:", "\(width)x\(height)",
                "time:", presentationTime.seconds
            )
        }

        onFrame?(sampleBuffer)
    }

    private static func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?

        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard descStatus == noErr,
              let formatDescription else {
            print(
                "[VIDEO_OUTPUT] CMVideoFormatDescriptionCreateForImageBuffer failed:",
                descStatus
            )
            return nil
        }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr,
              let sampleBuffer else {
            print(
                "[VIDEO_OUTPUT] CMSampleBufferCreateReadyWithImageBuffer failed:",
                sampleStatus
            )
            return nil
        }

        return sampleBuffer
    }

    // MARK: - Cleanup

    private func cancelLoadTasks() {
        loadTask?.cancel()
        loadTask = nil

        readyTask?.cancel()
        readyTask = nil
    }

    private func stopRuntimeOnly(removeCurrentItem: Bool) {
        stopDisplayLink()

        player.pause()
        player.cancelPendingPrerolls()

        removeEndObserver()
        removeVideoOutputFromCurrentItem()

        playerItem = nil
        videoOutput = nil
        lastCopiedItemTime = .invalid
        videoOutputFrameCount = 0

        if removeCurrentItem {
            player.replaceCurrentItem(with: nil)
        }
    }

    private func removeVideoOutputFromCurrentItem() {
        guard let item = playerItem,
              let output = videoOutput else {
            return
        }

        item.remove(output)
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

        stopDisplayLink()

        shouldAutoPlay = false

        removeEndObserver()

        onEnded?()
    }
}
