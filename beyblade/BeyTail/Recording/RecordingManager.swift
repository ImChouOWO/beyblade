import AVFoundation
import UIKit
import Photos

@MainActor
final class RecordingManager {

    enum RecordingState: String {
        case idle
        case starting
        case recording
        case stopping
    }

    private(set) var state: RecordingState = .idle
    private(set) var isRecording = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?

    private var requestedOrientation: UIDeviceOrientation = .portrait
    private var didStartSession = false
    private var pendingStopAfterStart = false

    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var appendedFrameCount = 0

    var onStarted: ((Bool) -> Void)?
    var onStopped: ((URL?) -> Void)?

    // MARK: - Start

    func startRecording(deviceOrientation: UIDeviceOrientation) {
        switch state {
        case .idle:
            break
        case .starting:
            print("[Recording] start ignored: already starting")
            return
        case .recording:
            print("[Recording] start ignored: already recording")
            onStarted?(true)
            return
        case .stopping:
            print("[Recording] start ignored: still stopping")
            onStarted?(false)
            return
        }

        requestedOrientation = normalizedOrientation(deviceOrientation)
        pendingStopAfterStart = false
        didStartSession = false
        firstPresentationTime = nil
        lastPresentationTime = nil
        appendedFrameCount = 0

        outputURL = makeOutputURL()
        writer = nil
        videoInput = nil

        state = .starting
        isRecording = true

        // Writer 會在第一個相機 sampleBuffer 到達時，依照真實尺寸建立。
        // 這樣不需要假設一定是 720x1280，也不會把 UI 畫面寫入影片。
        state = .recording
        print("[Recording] waiting for first camera frame, orientation:", requestedOrientation.rawValue)
        onStarted?(true)

        if pendingStopAfterStart {
            pendingStopAfterStart = false
            stopRecording()
        }
    }

    // MARK: - Append camera frames only

    func append(sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              isRecording,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        if writer == nil {
            guard configureWriter(
                formatDescription: formatDescription,
                firstSampleBuffer: sampleBuffer
            ) else {
                failRecording("unable to configure AVAssetWriter")
                return
            }
        }

        guard let writer,
              let videoInput,
              writer.status == .writing else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard presentationTime.isValid,
              !presentationTime.isIndefinite else {
            return
        }

        if !didStartSession {
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
            firstPresentationTime = presentationTime
        }

        guard videoInput.isReadyForMoreMediaData else {
            return
        }

        guard videoInput.append(sampleBuffer) else {
            print("[Recording] append failed:", writer.error?.localizedDescription ?? "unknown")
            return
        }

        appendedFrameCount += 1
        lastPresentationTime = presentationTime

        if appendedFrameCount % 30 == 0,
           let firstPresentationTime {
            let duration = CMTimeGetSeconds(
                CMTimeSubtract(presentationTime, firstPresentationTime)
            )
            print(
                "[Recording] frames:", appendedFrameCount,
                "duration:", String(format: "%.2f", duration)
            )
        }
    }

    private func configureWriter(
        formatDescription: CMFormatDescription,
        firstSampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard let outputURL else {
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)

            guard width > 0, height > 0 else {
                print("[Recording] invalid frame size:", width, "x", height)
                return false
            }

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: recommendedBitRate(width: width, height: height),
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings,
                sourceFormatHint: formatDescription
            )
            input.expectsMediaDataInRealTime = true
            input.transform = preferredTransform(
                for: requestedOrientation,
                sourceWidth: width,
                sourceHeight: height
            )

            guard writer.canAdd(input) else {
                print("[Recording] cannot add video input")
                return false
            }

            writer.add(input)

            guard writer.startWriting() else {
                print("[Recording] startWriting failed:", writer.error?.localizedDescription ?? "unknown")
                return false
            }

            self.writer = writer
            self.videoInput = input

            let pts = CMSampleBufferGetPresentationTimeStamp(firstSampleBuffer)
            print(
                "[Recording] writer configured:",
                "size=\(width)x\(height)",
                "firstPTS=\(CMTimeGetSeconds(pts))"
            )

