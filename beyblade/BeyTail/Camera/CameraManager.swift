import AVFoundation
import UIKit
import ImageIO

final class CameraManager: NSObject {

    // MARK: - Public

    let session = AVCaptureSession()

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAudioFrame: ((CMSampleBuffer) -> Void)?

    var currentVisionImageOrientation: CGImagePropertyOrientation {
        orientationLock.lock()
        defer {
            orientationLock.unlock()
        }

        return _currentVisionImageOrientation
    }

    var currentVideoRotationAngle: CGFloat {
        orientationLock.lock()
        defer {
            orientationLock.unlock()
        }

        return _currentVideoRotationAngle
    }

    // MARK: - Fixed Orientation

    /*
     固定順時針 90 度畫面基準。

     依照你前面的實測：
     - 順時針旋轉 90 度時 bbox 正常
     - 該方向對應原本的 landscapeRight
     - 原本 landscapeRight 對應：
       videoRotationAngle = 0
       visionImageOrientation = .down

     所以這裡完全固定相機輸出與 Vision 方向。
     手機實體旋轉時，不再改變 camera output / Vision / bbox 座標系。
    */
    private let fixedVideoRotationAngle: CGFloat = 90
    private let fixedVisionImageOrientation: CGImagePropertyOrientation = .up

    // MARK: - Private

    private let sessionQueue = DispatchQueue(
        label: "com.beytail.camera.session.queue",
        qos: .userInitiated
    )

    private let frameQueue = DispatchQueue(
        label: "com.beytail.camera.frame.queue",
        qos: .userInitiated
    )

    private let audioQueue = DispatchQueue(
        label: "com.beytail.camera.audio.queue",
        qos: .userInitiated
    )

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var isConfigured = false
    private var isAudioConfigured = false
    private var isSessionRunning = false

    private let orientationLock = NSLock()
    private var _currentVisionImageOrientation: CGImagePropertyOrientation = .down
    private var _currentVideoRotationAngle: CGFloat = 0

    private var lastAppliedVideoAngle: CGFloat = -1

    // MARK: - Init

    override init() {
        super.init()

        /*
         不再監聽 UIDevice.orientationDidChangeNotification。
         目標是固定相機畫布方向，而不是跟著手機旋轉改變影像座標系。
        */
        setFixedOrientationState()
    }

    deinit {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Permission / Start

    func requestPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            start()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else {
                    return
                }

                if granted {
                    self.start()
                } else {
                    print("[ERROR] Camera permission denied by user.")
                }
            }

        case .denied:
            print("[ERROR] Camera permission denied. Please enable it in Settings.")

        case .restricted:
            print("[ERROR] Camera permission restricted.")

