import AVFoundation
import UIKit

final class CameraManager: NSObject {

    // MARK: - Public

    let session = AVCaptureSession()

    var onFrame: ((CMSampleBuffer) -> Void)?

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

    // MARK: - Permission / Start

    func requestPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            start()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }

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
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
            guard let self else { return }

            self.startSessionIfNeeded()
        }
    }

    private func startAsync() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
            guard let self else { return }

            self.stopSessionIfNeeded()
        }
    }

    func stopForPickerAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
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

        guard !session.isRunning else {
            isSessionRunning = true
            return
        }

        session.startRunning()
        isSessionRunning = session.isRunning
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
        if #available(iOS 17.0, *) {
            let portraitAngle: CGFloat = 90

            if connection.isVideoRotationAngleSupported(portraitAngle) {
                connection.videoRotationAngle = portraitAngle
            }

        } else {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

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

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // intentionally empty
    }
}