            return true
        } catch {
            print("[Recording] configure error:", error.localizedDescription)
            return false
        }
    }

    // MARK: - Stop

    func stopRecording() {
        switch state {
        case .idle:
            isRecording = false
            onStopped?(nil)
            return

        case .starting:
            pendingStopAfterStart = true
            return

        case .recording:
            break

        case .stopping:
            return
        }

        state = .stopping
        isRecording = false

        guard let writer,
              let videoInput,
              let outputURL,
              didStartSession,
              appendedFrameCount > 0 else {
            print("[Recording] stop failed: no camera frames were appended")
            resetWriterState(cancelWriter: true)
            state = .idle
            onStopped?(nil)
            return
        }

        let duration: Double
        if let firstPresentationTime,
           let lastPresentationTime {
            duration = max(
                0,
                CMTimeGetSeconds(
                    CMTimeSubtract(lastPresentationTime, firstPresentationTime)
                )
            )
        } else {
            duration = 0
        }

        print(
            "[Recording] finishing:",
            "frames=\(appendedFrameCount)",
            "duration=\(String(format: "%.2f", duration))"
        )

        videoInput.markAsFinished()

        writer.finishWriting { [weak self, outputURL] in
            Task { @MainActor [weak self, outputURL] in
                self?.handleStopFinished(outputURL: outputURL)
            }
        }
    }

    private func handleStopFinished(outputURL: URL) {
        guard state == .stopping else {
            return
        }

        let status = writer?.status
        let errorMessage = writer?.error?.localizedDescription

        resetWriterState(cancelWriter: false)
        state = .idle
        isRecording = false
        pendingStopAfterStart = false

        if let errorMessage {
            print("[Recording] finish error:", errorMessage)
            onStopped?(nil)
            return
        }

        guard status == .completed else {
            print("[Recording] writer status:", String(describing: status))
            onStopped?(nil)
            return
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            print("[Recording] output file does not exist")
            onStopped?(nil)
            return
        }

        print("[Recording] completed:", outputURL.path)
        onStopped?(outputURL)
    }

    private func failRecording(_ message: String) {
        print("[Recording] failed:", message)
        resetWriterState(cancelWriter: true)
        state = .idle
        isRecording = false
        pendingStopAfterStart = false
        onStopped?(nil)
    }

    // MARK: - Reset

    func forceReset() {
        print("[Recording] forceReset, state:", state.rawValue)

        pendingStopAfterStart = false
        isRecording = false
        state = .idle
        resetWriterState(cancelWriter: true)
    }

    private func resetWriterState(cancelWriter: Bool) {
        if cancelWriter,
           let writer,
           writer.status == .writing {
            videoInput?.markAsFinished()
            writer.cancelWriting()
        }

        writer = nil
        videoInput = nil
        outputURL = nil
        didStartSession = false
        firstPresentationTime = nil
        lastPresentationTime = nil
        appendedFrameCount = 0
    }

    // MARK: - Photo library

    func saveToPhotoLibrary(
        url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            performSaveToPhotoLibrary(url: url, completion: completion)

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self, url] newStatus in
                Task { @MainActor [weak self, url, newStatus] in
                    guard let self else {
                        completion(false)
                        return
                    }

                    switch newStatus {
                    case .authorized, .limited:
                        self.performSaveToPhotoLibrary(url: url, completion: completion)
                    default:
                        completion(false)
                    }
                }
            }

        default:
            completion(false)
        }
    }

    private func performSaveToPhotoLibrary(
        url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            Task { @MainActor [success, error] in
                if let error {
                    print("[Recording] save error:", error.localizedDescription)
                }
                completion(success)
            }
        }
    }

    // MARK: - Helpers

    private func makeOutputURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "beytail_\(timestamp)_\(UUID().uuidString.prefix(8)).mp4"

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
    }

    private func normalizedOrientation(
        _ orientation: UIDeviceOrientation
    ) -> UIDeviceOrientation {
        switch orientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return orientation
        default:
            return .portrait
        }
    }

    private func preferredTransform(
        for orientation: UIDeviceOrientation,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGAffineTransform {
        // CameraManager 現在固定輸出 videoRotationAngle = 90，
        // 因此 sampleBuffer 通常已是直式 720x1280。
        let sourceIsPortrait = sourceHeight >= sourceWidth

        guard sourceIsPortrait else {
            switch orientation {
            case .portrait:
                return CGAffineTransform(rotationAngle: .pi / 2)
            case .portraitUpsideDown:
                return CGAffineTransform(rotationAngle: -.pi / 2)
            case .landscapeRight:
                return CGAffineTransform(rotationAngle: .pi)
            default:
                return .identity
            }
        }

        switch orientation {
        case .landscapeLeft:
            // UIDevice 的 landscapeLeft 表示裝置左側朝下，
            // 對已是直式的相機 frame 應順時針旋轉 90 度。
            return CGAffineTransform(rotationAngle: -.pi / 2)

        case .landscapeRight:
            // UIDevice 的 landscapeRight 表示裝置右側朝下，
            // 對已是直式的相機 frame 應逆時針旋轉 90 度。
            return CGAffineTransform(rotationAngle: .pi / 2)

        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: .pi)

        default:
            return .identity
        }
    }

    private func recommendedBitRate(width: Int, height: Int) -> Int {
        let pixels = width * height

        if pixels >= 1920 * 1080 {
            return 12_000_000
        }

        if pixels >= 1280 * 720 {
            return 8_000_000
        }

        return 4_000_000
    }
}
