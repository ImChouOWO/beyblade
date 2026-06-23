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
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?

    private var didStartSession = false
    private var pendingStopAfterStart = false

    var onStarted: ((Bool) -> Void)?
    var onStopped: ((URL?) -> Void)?

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

        state = .starting
        isRecording = false
        pendingStopAfterStart = false
        didStartSession = false

        let url = makeOutputURL()
        outputURL = url

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 720,
                AVVideoHeightKey: 1280,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.transform = preferredTransform(for: normalizedOrientation(deviceOrientation))

            guard writer.canAdd(input) else {
                print("[Recording] cannot add video input")
                resetWriterState()
                state = .idle
                onStarted?(false)
                return
            }

            writer.add(input)

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 720,
                    kCVPixelBufferHeightKey as String: 1280
                ]
            )

            self.writer = writer
            self.videoInput = input
            self.adaptor = adaptor

            guard writer.startWriting() else {
                print("[Recording] startWriting failed:", writer.error?.localizedDescription ?? "unknown")
                resetWriterState()
                state = .idle
                onStarted?(false)
                return
            }

            handleStartFinished(success: true)

        } catch {
            print("[Recording] start error:", error.localizedDescription)
            resetWriterState()
            state = .idle
            onStarted?(false)
        }
    }

    private func handleStartFinished(success: Bool) {
        guard state == .starting else {
            return
        }

        guard success else {
            resetWriterState()
            state = .idle
            isRecording = false
            pendingStopAfterStart = false
            onStarted?(false)
            return
        }

        state = .recording
        isRecording = true
        onStarted?(true)

        if pendingStopAfterStart {
            pendingStopAfterStart = false
            stopRecording()
        }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              isRecording,
              let writer,
              let videoInput,
              let adaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !didStartSession {
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
        }

        guard videoInput.isReadyForMoreMediaData else {
            return
        }

        let success = adaptor.append(
            pixelBuffer,
            withPresentationTime: presentationTime
        )

        if !success {
            print("[Recording] append frame failed")
        }
    }

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

        let url = outputURL

        videoInput?.markAsFinished()

        writer?.finishWriting { [weak self, url] in
            Task { @MainActor [weak self, url] in
                self?.handleStopFinished(outputURL: url)
            }
        }
    }

    private func handleStopFinished(outputURL: URL?) {
        guard state == .stopping else {
            return
        }

        let writerStatus = writer?.status
        let writerError = writer?.error?.localizedDescription

        resetWriterState()
        state = .idle
        isRecording = false
        pendingStopAfterStart = false

        if let writerError {
            print("[Recording] stop error:", writerError)
            onStopped?(nil)
            return
        }

        guard writerStatus == .completed else {
            print("[Recording] writer not completed:", String(describing: writerStatus))
            onStopped?(nil)
            return
        }

        guard let outputURL,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            print("[Recording] output file does not exist")
            onStopped?(nil)
            return
        }

        onStopped?(outputURL)
    }

    func forceReset() {
        pendingStopAfterStart = false
        isRecording = false
        state = .idle

        videoInput?.markAsFinished()
        writer?.cancelWriting()
        resetWriterState()
    }

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

    private func resetWriterState() {
        writer = nil
        videoInput = nil
        adaptor = nil
        outputURL = nil
        didStartSession = false
    }

    private func makeOutputURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "beytail_\(timestamp)_\(UUID().uuidString.prefix(8)).mp4"

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
    }

    private func normalizedOrientation(_ orientation: UIDeviceOrientation) -> UIDeviceOrientation {
        switch orientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return orientation
        default:
            return .portrait
        }
    }

    private func preferredTransform(for orientation: UIDeviceOrientation) -> CGAffineTransform {
        switch orientation {
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: .pi)
        default:
            return .identity
        }
    }
}
