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

    private var activeCameraDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    private var lastAppliedRotationAngle: CGFloat = -1

    private let orientationLock = NSLock()
    private var _currentVisionImageOrientation: CGImagePropertyOrientation = .right

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

        activeCameraDevice = device
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        )

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
        guard let rotationCoordinator else {
            return
        }

        let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture

        guard angle.isFinite else {
            return
        }

        let visionOrientation = visionImageOrientation(
            forRotationAngle: angle
        )

        setCurrentVisionImageOrientation(visionOrientation)

        guard force || angle != lastAppliedRotationAngle else {
            return
        }

        guard connection.isVideoRotationAngleSupported(angle) else {
            print("[WARN] videoRotationAngle not supported:", angle)
            return
        }

        connection.videoRotationAngle = angle
        lastAppliedRotationAngle = angle

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }

        print(
            "[CAMERA] apply videoRotationAngle:",
            angle,
            "visionOrientation:",
            visionOrientation
        )
    }

    private func setCurrentVisionImageOrientation(
        _ orientation: CGImagePropertyOrientation
    ) {
        orientationLock.lock()
        _currentVisionImageOrientation = orientation
        orientationLock.unlock()
    }

    private func visionImageOrientation(
        forRotationAngle angle: CGFloat
    ) -> CGImagePropertyOrientation {
        let rounded = Int(round(angle / 90.0)) * 90
        let normalized = ((rounded % 360) + 360) % 360

        switch normalized {
        case 0:
            return .up

        case 90:
            return .right

        case 180:
            return .down

        case 270:
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
        applyCurrentVideoRotation(
            to: connection,
            force: false
        )

        onFrame?(sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // intentionally empty
    }
}
