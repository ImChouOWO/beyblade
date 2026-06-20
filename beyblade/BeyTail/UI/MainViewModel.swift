import SwiftUI
import Combine
import AVFoundation
import ImageIO
import UIKit

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
final class MainViewModel: ObservableObject {

    // MARK: - Published State

    @Published var selectedEffect: EffectType = .lightning {
        didSet {
            trailEffectEngine.fadeDurationMs = selectedEffect.fadeDurationMs
            trailOverlayView.currentEffect = selectedEffect
        }
    }

    @Published var effectMenuVisible = false

    @Published private(set) var isRecording = false
    @Published private(set) var fps: Int = 0
    @Published private(set) var hardwareLabel = "MOCK"
    @Published private(set) var hardwareColor = Color(white: 0.6)
    @Published private(set) var cameraVideoRotationAngle: CGFloat = 0

    @Published var hintVisible = true
    @Published var pulseScale: CGFloat = 1.0

    @Published private(set) var isUsingVideoFile = false
    @Published private(set) var isVideoLoading = false
    @Published private(set) var isSwitchingInputSource = false

    @Published private(set) var canOpenVideoLibrary = true
    @Published private(set) var canToggleRecording = true
    @Published private(set) var canReturnToCamera = false

    @Published private(set) var loadingText = ""

    // MARK: - Components

    let cameraManager = CameraManager()
    let inferenceEngine = InferenceEngine()
    let tracker = BeybladeTracker()
    let trailEffectEngine = TrailEffectEngine()
    let trailOverlayView = TrailOverlayView()
    let videoFrameSource = VideoFrameSource()
    let recordingManager = RecordingManager()

    // MARK: - Internal State

    private enum UIEvent: Equatable {
        case openVideoLibrary
        case loadPickedVideo
        case startRecording
        case stopRecording
        case returnToCamera
    }

    private enum AppMode: Equatable {
        case cameraPreview
        case preparingVideoLibrary
        case videoPickerPresented
        case loadingVideo
        case videoReady
        case videoEnded
        case preparingRecording
        case recording
        case stoppingRecording
        case recovering
        case stopped
    }

    private enum FrameInputSource: Equatable {
        case camera
        case video
    }

    private struct ResourceClearPolicy {
        let clearLoadedVideo: Bool
        let clearRecordedPreview: Bool
        let clearTracking: Bool

        static let beforeOpenVideoLibrary = ResourceClearPolicy(
            clearLoadedVideo: true,
            clearRecordedPreview: true,
            clearTracking: true
        )

        static let beforeStartRecording = ResourceClearPolicy(
            clearLoadedVideo: true,
            clearRecordedPreview: true,
            clearTracking: true
        )

        static let returnToCamera = ResourceClearPolicy(
            clearLoadedVideo: true,
            clearRecordedPreview: true,
            clearTracking: true
        )
    }

    private var appMode: AppMode = .cameraPreview {
        didSet {
            print("[STATE] appMode:", oldValue, "->", appMode)
            syncPublishedState()
        }
    }

    private var modeBeforePicker: AppMode = .cameraPreview

    private var activeEvent: UIEvent? {
        didSet {
            syncPublishedState()
        }
    }

    private var lastEventFinishedAt = Date.distantPast
    private let minEventInterval: TimeInterval = 0.45

    private var hintTask: Task<Void, Never>?

    private var isStartingCameraPreview = false
    private var hasRequestedInitialCameraPreview = false

    private var latestSourceFrameSize = CGSize(width: 1, height: 1)
    private var latestOverlaySize = CGSize(width: 1, height: 1)
    private var previewVideoGravity: AVLayerVideoGravity = .resizeAspectFill

    private var activeFrameInputSource: FrameInputSource = .camera
    private var activeVisionOrientation: CGImagePropertyOrientation = .up

