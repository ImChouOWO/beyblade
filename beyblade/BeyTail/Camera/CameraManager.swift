import AVFoundation
import UIKit
import ImageIO

final class CameraManager: NSObject {

    // MARK: - Public

    let session = AVCaptureSession()

    var onFrame: ((CMSampleBuffer) -> Void)?

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

    // MARK: - Private

    private let sessionQueue = DispatchQueue(
        label: "com.beytail.camera.session.queue",
        qos: .userInitiated
    )

    private let frameQueue = DispatchQueue(
        label: "com.beytail.camera.frame.queue",
        qos: .userInitiated
    )

    private let videoOutput = AVCaptureVideoDataOutput()

    private var isConfigured = false
    private var isSessionRunning = false

    private let orientationLock = NSLock()
    private var _currentVisionImageOrientation: CGImagePropertyOrientation = .right
    private var _currentVideoRotationAngle: CGFloat = 90

    private var lastAppliedVideoAngle: CGFloat = -1
    private var lastValidDeviceOrientation: UIDeviceOrientation = .portrait

    // MARK: - Init

    override init() {
        super.init()

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange() {
        updateDeviceOrientationState()
        updateVideoRotation()
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

        updateDeviceOrientationState()
        applyCurrentVideoRotation(force: true)

        guard !session.isRunning else {
            isSessionRunning = true
            return
        }

        session.startRunning()
        isSessionRunning = session.isRunning

        applyCurrentVideoRotation(force: true)
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

    private func removeExistingInputsAndOutputs() {
        for input in session.inputs {
            session.removeInput(input)
        }

        for output in session.outputs {
            session.removeOutput(output)
        }
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
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }

            connection.isVideoMirrored = false
        }

        applyCurrentVideoRotation(
            to: connection,
            force: true
        )
    }

    // MARK: - Dynamic Rotation

    func updateVideoRotation() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.updateDeviceOrientationState()
            self.applyCurrentVideoRotation(force: false)
        }
    }

    private func applyCurrentVideoRotation(force: Bool) {
        guard let connection = videoOutput.connection(with: .video) else {
            return
        }

        applyCurrentVideoRotation(
            to: connection,
            force: force
        )
    }

    private func applyCurrentVideoRotation(
        to connection: AVCaptureConnection,
        force: Bool
    ) {
        let angle = videoRotationAngle(
            for: lastValidDeviceOrientation
        )

        let visionOrientation = visionImageOrientation(
            for: lastValidDeviceOrientation
        )

        orientationLock.lock()
        _currentVideoRotationAngle = angle
        _currentVisionImageOrientation = visionOrientation
        orientationLock.unlock()

        guard force || angle != lastAppliedVideoAngle else {
            return
        }

        guard connection.isVideoRotationAngleSupported(angle) else {
            print("[WARN] videoRotationAngle not supported:", angle)
            return
        }

        connection.videoRotationAngle = angle
        lastAppliedVideoAngle = angle

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }

        print(
            "[CAMERA]",
            "deviceOrientation:", lastValidDeviceOrientation.rawValue,
            "videoRotationAngle:", angle,
            "visionOrientation:", visionOrientation.rawValue
        )
    }

    private func updateDeviceOrientationState() {
        let orientation = UIDevice.current.orientation

        switch orientation {
        case .portrait,
             .portraitUpsideDown,
             .landscapeLeft,
             .landscapeRight:
            lastValidDeviceOrientation = orientation

        default:
            break
        }

        let angle = videoRotationAngle(
            for: lastValidDeviceOrientation
        )

        let visionOrientation = visionImageOrientation(
            for: lastValidDeviceOrientation
        )

        orientationLock.lock()
        _currentVideoRotationAngle = angle
        _currentVisionImageOrientation = visionOrientation
        orientationLock.unlock()
    }

    private func videoRotationAngle(
        for deviceOrientation: UIDeviceOrientation
    ) -> CGFloat {
        switch deviceOrientation {
        case .portrait:
            return 90

        case .landscapeRight:
            return 0

        case .landscapeLeft:
            return 180

        case .portraitUpsideDown:
            return 270

        default:
            return 90
        }
    }

    private func visionImageOrientation(
        for deviceOrientation: UIDeviceOrientation
    ) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .portrait:
            return .right

        case .landscapeLeft:
            return .up

        case .landscapeRight:
            return .down

        case .portraitUpsideDown:
            return .left

        default:
            return .right
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

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame?(sampleBuffer)
    }
}
