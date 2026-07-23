@preconcurrency import AVFoundation
import UIKit
import Photos

private struct RecordingFramePayload: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let trackData: [Int: [(TrailPoint, Float)]]
    let effect: EffectType
    let now: TimeInterval
}

private final class RecordingWriterWorker: @unchecked Sendable {

    private let queue = DispatchQueue(
        label: "com.beytail.recording.composited.writer",
        qos: .userInitiated
    )

    /// 最多保留兩個待合成影格，避免 Metal 合成速度落後時記憶體持續增長。
    private let frameSlots = DispatchSemaphore(value: 2)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var compositor: PicTrailPixelBufferCompositor?

    private var outputURL: URL?
    private var requestedOrientation: UIDeviceOrientation = .portrait

    private var didStartSession = false
    private var acceptingFrames = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var appendedFrameCount = 0
    private var droppedFrameCount = 0

    private var fatalErrorHandler: (@Sendable (String) -> Void)?

    func prepare(
        outputURL: URL,
        orientation: UIDeviceOrientation,
        fatalErrorHandler: @escaping @Sendable (String) -> Void
    ) -> Bool {
        queue.sync {
            resetOnQueue(cancelWriter: true)

            self.outputURL = outputURL
            self.requestedOrientation = orientation
            self.fatalErrorHandler = fatalErrorHandler
            self.acceptingFrames = true

            return true
        }
    }