    /*
     bbox 修正分離：
     - 相機 / 錄影模式維持原本 180 度修正。
     - 影片模式不在 MainViewModel 做 bbox 旋轉。
     - HDR videoComposition 會影響影片 frame 顯示管線，所以影片模式不要再額外轉 90 度。
    */
    private enum BBoxRotation {
        case none
        case clockwise90
        case counterClockwise90
        case rotate180
    }

    private let rotateCameraBBox180 = false
    private let videoBBoxRotation: BBoxRotation = .none

    private var videoFrameCount = 0

    private let enableBBoxDisplayMapping = true

    /*
     建議先不要在映射後強制 clamp。
     因為 resizeAspectFill 會裁切畫面，bbox 超出 overlay 邊界是正常現象。
     若直接 clamp，會讓 bbox 偏移問題更難 debug。
     確認座標正確後，如果你想避免畫出畫面外，可以改成 true。
     */
    private let clampMappedBBoxToVisibleArea = false

    // MARK: - Init

    init() {
        trailOverlayView.effectEngine = trailEffectEngine
        trailEffectEngine.fadeDurationMs = selectedEffect.fadeDurationMs
        trailOverlayView.currentEffect = selectedEffect

        inferenceEngine.onResult = { [weak self] detections in
            Task { @MainActor [weak self, detections] in
                guard let self else {
                    return
                }

                let tracked = self.tracker.update(detections)
                self.applyTrackedResults(tracked)
            }
        }

        videoFrameSource.onEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.handleVideoEnded()
            }
        }

        recordingManager.onStarted = { [weak self] success in
            Task { @MainActor [weak self, success] in
                guard let self else {
                    return
                }

                self.handleRecordingStarted(success: success)
            }
        }

        recordingManager.onStopped = { [weak self] url in
            Task { @MainActor [weak self, url] in
                guard let self else {
                    return
                }

                self.handleRecordingStopped(url: url)
            }
        }

        syncPublishedState()
    }

    // MARK: - Layout Sync

    func updatePreviewLayout(
        overlaySize: CGSize,
        videoGravity: AVLayerVideoGravity
    ) {
        guard overlaySize.width > 1,
              overlaySize.height > 1 else {
            return
        }

        latestOverlaySize = overlaySize
        previewVideoGravity = videoGravity
        cameraVideoRotationAngle = cameraManager.currentVideoRotationAngle

        print(
            "[LAYOUT]",
            "overlaySize:", overlaySize,
            "trailBounds:", trailOverlayView.bounds.size,
            "videoGravity:", videoGravity.rawValue,
            "cameraVideoRotationAngle:", cameraVideoRotationAngle
        )

        trailOverlayView.setNeedsDisplay()
    }

    // MARK: - Published State Sync

    private func syncPublishedState() {
        switch appMode {
        case .cameraPreview:
            isRecording = false
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = isStartingCameraPreview
            canOpenVideoLibrary = !isStartingCameraPreview
            canToggleRecording = !isStartingCameraPreview
            canReturnToCamera = false

        case .preparingVideoLibrary:
            isRecording = false
            isUsingVideoFile = shouldShowPreviousVideoWhilePickerActive()
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .videoPickerPresented:
            isRecording = false
            isUsingVideoFile = shouldShowPreviousVideoWhilePickerActive()
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .loadingVideo:
            isRecording = false
            isUsingVideoFile = true
            isVideoLoading = true
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .videoReady:
            isRecording = false
            isUsingVideoFile = true
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = true
            canToggleRecording = true
            canReturnToCamera = true

        case .videoEnded:
            isRecording = false
            isUsingVideoFile = true
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = true
            canToggleRecording = true
            canReturnToCamera = true

        case .preparingRecording:
            isRecording = false
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .recording:
            isRecording = true
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = true
            canReturnToCamera = false

        case .stoppingRecording:
            isRecording = false
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .recovering:
            isRecording = false
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .stopped:
            isRecording = false
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false
        }

        if activeEvent != nil {
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

            if appMode != .videoPickerPresented {
                isSwitchingInputSource = true
            }
        }
    }

    private func shouldShowPreviousVideoWhilePickerActive() -> Bool {
        switch modeBeforePicker {
        case .videoReady, .videoEnded:
            return videoFrameSource.hasActiveItem

        default:
            return false
        }
    }

    // MARK: - Lifecycle

    func start() {
        if appMode == .stopped {
            appMode = .cameraPreview
        }

        guard !hasRequestedInitialCameraPreview else {
            return
        }

        hasRequestedInitialCameraPreview = true

        inferenceEngine.start()

        startPulse()
        startHintAutoHide()

        startCameraPreview()
    }

    func stop() {
        activeEvent = nil
        loadingText = ""

        hasRequestedInitialCameraPreview = false
        isStartingCameraPreview = false

        hintTask?.cancel()
        hintTask = nil

        cameraManager.onFrame = nil
        cameraManager.stop()

        inferenceEngine.stop()

        tracker.reset()
        trailEffectEngine.clear()
        trailOverlayView.debugBoundingBoxes = []

        videoFrameSource.onFrame = nil
        videoFrameSource.stop()

        if recordingManager.isRecording {
            recordingManager.stopRecording()
        }

        recordingManager.forceReset()

        activeFrameInputSource = .camera
        activeVisionOrientation = .up
        videoFrameCount = 0
        latestSourceFrameSize = CGSize(width: 1, height: 1)

        appMode = .stopped
    }

    // MARK: - Inference Result

    private func applyTrackedResults(_ tracked: [DetectionResult]) {
        guard !tracked.isEmpty else {
            fps = Int(inferenceEngine.currentFps)
            trailOverlayView.debugBoundingBoxes = []
            return
        }

        if let first = tracked.first {
            fps = Int(first.fps)
            hardwareLabel = first.hardware.label
            hardwareColor = colorForHardware(first.hardware)
        }

        let mappedResults = tracked.map {
            mapDetectionToOverlaySpace($0)
        }

        trailOverlayView.debugBoundingBoxes = mappedResults.map {
            ($0.displayRect, $0.trackId)
        }

        logDetectedObjects(
            rawDetections: tracked,
            mappedDetections: mappedResults
        )

        for result in mappedResults {
            guard result.trackId > 0 else {
                continue
            }

            trailEffectEngine.addPoint(
                trackId: result.trackId,
                center: result.displayCenter,
                color: result.color
            )
        }
    }

    private func logDetectedObjects(
        rawDetections: [DetectionResult],
        mappedDetections: [DisplayDetection]
    ) {
        let canvasSize = currentCanvasSize()

        print(
            "[DETECTION]",
            "count:", rawDetections.count,
            "fps:", fps,
            "hardware:", hardwareLabel,
            "sourceSize:", latestSourceFrameSize,
            "mappingSourceSize:", currentMappingSourceSize(),
            "canvasSize:", canvasSize,
            "overlaySize:", latestOverlaySize,
            "trailBounds:", trailOverlayView.bounds.size,
            "videoGravity:", previewVideoGravity.rawValue,
            "cameraVideoRotationAngle:", cameraVideoRotationAngle,
            "inputSource:", activeFrameInputSource,
            "visionOrientation:", activeVisionOrientation.rawValue
        )

        for index in rawDetections.indices {
            let raw = rawDetections[index]
            let mapped = mappedDetections[index]

            print(
                "[DETECTION_ITEM]",
                "index:", index,
                "trackId:", raw.trackId,
                "confidence:", raw.confidence,
                "rawBBox:", raw.boundingBox,
                "mappedBBox:", mapped.displayRect,
                "mappedCenter:", mapped.displayCenter
            )
        }
    }

    private func colorForHardware(_ hardware: BeyTailInferenceHardware) -> Color {
        switch hardware {
        case .cpu:
            return .orange

        case .gpu:
            return .blue

        case .npu:
            return .green

        case .mock:
            return Color(white: 0.6)
        }
    }

    // MARK: - BBox Mapping

    private struct DisplayDetection {
        let displayRect: CGRect
        let displayCenter: CGPoint
        let trackId: Int
        let color: UIColor
    }

    private func mapDetectionToOverlaySpace(
        _ detection: DetectionResult
    ) -> DisplayDetection {
        let inputRect = clampNormalizedRect(
            detection.boundingBox
        )

        let correctedRect: CGRect

        switch activeFrameInputSource {
        case .camera:
            correctedRect = rotateCameraBBox180
                ? rotateBBox(inputRect, rotation: .rotate180)
                : inputRect

        case .video:
            /*
             影片模式不在 MainViewModel 做 bbox 旋轉。
             HDR videoComposition 已經讓影片 frame 走過系統顯示管線。
             若這裡再旋轉，就會多轉 90 度。
            */
            correctedRect = inputRect
        }

        let mappedRect = mapNormalizedRectToCanvas(
            correctedRect
        )

        return DisplayDetection(
            displayRect: mappedRect,
            displayCenter: CGPoint(
                x: mappedRect.midX,
                y: mappedRect.midY
            ),
            trackId: detection.trackId,
            color: detection.dominantColor
        )
    }

    private func rotateBBox(
        _ rect: CGRect,
        rotation: BBoxRotation
    ) -> CGRect {
        let input = clampNormalizedRect(rect)

        let rotated: CGRect

        switch rotation {
        case .none:
            rotated = input

        case .clockwise90:
            rotated = CGRect(
                x: 1.0 - input.maxY,
                y: input.minX,
                width: input.height,
                height: input.width
            )

        case .counterClockwise90:
            rotated = CGRect(
                x: input.minY,
                y: 1.0 - input.maxX,
                width: input.height,
                height: input.width
            )

        case .rotate180:
            rotated = CGRect(
                x: 1.0 - input.maxX,
                y: 1.0 - input.maxY,
                width: input.width,
                height: input.height
            )
        }

        return clampNormalizedRect(rotated)
    }

    private func mapNormalizedRectToCanvas(
        _ normalizedRect: CGRect
    ) -> CGRect {
        let inputRect = clampNormalizedRect(normalizedRect)

        guard enableBBoxDisplayMapping else {
            return inputRect
        }

        let canvasSize = currentCanvasSize()

        guard canvasSize.width > 1,
              canvasSize.height > 1,
              latestSourceFrameSize.width > 1,
              latestSourceFrameSize.height > 1 else {
            return inputRect
        }

        let sourceSize = currentMappingSourceSize()

        let useAspectFill: Bool

        switch previewVideoGravity {
        case .resizeAspect:
            useAspectFill = false

        case .resizeAspectFill:
            useAspectFill = true

        case .resize:
            return inputRect

        default:
            useAspectFill = true
        }

        let widthScale = canvasSize.width / sourceSize.width
        let heightScale = canvasSize.height / sourceSize.height

        let scale = useAspectFill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)

        let displayedVideoWidth = sourceSize.width * scale
        let displayedVideoHeight = sourceSize.height * scale

        let offsetX = (canvasSize.width - displayedVideoWidth) / 2.0
        let offsetY = (canvasSize.height - displayedVideoHeight) / 2.0

        let sourceRect = CGRect(
            x: inputRect.minX * sourceSize.width,
            y: inputRect.minY * sourceSize.height,
            width: inputRect.width * sourceSize.width,
            height: inputRect.height * sourceSize.height
        )

        let canvasRect = CGRect(
            x: sourceRect.minX * scale + offsetX,
            y: sourceRect.minY * scale + offsetY,
            width: sourceRect.width * scale,
            height: sourceRect.height * scale
        )

        let normalizedCanvasRect = CGRect(
            x: canvasRect.minX / canvasSize.width,
            y: canvasRect.minY / canvasSize.height,
            width: canvasRect.width / canvasSize.width,
            height: canvasRect.height / canvasSize.height
        )

        guard isValidRect(normalizedCanvasRect) else {
            return inputRect
        }

        if clampMappedBBoxToVisibleArea {
            return clampNormalizedRect(normalizedCanvasRect)
        }

        return normalizedCanvasRect
    }

    private func currentCanvasSize() -> CGSize {
        let boundsSize = trailOverlayView.bounds.size

        if boundsSize.width > 1,
           boundsSize.height > 1 {
            return boundsSize
        }

        return latestOverlaySize
    }

    private func currentMappingSourceSize() -> CGSize {
        let sourceSize = latestSourceFrameSize

        guard sourceSize.width > 1,
              sourceSize.height > 1 else {
            return sourceSize
        }

        switch activeFrameInputSource {
        case .camera:
            return sourceSize

        case .video:
            /*
             影片模式不交換寬高。
             避免 bbox 在 HDR videoComposition 後又被額外當成旋轉後座標處理。
            */
            return sourceSize
        }
    }

    private func updateLatestSourceFrameSize(
        from buffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return
        }

        let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
        let rawHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard rawWidth > 0,
              rawHeight > 0 else {
            return
        }

        let rawSize = CGSize(
            width: CGFloat(rawWidth),
            height: CGFloat(rawHeight)
        )

        latestSourceFrameSize = orientedSourceSize(
            rawSize: rawSize,
            orientation: orientation
        )
    }

    private func orientedSourceSize(
        rawSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(
                width: rawSize.height,
                height: rawSize.width
            )

        default:
            return rawSize
        }
    }

    private func clampNormalizedRect(
        _ rect: CGRect
    ) -> CGRect {
        let minX = clamp(
            rect.minX,
            lower: 0.0,
            upper: 1.0
        )

        let minY = clamp(
            rect.minY,
            lower: 0.0,
            upper: 1.0
        )

        let maxX = clamp(
            rect.maxX,
            lower: 0.0,
            upper: 1.0
        )

        let maxY = clamp(
            rect.maxY,
            lower: 0.0,
            upper: 1.0
        )

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0, maxX - minX),
            height: max(0.0, maxY - minY)
        )
    }

    private func clamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func isValidRect(
        _ rect: CGRect
    ) -> Bool {
        rect.minX.isFinite &&
        rect.minY.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width >= 0.0 &&
        rect.height >= 0.0
    }

    // MARK: - Video Picker Event

    func prepareForVideoPickerAsync() async -> Bool {
        switch appMode {
        case .cameraPreview, .videoReady, .videoEnded:
            break

        default:
            print("[EVENT] open video library ignored, state:", appMode)
            return false
        }

        guard beginEvent(
            .openVideoLibrary,
            loadingText: "準備開啟影片庫..."
        ) else {
            return false
        }

        modeBeforePicker = appMode

        await waitForEventInterval()

        appMode = .preparingVideoLibrary

        switch modeBeforePicker {
        case .cameraPreview:
            await stopCameraForExternalPicker()

        case .videoReady, .videoEnded:
            videoFrameSource.pause()

        default:
            break
        }

        hintVisible = false
        appMode = .videoPickerPresented

        finishEvent()
        return true
    }

    func beginResolvingPickedVideo() {
        if appMode == .preparingVideoLibrary {
            appMode = .videoPickerPresented
        }
    }

    func cancelVideoPickerAndRecover() {
        guard appMode == .preparingVideoLibrary ||
              appMode == .videoPickerPresented else {
            syncPublishedState()
            return
        }

        restoreAfterPickerDismiss()
    }

    private func restoreAfterPickerDismiss() {
        guard beginEvent(
            .returnToCamera,
            loadingText: "恢復畫面中..."
        ) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.waitForEventInterval()

            switch self.modeBeforePicker {
            case .videoReady, .videoEnded:
                if self.videoFrameSource.hasActiveItem {
                    self.appMode = self.modeBeforePicker
                } else {
                    self.appMode = .recovering
                    await self.startCameraPreviewAsync()
                    self.appMode = .cameraPreview
                }

            default:
                self.appMode = .recovering
                await self.startCameraPreviewAsync()
                self.appMode = .cameraPreview
            }

            self.finishEvent()
        }
    }

    func videoPickerDismissedWithoutSelection() {
        cancelVideoPickerAndRecover()
    }

    func videoSelectionFailed() {
        recoverToCameraPreview(reason: "video selection failed")
    }

    func loadVideo(url: URL) {
        guard appMode == .videoPickerPresented else {
            print("[EVENT] load picked video ignored, state:", appMode)
            return
        }

        guard beginEvent(
            .loadPickedVideo,
            loadingText: "載入影片中..."
        ) else {
            return
        }

        Task { @MainActor [weak self, url] in
            guard let self else {
                return
            }

            await self.waitForEventInterval()

            self.appMode = .loadingVideo

            self.activeFrameInputSource = .video
            self.activeVisionOrientation = .up
            self.cameraVideoRotationAngle = 0
            self.videoFrameCount = 0

            await self.clearImageResources(
                policy: .beforeOpenVideoLibrary
            )

            self.videoFrameSource.onFrame = { [weak self] buffer in
                let boxedBuffer = UncheckedSendableBox(value: buffer)

                Task { @MainActor [weak self, boxedBuffer] in
                    guard let self else {
                        return
                    }

                    self.handleVideoFrame(boxedBuffer.value)
                }
            }

            self.videoFrameSource.load(
                url: url,
                autoPlay: true,
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }

                        self.handleVideoReady()
                    }
                },
                onFailed: { [weak self] message in
                    Task { @MainActor [weak self, message] in
                        guard let self else {
                            return
                        }

                        self.handleVideoLoadFailed(message: message)
                    }
                }
            )
        }
    }

    private func handleVideoReady() {
        guard appMode == .loadingVideo else {
            print("[VIDEO] ready ignored, state:", appMode)
            finishEvent()
            return
        }

        activeFrameInputSource = .video
        activeVisionOrientation = .up

        appMode = .videoReady
        finishEvent()
    }

    private func handleVideoLoadFailed(message: String) {
        print("[VIDEO] load failed:", message)

        videoFrameSource.forceResetAfterFailedLoad()

        activeFrameInputSource = .camera
        activeVisionOrientation = .up
        videoFrameCount = 0

        appMode = .recovering

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.startCameraPreviewAsync()

            self.appMode = .cameraPreview
            self.finishEvent()
        }
    }

    private func handleVideoEnded() {
        guard appMode == .videoReady ||
              appMode == .loadingVideo ||
              appMode == .videoEnded else {
            print("[VIDEO] ended ignored, state:", appMode)
            syncPublishedState()
            return
        }

        activeFrameInputSource = .video
        activeVisionOrientation = .up

        appMode = .videoEnded
    }

    private func handleVideoFrame(_ buffer: CMSampleBuffer) {
        guard appMode == .loadingVideo ||
              appMode == .videoReady else {
            return
        }

        let orientation: CGImagePropertyOrientation = .up

        activeFrameInputSource = .video
        activeVisionOrientation = orientation
        cameraVideoRotationAngle = 0

        updateLatestSourceFrameSize(
            from: buffer,
            orientation: orientation
        )

        videoFrameCount += 1

        if videoFrameCount % 30 == 0 {
            print(
                "[VIDEO_FRAME]",
                "count:", videoFrameCount,
                "sourceSize:", latestSourceFrameSize,
                "orientation:", orientation.rawValue,
                "appMode:", appMode
            )
        }

        inferenceEngine.processFrame(
            buffer,
            orientation: orientation
        )
    }

    // MARK: - Recording Event

    func toggleRecording() {
        switch appMode {
        case .cameraPreview, .videoReady, .videoEnded:
            startRecordingEvent()

        case .recording:
            stopRecordingEvent()

        default:
            print("[EVENT] recording ignored, state:", appMode)
        }
    }

    private func startRecordingEvent() {
        guard beginEvent(
            .startRecording,
            loadingText: "準備錄影..."
        ) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.waitForEventInterval()

            self.appMode = .preparingRecording

            await self.clearImageResources(
                policy: .beforeStartRecording
            )

            self.activeFrameInputSource = .camera
            self.activeVisionOrientation = .up
            self.videoFrameCount = 0

            await self.startCameraPreviewAsync()

            guard self.appMode == .preparingRecording else {
                self.finishEvent()
                return
            }

            print("[RECORD] call startRecording")
            self.recordingManager.startRecording()
        }
    }

    private func handleRecordingStarted(success: Bool) {
        guard appMode == .preparingRecording else {
            print("[RECORD] onStarted ignored, state:", appMode)
            return
        }

        guard activeEvent == .startRecording else {
            print(
                "[RECORD] onStarted ignored, activeEvent:",
                String(describing: activeEvent)
            )
            return
        }

        guard success else {
            print("[RECORD] start failed")

            recordingManager.forceReset()
            appMode = .cameraPreview
            finishEvent()
            return
        }

        print("[RECORD] recording started")

        appMode = .recording
        finishEvent()
    }

    private func stopRecordingEvent() {
        guard appMode == .recording ||
              recordingManager.isRecording else {
            appMode = .cameraPreview
            syncPublishedState()
            return
        }

        guard beginEvent(
            .stopRecording,
            loadingText: "停止錄影中..."
        ) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            self.appMode = .stoppingRecording

            await self.waitForEventInterval()

            print("[RECORD] call stopRecording")
            self.recordingManager.stopRecording()
        }
    }

    private func handleRecordingStopped(url: URL?) {
        if appMode == .stopped {
            return
        }

        print("[RECORD] stopped:", url?.path ?? "nil")

        recordingManager.forceReset()

        if appMode == .recording ||
           appMode == .preparingRecording ||
           appMode == .stoppingRecording {
            appMode = .cameraPreview
        }

        activeFrameInputSource = .camera
        activeVisionOrientation = .up
        videoFrameCount = 0

        finishEvent()

        guard let url else {
            return
        }

        recordingManager.saveToPhotoLibrary(url: url) { success in
            print("[RECORD] saveToPhotoLibrary:", success)
        }
    }

    // MARK: - Effect Event

    func onEffectMenuButtonTapped() {
        guard activeEvent == nil else {
            return
        }

        effectMenuVisible.toggle()
    }

    func onEffectSelected(_ effect: EffectType) {
        guard activeEvent == nil else {
            return
        }

        guard !effect.isLocked else {
            return
        }

        selectedEffect = effect
        effectMenuVisible = false
    }

    // MARK: - Return To Camera

    func useLiveCameraInput() {
        guard appMode == .videoReady ||
              appMode == .videoEnded else {
            return
        }

        recoverToCameraPreview(reason: "return to camera")
    }

    func backToCamera() {
        recoverToCameraPreview(reason: "back to camera")
    }

    private func recoverToCameraPreview(reason: String) {
        guard beginEvent(
            .returnToCamera,
            loadingText: "恢復攝影機畫面..."
        ) else {
            return
        }

        Task { @MainActor [weak self, reason] in
            guard let self else {
                return
            }

            print("[EVENT] recover:", reason)

            self.appMode = .recovering

            await self.waitForEventInterval()

            if self.recordingManager.isRecording {
                self.recordingManager.stopRecording()
            }

            self.recordingManager.forceReset()

            await self.clearImageResources(
                policy: .returnToCamera
            )

            self.activeFrameInputSource = .camera
            self.activeVisionOrientation = .up
            self.videoFrameCount = 0

            await self.startCameraPreviewAsync()

            self.appMode = .cameraPreview
            self.finishEvent()
        }
    }

    // MARK: - Event Gate

    private func beginEvent(
        _ event: UIEvent,
        loadingText: String
    ) -> Bool {
        guard activeEvent == nil else {
            print(
                "[EVENT] ignored:",
                event,
                "active:",
                String(describing: activeEvent)
            )
            return false
        }

        activeEvent = event
        self.loadingText = loadingText
        return true
    }

    private func finishEvent() {
        activeEvent = nil
        loadingText = ""
        lastEventFinishedAt = Date()
        syncPublishedState()
    }

    private func waitForEventInterval() async {
        let elapsed = Date().timeIntervalSince(lastEventFinishedAt)

        guard elapsed < minEventInterval else {
            return
        }

        let delay = minEventInterval - elapsed
        let nanoseconds = UInt64(delay * 1_000_000_000)

        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func sleepMilliseconds(_ milliseconds: UInt64) async {
        try? await Task.sleep(
            nanoseconds: milliseconds * 1_000_000
        )
    }

    // MARK: - Resource Cleanup

    private func clearImageResources(
        policy: ResourceClearPolicy
    ) async {
        if policy.clearLoadedVideo {
            videoFrameSource.onFrame = nil
            videoFrameSource.stop()
        }

        if policy.clearRecordedPreview {
            if recordingManager.isRecording {
                recordingManager.stopRecording()
            }

            recordingManager.forceReset()
        }

        if policy.clearTracking {
            tracker.reset()
            trailEffectEngine.clear()
            trailOverlayView.debugBoundingBoxes = []
        }

        effectMenuVisible = false

        await Task.yield()
    }

    // MARK: - Camera Preview

    private func startCameraPreview() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.startCameraPreviewAsync()
        }
    }

    private func startCameraPreviewAsync() async {
        guard !isStartingCameraPreview else {
            print("[CAMERA] preview start ignored: already starting")
            return
        }

        guard appMode != .recording &&
              appMode != .stoppingRecording else {
            print(
                "[CAMERA] preview start ignored during recording state:",
                appMode
            )
            return
        }

        activeFrameInputSource = .camera
        activeVisionOrientation = .up
        videoFrameCount = 0

        isStartingCameraPreview = true
        syncPublishedState()

        cameraManager.onFrame = { [weak self] buffer in
            let boxedBuffer = UncheckedSendableBox(value: buffer)

            Task { @MainActor [weak self, boxedBuffer] in
                guard let self else {
                    return
                }

                self.handleCameraFrame(boxedBuffer.value)
            }
        }

        let started = await cameraManager.requestPermissionAndStartAsync()

        if !started {
            print("[CAMERA] preview start failed")
        }

        isStartingCameraPreview = false
        syncPublishedState()
    }

    private func handleCameraFrame(_ buffer: CMSampleBuffer) {
        guard appMode == .cameraPreview ||
              appMode == .recording ||
              appMode == .preparingRecording else {
            return
        }

        let orientation = cameraManager.currentVisionImageOrientation

        activeFrameInputSource = .camera
        activeVisionOrientation = orientation
        cameraVideoRotationAngle = cameraManager.currentVideoRotationAngle

        updateLatestSourceFrameSize(
            from: buffer,
            orientation: orientation
        )

        inferenceEngine.processFrame(
            buffer,
            orientation: orientation
        )
    }

    private func stopCameraForExternalPicker() async {
        cameraManager.onFrame = nil
        videoFrameSource.stop()

        await cameraManager.stopForPickerAsync()

        await Task.yield()
        await sleepMilliseconds(180)
    }

    // MARK: - UI Helpers

    private func startHintAutoHide() {
        hintTask?.cancel()

        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: 3_500_000_000
            )

            guard let self else {
                return
            }

            withAnimation(.easeOut(duration: 0.8)) {
                self.hintVisible = false
            }
        }
    }

    private func startPulse() {
        pulseScale = 1.0

        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: 100_000_000
            )

            guard let self else {
                return
            }

            self.pulseScale = 1.18
        }
    }
}
