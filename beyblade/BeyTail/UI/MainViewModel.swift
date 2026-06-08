import SwiftUI
import Combine
import AVFoundation

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

    private struct ResourceClearPolicy {
        let clearLoadedVideo: Bool
        let clearRecordedPreview: Bool
        let clearTracking: Bool

        static let none = ResourceClearPolicy(
            clearLoadedVideo: false,
            clearRecordedPreview: false,
            clearTracking: false
        )

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

        trailOverlayView.debugBoundingBoxes = tracked.map {
            ($0.boundingBox, $0.trackId)
        }

        for detection in tracked {
            guard detection.trackId > 0 else {
                continue
            }

            trailEffectEngine.addPoint(
                trackId: detection.trackId,
                center: detection.center,
                color: detection.dominantColor
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

        appMode = .videoReady
        finishEvent()
    }

    private func handleVideoLoadFailed(message: String) {
        print("[VIDEO] load failed:", message)

        videoFrameSource.forceResetAfterFailedLoad()

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

        appMode = .videoEnded
    }

    private func handleVideoFrame(_ buffer: CMSampleBuffer) {
        guard appMode == .loadingVideo ||
              appMode == .videoReady else {
            return
        }

        inferenceEngine.processFrame(buffer)
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

        inferenceEngine.processFrame(buffer)
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