        @unknown default:
            print("[ERROR] Unknown camera permission status.")
        }
    }

    func requestPermissionAndStartAsync() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            return await startAsync()

        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }

            guard granted else {
                print("[ERROR] Camera permission denied by user.")
                return false
            }

            return await startAsync()

        case .denied:
            print("[ERROR] Camera permission denied. Please enable it in Settings.")
            return false

        case .restricted:
            print("[ERROR] Camera permission restricted.")
            return false

        @unknown default:
            print("[ERROR] Unknown camera permission status.")
            return false
        }
    }

    /// 只在使用者開始錄影時要求麥克風權限，並將音訊輸入／輸出加入既有相機 Session。
    func prepareAudioCaptureAsync() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        let granted: Bool

        switch status {
        case .authorized:
            granted = true

        case .notDetermined:
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }

        case .denied, .restricted:
            granted = false

        @unknown default:
            granted = false
        }

        guard granted else {
            print("[ERROR] Microphone permission is required for recording.")
            return false
        }

        guard configureAudioSessionForRecording() else {
            return false
        }

        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let configured = self.configureAudioCaptureIfNeeded()
                continuation.resume(returning: configured)
            }
        }
    }

    private func configureAudioSessionForRecording() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker]
            )
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setActive(true)
            return true
        } catch {
            print(
                "[ERROR] Configure audio session failed:",
                error.localizedDescription
            )
            return false
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.startSessionIfNeeded()
        }
    }

    private func startAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                self.startSessionIfNeeded()
                continuation.resume(returning: self.session.isRunning)
            }
        }
    }

    // MARK: - Stop

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.stopSessionIfNeeded()
        }
    }

    func stopForPickerAsync() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                self.stopSessionIfNeeded()
                continuation.resume()
            }
        }
    }

    // MARK: - Session

    private func startSessionIfNeeded() {
        if !isConfigured {
            configureSession()
        }

        guard isConfigured else {
            isSessionRunning = false
            return
        }

        setFixedOrientationState()
        applyFixedVideoRotation(force: true)

        guard !session.isRunning else {
            isSessionRunning = true
            return
        }

        session.startRunning()
        isSessionRunning = session.isRunning

        applyFixedVideoRotation(force: true)
    }

    private func stopSessionIfNeeded() {
        guard session.isRunning else {
            isSessionRunning = false
            return
        }

        session.stopRunning()
        isSessionRunning = false
    }

    // MARK: - Configure

    private func configureSession() {
        guard !session.isRunning else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        defer {
            session.commitConfiguration()
        }

        removeExistingInputsAndOutputs()

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            isConfigured = false
            print("[ERROR] Back camera not found.")
            return
        }

        guard addCameraInput(device) else {
            isConfigured = false
            return
        }

        guard addVideoOutput() else {
            isConfigured = false
            return
        }

        if let connection = videoOutput.connection(with: .video) {
            configureVideoConnection(connection)
        }

        configureFrameRate(device)

        isConfigured = true
    }

    private func configureAudioCaptureIfNeeded() -> Bool {
        if isAudioConfigured,
           session.inputs.contains(where: { input in
               guard let deviceInput = input as? AVCaptureDeviceInput else {
                   return false
               }
               return deviceInput.device.hasMediaType(.audio)
           }),
           session.outputs.contains(where: { $0 === audioOutput }) {
            return true
        }

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            print("[ERROR] Microphone device not found.")
            isAudioConfigured = false
            return false
        }

        let audioInput: AVCaptureDeviceInput

        do {
            audioInput = try AVCaptureDeviceInput(device: microphone)
        } catch {
            print(
                "[ERROR] Create microphone input failed:",
                error.localizedDescription
            )
            isAudioConfigured = false
            return false
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        let hasAudioInput = session.inputs.contains { input in
            guard let deviceInput = input as? AVCaptureDeviceInput else {
                return false
            }

            return deviceInput.device.hasMediaType(.audio)
        }

        if !hasAudioInput {
            guard session.canAddInput(audioInput) else {
                print("[ERROR] Cannot add microphone input.")
                isAudioConfigured = false
                return false
            }

            session.addInput(audioInput)
        }

        audioOutput.setSampleBufferDelegate(
            self,
            queue: audioQueue
        )

        if !session.outputs.contains(where: { $0 === audioOutput }) {
            guard session.canAddOutput(audioOutput) else {
                print("[ERROR] Cannot add camera audio output.")
                isAudioConfigured = false
                return false
            }

            session.addOutput(audioOutput)
        }

        isAudioConfigured = true
        return true
    }

    private func removeExistingInputsAndOutputs() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)

        for input in session.inputs {
            session.removeInput(input)
        }

        for output in session.outputs {
            session.removeOutput(output)
        }

        isAudioConfigured = false
    }

    private func addCameraInput(_ device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)

            guard session.canAddInput(input) else {
                print("[ERROR] Cannot add camera input.")
                return false
            }

            session.addInput(input)
            return true

        } catch {
            print("[ERROR] Create camera input failed:", error.localizedDescription)
            return false
        }
    }

    private func addVideoOutput() -> Bool {
        videoOutput.alwaysDiscardsLateVideoFrames = true

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        videoOutput.setSampleBufferDelegate(
            self,
            queue: frameQueue
        )

        guard session.canAddOutput(videoOutput) else {
            print("[ERROR] Cannot add camera video output.")
            return false
        }

        session.addOutput(videoOutput)

        return true
    }

    private func configureVideoConnection(_ connection: AVCaptureConnection) {
        configureMirroringIfNeeded(connection)

        applyFixedVideoRotation(
            to: connection,
            force: true
        )
    }

    private func configureMirroringIfNeeded(_ connection: AVCaptureConnection) {
        /*
         videoOutput connection 可以安全關閉 mirroring。
         PreviewLayer connection 不要這樣做，否則可能因
         automaticallyAdjustsVideoMirroring == true 而 crash。
        */
        guard connection.isVideoMirroringSupported else {
            return
        }

        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }

        connection.isVideoMirrored = false
    }

    // MARK: - Fixed Rotation

    func updateVideoRotation() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.setFixedOrientationState()
            self.applyFixedVideoRotation(force: false)
        }
    }

    private func setFixedOrientationState() {
        orientationLock.lock()
        _currentVideoRotationAngle = fixedVideoRotationAngle
        _currentVisionImageOrientation = fixedVisionImageOrientation
        orientationLock.unlock()
    }

    private func applyFixedVideoRotation(force: Bool) {
        guard let connection = videoOutput.connection(with: .video) else {
            return
        }

        applyFixedVideoRotation(
            to: connection,
            force: force
        )
    }

    private func applyFixedVideoRotation(
        to connection: AVCaptureConnection,
        force: Bool
    ) {
        setFixedOrientationState()

        let angle = fixedVideoRotationAngle
        let visionOrientation = fixedVisionImageOrientation

        guard force || angle != lastAppliedVideoAngle else {
            return
        }

        guard connection.isVideoRotationAngleSupported(angle) else {
            print("[WARN] videoRotationAngle not supported:", angle)
            return
        }

        connection.videoRotationAngle = angle
        lastAppliedVideoAngle = angle

        print(
            "[CAMERA_FIXED]",
            "videoRotationAngle:", angle,
            "visionOrientation:", visionOrientation.rawValue
        )
    }

    // MARK: - Tap To Focus

    func focus(at devicePoint: CGPoint) {
        let point = CGPoint(
            x: min(max(devicePoint.x, 0), 1),
            y: min(max(devicePoint.y, 0), 1)
        )

        sessionQueue.async { [weak self] in
            guard let self,
                  let input = self.session.inputs
                    .compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.hasMediaType(.video) }) else {
                return
            }

            let device = input.device

            do {
                try device.lockForConfiguration()
                defer {
                    device.unlockForConfiguration()
                }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point

                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(
                        .continuousAutoFocus
                    ) {
                        device.focusMode = .continuousAutoFocus
                    }
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point

                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    } else if device.isExposureModeSupported(
                        .continuousAutoExposure
                    ) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }

                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = true
                }

                device.isSubjectAreaChangeMonitoringEnabled = true

                print(
                    "[CAMERA] focus point:",
                    point.x,
                    point.y
                )
            } catch {
                print(
                    "[CAMERA] focus configuration failed:",
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: - Frame Rate

    private func configureFrameRate(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            device.activeVideoMinFrameDuration = CMTime(
                value: 1,
                timescale: 30
            )

            device.activeVideoMaxFrameDuration = CMTime(
                value: 1,
                timescale: 30
            )

            device.unlockForConfiguration()

        } catch {
            print("[WARN] Cannot lock camera frame rate:", error.localizedDescription)
        }
    }
}

// MARK: - AVCaptureDataOutputSampleBufferDelegate

extension CameraManager:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            onFrame?(sampleBuffer)
            return
        }

        if output === audioOutput {
            onAudioFrame?(sampleBuffer)
        }
    }
}
