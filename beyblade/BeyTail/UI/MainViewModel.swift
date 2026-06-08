import SwiftUI
import Combine
import AVFoundation
import UIKit

final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
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
    @Published var isRecording = false
    @Published var fps: Int = 0
    @Published var hardwareLabel = "MOCK"
    @Published var hardwareColor = Color(white: 0.6)
    @Published var hintVisible = true
    @Published var pulseScale: CGFloat = 1.0

    @Published var isUsingVideoFile = false
    @Published var isVideoLoading = false
    @Published var isSwitchingInputSource = false

    @Published var canOpenVideoLibrary = true
    @Published var canToggleRecording = true
    @Published var canReturnToCamera = false

    // MARK: - Components

    let cameraManager     = CameraManager()
    let inferenceEngine   = InferenceEngine()
    let trailEffectEngine = TrailEffectEngine()
    let tracker           = BeybladeTracker()
    let recordingManager  = RecordingManager()
    let trailOverlayView  = TrailOverlayView()
    let videoFrameSource  = VideoFrameSource()

    // MARK: - Mode State

    private enum ModeState: Equatable {
        case cameraIdle
        case preparingRecording
        case recording
        case stoppingRecording
        case preparingVideoPicker
        case videoPickerPresented
        case loadingVideo
        case videoReady
        case videoEnded
        case switchingToCamera
        case stopped
    }

    private var modeState: ModeState = .cameraIdle {
        didSet {
            print("[STATE] modeState:", oldValue, "->", modeState)

            syncPublishedState()

            print(
                "[STATE] isVideoLoading:",
                isVideoLoading,
                "isSwitchingInputSource:",
                isSwitchingInputSource,
                "canOpenVideoLibrary:",
                canOpenVideoLibrary,
                "canToggleRecording:",
                canToggleRecording,
                "canReturnToCamera:",
                canReturnToCamera,
                "isRecording:",
                isRecording
            )
        }
    }

    // MARK: - Runtime State

    private var hintTask: Task<Void, Never>?
    private var videoLoadingTimeoutTask: Task<Void, Never>?
    private var recordingStartTimeoutTask: Task<Void, Never>?
    private var recordingStopTimeoutTask: Task<Void, Never>?

    private var operationID = UUID()
    private var isMediaOperationRunning = false
    private var lastRecordingToggleAt: CFTimeInterval = 0

    // MARK: - Init

    init() {
        trailOverlayView.effectEngine = trailEffectEngine
        trailEffectEngine.fadeDurationMs = selectedEffect.fadeDurationMs
        trailOverlayView.currentEffect = selectedEffect

        inferenceEngine.onResult = { [weak self] detections in
            guard let self else { return }

            let tracked = self.tracker.update(detections)
            self.applyTrackedResults(tracked)
        }

        videoFrameSource.onFrame = nil

        videoFrameSource.onEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleVideoEnded()
            }
        }

        recordingManager.onStarted = { [weak self] success in
            Task { @MainActor [weak self, success] in
                guard let self else { return }
                self.handleRecordingStarted(success: success)
            }
        }

        recordingManager.onStopped = { [weak self] url in
            Task { @MainActor [weak self, url] in
                guard let self else { return }
                self.handleRecordingStopped(url: url)
            }
        }

        syncPublishedState()
    }

    // MARK: - Published State Sync

    private func syncPublishedState() {
        switch modeState {
        case .cameraIdle:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = true
            canToggleRecording = true
            canReturnToCamera = false

        case .preparingRecording:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .recording:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = true
            canReturnToCamera = false

        case .stoppingRecording:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .preparingVideoPicker:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .videoPickerPresented:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .loadingVideo:
            isUsingVideoFile = true
            isVideoLoading = true
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .videoReady:
            isUsingVideoFile = true
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = true
            canToggleRecording = true
            canReturnToCamera = true

        case .videoEnded:
            isUsingVideoFile = true
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = true
            canToggleRecording = true
            canReturnToCamera = true

        case .switchingToCamera:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = true
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false

        case .stopped:
            isUsingVideoFile = false
            isVideoLoading = false
            isSwitchingInputSource = false
            canOpenVideoLibrary = false
            canToggleRecording = false
            canReturnToCamera = false
        }
    }

    // MARK: - Lifecycle

    func start() {
        if modeState == .stopped {
            modeState = .cameraIdle
        }

        inferenceEngine.start()
        startPulse()
        startHintAutoHide()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startInitialCamera()
        }
    }

    func stop() {
        invalidateCurrentOperation()
        isMediaOperationRunning = false

        cancelVideoLoadingTimeout()
        cancelRecordingStartTimeout()
        cancelRecordingStopTimeout()

        if isRecording || recordingManager.isRecording {
            recordingManager.stopRecording()
        }

        cameraManager.onFrame = nil
        cameraManager.stop()
        videoFrameSource.stop()
        inferenceEngine.stop()

        isRecording = false
        hintTask?.cancel()
        hintTask = nil

        modeState = .stopped
    }

    private func startInitialCamera() async {
        guard beginMediaOperation(name: "startInitialCamera") != nil else {
            return
        }

        modeState = .switchingToCamera

        let started = await configureCameraInputAsync(releaseVideoBeforeStart: true)

        if started {
            modeState = .cameraIdle
        } else {
            print("[CAMERA] initial camera start failed")
            modeState = .cameraIdle
        }

        endMediaOperation()
    }

    // MARK: - Media Operation Gate

    @discardableResult
    private func beginMediaOperation(name: String) -> UUID? {
        if isMediaOperationRunning {
            print("[MEDIA] operation ignored:", name, "current state:", modeState)
            return nil
        }

        isMediaOperationRunning = true
        let id = makeNewOperationID()
        print("[MEDIA] begin:", name, id)
        return id
    }

    private func endMediaOperation() {
        print("[MEDIA] end:", operationID)
        isMediaOperationRunning = false
    }

    private func forceEndMediaOperation() {
        print("[MEDIA] force end")
        isMediaOperationRunning = false
    }

    // MARK: - Camera

    private func configureCameraInputAsync(releaseVideoBeforeStart: Bool) async -> Bool {
        if releaseVideoBeforeStart {
            videoFrameSource.stop()
        }

        cameraManager.onFrame = { [weak self] buffer in
            guard let self else { return }

            guard self.modeState == .cameraIdle || self.modeState == .recording else {
                return
            }

            self.inferenceEngine.processFrame(buffer)
        }

        let started = await cameraManager.requestPermissionAndStartAsync()

        if !started {
            print("[CAMERA] requestPermissionAndStartAsync failed")
            return false
        }

        return true
    }

    private func stopCameraAndVideoAsync() async {
        cameraManager.onFrame = nil
        videoFrameSource.stop()

        await cameraManager.stopForPickerAsync()

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(180))
    }

    // MARK: - Video Picker

    func prepareForVideoPickerAsync() async -> Bool {
        switch modeState {
        case .cameraIdle, .videoReady, .videoEnded:
            break

        default:
            print("[PICKER] prepare ignored, state:", modeState)
            return false
        }

        guard beginMediaOperation(name: "prepareForVideoPicker") != nil else {
            return false
        }

        modeState = .preparingVideoPicker

        cancelVideoLoadingTimeout()
        cancelRecordingStartTimeout()
        cancelRecordingStopTimeout()

        await stopCameraAndVideoAsync()

        modeState = .videoPickerPresented
        hintVisible = false

        endMediaOperation()
        return true
    }

    func beginResolvingPickedVideo() {
        if modeState == .preparingVideoPicker {
            modeState = .videoPickerPresented
        }
    }

    func cancelVideoPickerAndRecover() {
        switch modeState {
        case .preparingVideoPicker, .videoPickerPresented:
            break

        default:
            print("[PICKER] cancel ignored, current state:", modeState)
            syncPublishedState()
            return
        }

        guard beginMediaOperation(name: "cancelVideoPickerAndRecover") != nil else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            print("[PICKER] cancel and recover to camera")

            self.cancelVideoLoadingTimeout()
            self.videoFrameSource.stop()

            self.modeState = .switchingToCamera

            let started = await self.configureCameraInputAsync(releaseVideoBeforeStart: true)

            if !started {
                print("[PICKER] recover camera start failed")
            }

            self.modeState = .cameraIdle
            self.endMediaOperation()
        }
    }

    func videoPickerDismissedWithoutSelection() {
        cancelVideoPickerAndRecover()
    }

    func videoSelectionFailed() {
        guard beginMediaOperation(name: "videoSelectionFailed") != nil else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.cancelVideoLoadingTimeout()
            self.videoFrameSource.forceResetAfterFailedLoad()

            self.modeState = .switchingToCamera

            let started = await self.configureCameraInputAsync(releaseVideoBeforeStart: true)

            if !started {
                print("[PICKER] selection failed recover camera failed")
            }

            self.modeState = .cameraIdle
            self.endMediaOperation()
        }
    }

    // MARK: - Video Loading

    func loadVideo(url: URL) {
        guard modeState == .videoPickerPresented ||
              modeState == .cameraIdle ||
              modeState == .videoReady ||
              modeState == .videoEnded else {
            print("[VIDEO] load ignored, state:", modeState)
            return
        }

        guard let operation = beginMediaOperation(name: "loadVideo") else {
            return
        }

        modeState = .loadingVideo

        cancelVideoLoadingTimeout()
        cancelRecordingStartTimeout()
        cancelRecordingStopTimeout()

        hintVisible = false
        inferenceEngine.start()

        startVideoLoadingTimeout(for: operation)

        Task { @MainActor [weak self, url, operation] in
            guard let self else { return }
            guard self.isCurrentOperation(operation) else { return }

            await self.stopCameraAndVideoAsync()

            guard self.isCurrentOperation(operation) else { return }
            guard self.modeState == .loadingVideo else {
                self.recoverToCameraIdleIfNeeded()
                return
            }

            self.videoFrameSource.load(
                url: url,
                autoPlay: false,
                onReady: { [weak self] in
                    Task { @MainActor [weak self, operation] in
                        guard let self else { return }
                        self.handleVideoReady(operation: operation)
                    }
                },
                onFailed: { [weak self] message in
                    Task { @MainActor [weak self, operation, message] in
                        guard let self else { return }
                        await self.handleVideoLoadFailed(
                            operation: operation,
                            message: message
                        )
                    }
                }
            )
        }
    }

    private func handleVideoReady(operation: UUID) {
        guard isCurrentOperation(operation) else {
            return
        }

        cancelVideoLoadingTimeout()

        modeState = .videoReady

        endMediaOperation()

        Task { @MainActor [weak self, operation] in
            guard let self else { return }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))

            guard self.isCurrentOperation(operation) else { return }
            guard self.modeState == .videoReady else { return }

            self.videoFrameSource.play()
        }
    }

    private func handleVideoLoadFailed(
        operation: UUID,
        message: String
    ) async {
        guard isCurrentOperation(operation) else {
            return
        }

        print("[VIDEO] load failed:", message)

        cancelVideoLoadingTimeout()
        videoFrameSource.forceResetAfterFailedLoad()

        modeState = .switchingToCamera

        let started = await configureCameraInputAsync(releaseVideoBeforeStart: true)

        if !started {
            print("[VIDEO] recover camera start failed")
        }

        modeState = .cameraIdle
        endMediaOperation()
    }

    private func handleVideoEnded() {
        print("[VIDEO] ended callback")

        cancelVideoLoadingTimeout()

        switch modeState {
        case .loadingVideo, .videoReady:
            modeState = .videoEnded

        case .videoEnded:
            syncPublishedState()

        case .preparingRecording,
             .recording,
             .stoppingRecording,
             .switchingToCamera:
            print("[VIDEO] ended ignored during active transition:", modeState)

        case .cameraIdle,
             .preparingVideoPicker,
             .videoPickerPresented,
             .stopped:
            print("[VIDEO] ended ignored, current state:", modeState)
            syncPublishedState()
        }
    }

    // MARK: - Switching

    func useLiveCameraInput() {
        guard modeState == .videoReady || modeState == .videoEnded else {
            return
        }

        guard beginMediaOperation(name: "useLiveCameraInput") != nil else {
            return
        }

        modeState = .switchingToCamera

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.videoFrameSource.stop()
            await self.cameraManager.stopForPickerAsync()

            let started = await self.configureCameraInputAsync(releaseVideoBeforeStart: false)

            if !started {
                print("[CAMERA] switch to live failed")
            }

            self.modeState = .cameraIdle
            self.endMediaOperation()
        }
    }

    func backToCamera() {
        useLiveCameraInput()
    }

    // MARK: - Recording

    func toggleRecording() {
        let now = CACurrentMediaTime()

        guard now - lastRecordingToggleAt > 0.45 else {
            print("[RECORD] toggle ignored: debounce")
            return
        }

        lastRecordingToggleAt = now

        switch modeState {
        case .cameraIdle, .videoReady, .videoEnded:
            startRecordingAfterResourceCheck()

        case .recording:
            stopRecordingFromButton()

        case .preparingRecording,
             .stoppingRecording,
             .switchingToCamera,
             .loadingVideo,
             .preparingVideoPicker,
             .videoPickerPresented:
            print("[RECORD] toggle ignored, current state:", modeState)

        case .stopped:
            return
        }
    }

    private func startRecordingAfterResourceCheck() {
        guard modeState == .cameraIdle ||
              modeState == .videoReady ||
              modeState == .videoEnded else {
            return
        }

        guard let operation = beginMediaOperation(name: "startRecording") else {
            return
        }

        let cameFromVideo =
            modeState == .videoReady ||
            modeState == .videoEnded ||
            isUsingVideoFile ||
            videoFrameSource.hasActiveItem

        modeState = .preparingRecording

        cancelVideoLoadingTimeout()
        cancelRecordingStartTimeout()
        cancelRecordingStopTimeout()

        startRecordingPreparationTimeout(for: operation)

        Task { @MainActor [weak self, operation, cameFromVideo] in
            guard let self else { return }
            guard self.isCurrentOperation(operation) else { return }

            if cameFromVideo {
                self.videoFrameSource.stop()
                await self.cameraManager.stopForPickerAsync()
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard self.isCurrentOperation(operation) else { return }
            guard self.modeState == .preparingRecording else {
                self.recoverToCameraIdleIfNeeded()
                return
            }

            let started = await self.configureCameraInputAsync(
                releaseVideoBeforeStart: cameFromVideo
            )

            guard self.isCurrentOperation(operation) else { return }

            guard started else {
                print("[RECORD] camera start failed")
                self.cancelRecordingStartTimeout()
                self.isRecording = false
                self.modeState = .cameraIdle
                self.endMediaOperation()
                return
            }

            guard self.modeState == .preparingRecording else {
                self.recoverToCameraIdleIfNeeded()
                return
            }

            print("[RECORD] call startRecording")
            self.recordingManager.startRecording()
        }
    }

    private func handleRecordingStarted(success: Bool) {
        cancelRecordingStartTimeout()

        guard modeState == .preparingRecording else {
            print("[RECORD] onStarted ignored, current state:", modeState)
            return
        }

        guard success else {
            print("[RECORD] start failed, recover to cameraIdle")
            isRecording = false
            modeState = .cameraIdle
            endMediaOperation()
            return
        }

        print("[RECORD] recording started")

        isRecording = true
        pulseScale = 1.0
        modeState = .recording

        endMediaOperation()
    }

    private func stopRecordingFromButton() {
        guard modeState == .recording || isRecording || recordingManager.isRecording else {
            isRecording = false
            modeState = .cameraIdle
            return
        }

        guard beginMediaOperation(name: "stopRecording") != nil else {
            return
        }

        print("[RECORD] stop button tapped")

        isRecording = false
        modeState = .stoppingRecording

        cancelRecordingStartTimeout()
        startRecordingStopTimeout()

        Task { @MainActor [weak self] in
            guard let self else { return }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(80))

            print("[RECORD] call stopRecording")
            self.recordingManager.stopRecording()
        }
    }

    private func handleRecordingStopped(url: URL?) {
        print("[RECORD] onStopped callback, url:", url?.path ?? "nil")

        cancelRecordingStartTimeout()
        cancelRecordingStopTimeout()

        isRecording = false

        if modeState == .recording ||
            modeState == .preparingRecording ||
            modeState == .stoppingRecording {
            modeState = .cameraIdle
        }

        endMediaOperation()

        guard let url else {
            return
        }

        recordingManager.saveToPhotoLibrary(url: url) { (success: Bool) in
            print("[RECORD] saveToPhotoLibrary finished:", success)
        }
    }

    // MARK: - Timeouts

    private func startRecordingPreparationTimeout(for operationID: UUID) {
        recordingStartTimeoutTask?.cancel()

        recordingStartTimeoutTask = Task { @MainActor [weak self, operationID] in
            try? await Task.sleep(for: .seconds(8))

            guard let self else { return }
            guard self.isCurrentOperation(operationID) else { return }

            if self.modeState == .preparingRecording {
                print("[RECOVER] preparingRecording timeout, recover to cameraIdle")

                self.recordingManager.forceReset()
                self.isRecording = false
                self.modeState = .cameraIdle
                self.forceEndMediaOperation()
            }
        }
    }

    private func startRecordingStopTimeout() {
        recordingStopTimeoutTask?.cancel()

        recordingStopTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))

            guard let self else { return }

            if self.modeState == .stoppingRecording {
                print("[RECOVER] stopRecording timeout, force cameraIdle")

                self.recordingManager.forceReset()
                self.isRecording = false
                self.modeState = .cameraIdle
                self.startPulse()
                self.forceEndMediaOperation()
            }
        }
    }

    private func cancelRecordingStartTimeout() {
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
    }

    private func cancelRecordingStopTimeout() {
        recordingStopTimeoutTask?.cancel()
        recordingStopTimeoutTask = nil
    }

    private func cancelVideoLoadingTimeout() {
        videoLoadingTimeoutTask?.cancel()
        videoLoadingTimeoutTask = nil
    }

    private func startVideoLoadingTimeout(for operationID: UUID) {
        cancelVideoLoadingTimeout()

        videoLoadingTimeoutTask = Task { @MainActor [weak self, operationID] in
            try? await Task.sleep(for: .seconds(8))

            guard let self else { return }
            guard self.isCurrentOperation(operationID) else { return }

            if self.modeState == .loadingVideo {
                print("[RECOVER] video loading timeout")

                self.videoFrameSource.forceResetAfterFailedLoad()
                self.modeState = .switchingToCamera

                let started = await self.configureCameraInputAsync(
                    releaseVideoBeforeStart: true
                )

                if !started {
                    print("[RECOVER] camera start failed after video timeout")
                }

                self.modeState = .cameraIdle
                self.forceEndMediaOperation()
            }
        }
    }

    // MARK: - Recovery

    private func recoverToCameraIdleIfNeeded() {
        if modeState == .preparingRecording ||
            modeState == .stoppingRecording ||
            modeState == .switchingToCamera ||
            modeState == .loadingVideo ||
            modeState == .preparingVideoPicker ||
            modeState == .videoPickerPresented {

            print("[RECOVER] force recover from:", modeState)

            cancelRecordingStartTimeout()
            cancelRecordingStopTimeout()
            cancelVideoLoadingTimeout()

            isRecording = false
            modeState = .cameraIdle
            forceEndMediaOperation()
        }
    }

    // MARK: - Operation ID

    private func makeNewOperationID() -> UUID {
        let id = UUID()
        operationID = id
        return id
    }

    private func invalidateCurrentOperation() {
        operationID = UUID()
    }

    private func isCurrentOperation(_ id: UUID) -> Bool {
        operationID == id
    }

    // MARK: - UI Helpers

    private func startHintAutoHide() {
        hintTask?.cancel()

        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))

            guard let self else { return }

            withAnimation(.easeOut(duration: 0.8)) {
                self.hintVisible = false
            }
        }
    }

    private func applyTrackedResults(_ tracked: [DetectionResult]) {
        for det in tracked {
            trailEffectEngine.addPoint(
                trackId: det.trackId,
                center: det.center,
                color: det.dominantColor
            )
        }

        if let first = tracked.first {
            fps = Int(first.fps)
            hardwareLabel = first.hardware.rawValue
            hardwareColor = hardwareColor(for: first.hardware)
        }

        trailOverlayView.setNeedsDisplay()
    }

    private func hardwareColor(for hw: InferenceHardware) -> Color {
        switch hw {
        case .npu:
            return Color(hex: 0x00FF88)

        case .gpu:
            return Color(hex: 0x88AAFF)

        case .cpu:
            return Color(hex: 0xFFAA00)

        case .mock:
            return Color(white: 0.6)
        }
    }

    private func startPulse() {
        pulseScale = 1.0

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))

            guard let self else { return }
            self.pulseScale = 1.18
        }
    }
}
