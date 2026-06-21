import Foundation
import AVFoundation

/// 相機管線（對應 Android CameraManager + ImageAnalysis）：
///   - 後鏡頭 1920×1080，connection 轉直向 → BGRA buffer 1080×1920
///   - 30/60fps 可切（60fps 找支援的 activeFormat）
///   - 手電筒、麥克風（錄影收音）
/// 視訊幀以 CVPixelBuffer 回呼給渲染器（同一條 buffer 做推論+渲染，同 Android）。
final class CameraManager: NSObject {

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private let audioQueue = DispatchQueue(label: "camera.audio")

    private var videoDevice: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    /// 每幀視訊回呼（camera queue 上）— pixelBuffer 為直向 1080×1920 BGRA
    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// 錄影中的音訊 sample 回呼
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    /// 解析度確定回呼（寬, 高 — 直向）
    var onResolutionKnown: ((Int, Int) -> Void)?

    private(set) var use60Fps = false

    func start() {
        sessionQueue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private var configured = false

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // 視訊輸入
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoDevice = device

        // 音訊輸入（錄影收音）
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        // 視訊輸出：BGRA（Metal/推論直接可用）
        videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // 直向 buffer（1080×1920，同 Android 的 portrait 串流）
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
        }

        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()
        applyFrameRate()
        onResolutionKnown?(1080, 1920)
    }

    // ── 30/60fps ─────────────────────────────────────────────────────────

    func setFrameRate(is60: Bool) {
        use60Fps = is60
        sessionQueue.async { [self] in applyFrameRate() }
    }

    private func applyFrameRate() {
        guard let device = videoDevice else { return }
        let targetFps = use60Fps ? 60.0 : 30.0
        do {
            try device.lockForConfiguration()
            if use60Fps {
                // 找支援 1920×1080@60 的 format
                for format in device.formats {
                    let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard dim.width == 1920, dim.height == 1080 else { continue }
                    if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 }) {
                        device.activeFormat = format
                        break
                    }
                }
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            print("[Camera] setFrameRate failed: \(error)")
        }
    }

    // ── 手電筒 ───────────────────────────────────────────────────────────

    func setTorch(_ on: Bool) {
        sessionQueue.async { [self] in
            guard let device = videoDevice, device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onVideoFrame?(pb, pts)
        } else if output === audioOutput {
            onAudioSample?(sampleBuffer)
        }
    }
}