    func append(_ payload: RecordingFramePayload) {
        guard frameSlots.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                self?.droppedFrameCount += 1
            }
            return
        }

        queue.async { [weak self, payload] in
            defer {
                self?.frameSlots.signal()
            }

            guard let self,
                  self.acceptingFrames else {
                return
            }

            do {
                try self.appendOnQueue(payload)
            } catch {
                self.failOnQueue(error.localizedDescription)
            }
        }
    }

    func finish(
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            self.acceptingFrames = false

            guard let writer = self.writer,
                  let videoInput = self.videoInput,
                  let outputURL = self.outputURL,
                  self.didStartSession,
                  self.appendedFrameCount > 0 else {
                print(
                    "[Recording] stop failed: no composited frames were appended"
                )
                self.resetOnQueue(cancelWriter: true)
                completion(nil)
                return
            }

            let duration: Double
            if let firstPresentationTime = self.firstPresentationTime,
               let lastPresentationTime = self.lastPresentationTime {
                duration = max(
                    0,
                    CMTimeGetSeconds(
                        CMTimeSubtract(
                            lastPresentationTime,
                            firstPresentationTime
                        )
                    )
                )
            } else {
                duration = 0
            }

            print(
                "[Recording] finishing composited video:",
                "frames=\(self.appendedFrameCount)",
                "dropped=\(self.droppedFrameCount)",
                "duration=\(String(format: "%.2f", duration))"
            )

            videoInput.markAsFinished()

            writer.finishWriting { [weak self, outputURL] in
                guard let self else {
                    completion(nil)
                    return
                }

                self.queue.async {
                    let status = writer.status
                    let errorMessage = writer.error?.localizedDescription

                    self.resetOnQueue(cancelWriter: false)

                    if let errorMessage {
                        print(
                            "[Recording] finish error:",
                            errorMessage
                        )
                        completion(nil)
                        return
                    }

                    guard status == .completed,
                          FileManager.default.fileExists(
                            atPath: outputURL.path
                          ) else {
                        print(
                            "[Recording] writer status:",
                            status.rawValue
                        )
                        completion(nil)
                        return
                    }

                    print(
                        "[Recording] composited video completed:",
                        outputURL.path
                    )
                    completion(outputURL)
                }
            }
        }
    }

    func cancel() {
        queue.sync {
            resetOnQueue(cancelWriter: true)
        }
    }

    private func appendOnQueue(
        _ payload: RecordingFramePayload
    ) throws {
        let sampleBuffer = payload.sampleBuffer

        guard CMSampleBufferDataIsReady(sampleBuffer),
              let sourcePixelBuffer =
                CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription =
                CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        if writer == nil {
            try configureWriter(
                formatDescription: formatDescription
            )
        }

        guard let writer,
              let videoInput,
              let adaptor,
              writer.status == .writing else {
            return
        }

        let presentationTime =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard presentationTime.isValid,
              !presentationTime.isIndefinite else {
            return
        }

        if let lastPresentationTime,
           CMTimeCompare(
            presentationTime,
            lastPresentationTime
           ) <= 0 {
            return
        }

        if !didStartSession {
            writer.startSession(
                atSourceTime: presentationTime
            )
            didStartSession = true
            firstPresentationTime = presentationTime
        }

        guard videoInput.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw makeError(
                "無法取得錄影輸出 PixelBuffer pool"
            )
        }

        var destinationPixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pixelBufferPool,
            &destinationPixelBuffer
        )

        guard createStatus == kCVReturnSuccess,
              let destinationPixelBuffer else {
            throw makeError(
                "無法建立錄影輸出 PixelBuffer：\(createStatus)"
            )
        }

        guard let compositor else {
            throw makeError("Metal 特效合成器尚未建立")
        }

        try compositor.render(
            source: sourcePixelBuffer,
            into: destinationPixelBuffer,
            trackData: payload.trackData,
            effect: payload.effect,
            now: payload.now
        )

        guard adaptor.append(
            destinationPixelBuffer,
            withPresentationTime: presentationTime
        ) else {
            throw writer.error ??
                makeError("寫入合成後錄影影格失敗")
        }

        appendedFrameCount += 1
        lastPresentationTime = presentationTime

        if appendedFrameCount.isMultiple(of: 30),
           let firstPresentationTime {
            let duration = CMTimeGetSeconds(
                CMTimeSubtract(
                    presentationTime,
                    firstPresentationTime
                )
            )

            print(
                "[Recording] composited frames:",
                appendedFrameCount,
                "duration:",
                String(format: "%.2f", duration),
                "dropped:",
                droppedFrameCount
            )
        }
    }

    private func configureWriter(
        formatDescription: CMFormatDescription
    ) throws {
        guard let outputURL else {
            throw makeError("找不到錄影輸出路徑")
        }

        if FileManager.default.fileExists(
            atPath: outputURL.path
        ) {
            try FileManager.default.removeItem(
                at: outputURL
            )
        }

        let dimensions =
            CMVideoFormatDescriptionGetDimensions(
                formatDescription
            )

        let width = evenDimension(
            Int(dimensions.width)
        )
        let height = evenDimension(
            Int(dimensions.height)
        )

        guard width > 0, height > 0 else {
            throw makeError(
                "無效的錄影尺寸：\(width)x\(height)"
            )
        }

        let writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: .mp4
        )

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:
                    recommendedBitRate(
                        width: width,
                        height: height
                    ),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey:
                    AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )

        input.expectsMediaDataInRealTime = true
        input.transform = preferredTransform(
            for: requestedOrientation,
            sourceWidth: width,
            sourceHeight: height
        )

        guard writer.canAdd(input) else {
            throw makeError(
                "無法加入錄影 video input"
            )
        }

        writer.add(input)

        let adaptor =
            AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
            )

        guard writer.startWriting() else {
            throw writer.error ??
                makeError("無法開始寫入錄影")
        }

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.compositor =
            try PicTrailPixelBufferCompositor()

        print(
            "[Recording] composited writer configured:",
            "size=\(width)x\(height)",
            "orientation=\(requestedOrientation.rawValue)"
        )
    }

    private func failOnQueue(_ message: String) {
        guard acceptingFrames ||
              writer != nil else {
            return
        }

        print(
            "[Recording] composited recording failed:",
            message
        )

        let handler = fatalErrorHandler
        resetOnQueue(cancelWriter: true)
        handler?(message)
    }

    private func resetOnQueue(
        cancelWriter: Bool
    ) {
        acceptingFrames = false

        if cancelWriter,
           let writer,
           writer.status == .writing {
            videoInput?.markAsFinished()
            writer.cancelWriting()
        }

        writer = nil
        videoInput = nil
        adaptor = nil
        compositor = nil
        outputURL = nil

        didStartSession = false
        firstPresentationTime = nil
        lastPresentationTime = nil
        appendedFrameCount = 0
        droppedFrameCount = 0
        fatalErrorHandler = nil
    }

    private func evenDimension(_ value: Int) -> Int {
        let normalized = max(abs(value), 2)
        return max((normalized / 2) * 2, 2)
    }

    private func recommendedBitRate(
        width: Int,
        height: Int
    ) -> Int {
        let estimated =
            Double(width * height) * 60.0 * 0.14

        return Int(
            min(
                max(estimated, 6_000_000),
                24_000_000
            )
        )
    }

    private func preferredTransform(
        for orientation: UIDeviceOrientation,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGAffineTransform {
        let sourceIsPortrait =
            sourceHeight >= sourceWidth

        guard sourceIsPortrait else {
            switch orientation {
            case .portrait:
                return CGAffineTransform(
                    rotationAngle: .pi / 2
                )

            case .portraitUpsideDown:
                return CGAffineTransform(
                    rotationAngle: -.pi / 2
                )

            case .landscapeLeft:
                return CGAffineTransform(
                    rotationAngle: .pi
                )

            case .landscapeRight:
                return .identity

            default:
                return .identity
            }
        }

        switch orientation {
        case .portraitUpsideDown:
            return CGAffineTransform(
                rotationAngle: .pi
            )

        case .landscapeLeft:
            return CGAffineTransform(
                rotationAngle: -.pi / 2
            )

        case .landscapeRight:
            return CGAffineTransform(
                rotationAngle: .pi / 2
            )

        default:
            return .identity
        }
    }

    private func makeError(
        _ message: String
    ) -> NSError {
        NSError(
            domain: "BeyTail.RecordingWriterWorker",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }
}

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

    private let worker = RecordingWriterWorker()
    private var pendingStopAfterStart = false

    var onStarted: ((Bool) -> Void)?
    var onStopped: ((URL?) -> Void)?

    // MARK: - Start

    func startRecording(
        deviceOrientation: UIDeviceOrientation
    ) {
        switch state {
        case .idle:
            break

        case .starting:
            print(
                "[Recording] start ignored: already starting"
            )
            return

        case .recording:
            print(
                "[Recording] start ignored: already recording"
            )
            onStarted?(true)
            return

        case .stopping:
            print(
                "[Recording] start ignored: still stopping"
            )
            onStarted?(false)
            return
        }

        state = .starting
        isRecording = false
        pendingStopAfterStart = false

        let orientation =
            normalizedOrientation(deviceOrientation)
        let outputURL = makeOutputURL()

        let prepared = worker.prepare(
            outputURL: outputURL,
            orientation: orientation,
            fatalErrorHandler: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    print(
                        "[Recording] worker fatal error:",
                        message
                    )

                    self.state = .idle
                    self.isRecording = false
                    self.pendingStopAfterStart = false
                    self.onStopped?(nil)
                }
            }
        )

        guard prepared else {
            state = .idle
            isRecording = false
            onStarted?(false)
            return
        }

        state = .recording
        isRecording = true

        print(
            "[Recording] composited recording ready:",
            orientation.rawValue
        )

        onStarted?(true)

        if pendingStopAfterStart {
            pendingStopAfterStart = false
            stopRecording()
        }
    }

    // MARK: - Append composited camera frame

    func append(
        sampleBuffer: CMSampleBuffer,
        trackData: [Int: [(TrailPoint, Float)]],
        effect: EffectType,
        now: TimeInterval
    ) {
        guard state == .recording,
              isRecording else {
            return
        }

        worker.append(
            RecordingFramePayload(
                sampleBuffer: sampleBuffer,
                trackData: trackData,
                effect: effect,
                now: now
            )
        )
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

        worker.finish { [weak self] outputURL in
            Task { @MainActor [weak self, outputURL] in
                guard let self,
                      self.state == .stopping else {
                    return
                }

                self.state = .idle
                self.isRecording = false
                self.pendingStopAfterStart = false
                self.onStopped?(outputURL)
            }
        }
    }

    // MARK: - Reset

    func forceReset() {
        print(
            "[Recording] forceReset, state:",
            state.rawValue
        )

        pendingStopAfterStart = false
        isRecording = false
        state = .idle
        worker.cancel()
    }

    // MARK: - Photo library

    func saveToPhotoLibrary(
        url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let status = PHPhotoLibrary.authorizationStatus(
            for: .addOnly
        )

        switch status {
        case .authorized, .limited:
            performSaveToPhotoLibrary(
                url: url,
                completion: completion
            )

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(
                for: .addOnly
            ) { [weak self, url] newStatus in
                Task { @MainActor [weak self, url, newStatus] in
                    guard let self else {
                        completion(false)
                        return
                    }

                    switch newStatus {
                    case .authorized, .limited:
                        self.performSaveToPhotoLibrary(
                            url: url,
                            completion: completion
                        )

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
            PHAssetChangeRequest
                .creationRequestForAssetFromVideo(
                    atFileURL: url
                )
        } completionHandler: { success, error in
            Task { @MainActor [success, error] in
                if let error {
                    print(
                        "[Recording] save error:",
                        error.localizedDescription
                    )
                }

                completion(success)
            }
        }
    }

    // MARK: - Helpers

    private func makeOutputURL() -> URL {
        let timestamp =
            Int(Date().timeIntervalSince1970)

        let fileName =
            "beytail_\(timestamp)_\(UUID().uuidString.prefix(8)).mp4"

        return FileManager.default
            .temporaryDirectory
            .appendingPathComponent(fileName)
    }

    private func normalizedOrientation(
        _ orientation: UIDeviceOrientation
    ) -> UIDeviceOrientation {
        switch orientation {
        case .portrait,
             .portraitUpsideDown,
             .landscapeLeft,
             .landscapeRight:
            return orientation

        default:
            return .portrait
        }
    }
}
