import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import UIKit

/// 將相簿影片逐幀執行物件偵測與軌跡繪製，輸出可儲存或分享的 MP4。
///
/// 此處刻意沿用主專案既有的：
/// - InferenceEngine
/// - BeybladeTracker
/// - TrailEffectEngine
/// - EffectType
///
/// 不引入 tmp 專案的 Metal renderer，避免大幅改動現有架構。
final class VideoRenderProcessor: @unchecked Sendable {

    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onCompleted: (@MainActor @Sendable (URL) -> Void)?
    var onFailed: (@MainActor @Sendable (String) -> Void)?

    private let stateLock = NSLock()
    private var isCancelled = false

    func process(inputURL: URL, effect: EffectType) {
        setCancelled(false)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            do {
                let outputURL = try await self.render(
                    inputURL: inputURL,
                    effect: effect
                )

                guard !self.cancelled else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }

                await MainActor.run {
                    self.onProgress?(1.0)
                    self.onCompleted?(outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.onFailed?("處理已取消")
                }
            } catch {
                await MainActor.run {
                    self.onFailed?(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        setCancelled(true)
    }

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    private func setCancelled(_ value: Bool) {
        stateLock.lock()
        isCancelled = value
        stateLock.unlock()
    }

    private func render(
        inputURL: URL,
        effect: EffectType
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw makeError("找不到影片軌")
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let outputWidth = evenDimension(naturalSize.width)
        let outputHeight = evenDimension(naturalSize.height)
        let fps = max(Double(nominalFPS), 1.0)
        let estimatedFrameCount = max(duration.seconds * fps, 1.0)

        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        videoOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(videoOutput) else {
            throw makeError("無法建立影片讀取器")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false

            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "beytail_render_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).mp4"
            )

        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: .mp4
        )

        let averageBitRate = calculateBitRate(
            width: outputWidth,
            height: outputHeight,
            fps: fps
        )

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: averageBitRate,
                    AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform

        guard writer.canAdd(videoInput) else {
            throw makeError("無法建立影片輸出器")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil
            )
            input.expectsMediaDataInRealTime = false

            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? makeError("無法開始輸出影片")
        }

        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? makeError("無法開始讀取影片")
        }

        writer.startSession(atSourceTime: .zero)

        let inference = InferenceEngine()
        let tracker = BeybladeTracker()
        let trailEngine = TrailEffectEngine()
        trailEngine.fadeDurationMs = effect.fadeDurationMs

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var frameIndex = 0

        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            try checkCancellation(
                reader: reader,
                writer: writer,
                outputURL: outputURL
            )

            guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = presentationTime.seconds.isFinite
                ? max(presentationTime.seconds, 0.0)
                : Double(frameIndex) / fps

            let trackedResults: [DetectionResult]

            if frameIndex.isMultiple(of: 2) {
                let detections = try inference.inferSynchronously(
                    pixelBuffer: sourcePixelBuffer,
                    orientation: .up,
                    timestamp: timestamp
                )
                trackedResults = tracker.update(detections)
            } else {
                trackedResults = tracker.predictStep()
            }

            for result in trackedResults where result.trackId > 0 {
                trailEngine.addPoint(
                    trackId: result.trackId,
                    center: result.center,
                    color: result.dominantColor,
                    timestamp: timestamp
                )
            }

            try await waitUntilReady(
                videoInput,
                reader: reader,
                writer: writer,
                outputURL: outputURL
            )

            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw makeError("無法取得輸出 PixelBuffer pool")
            }

            var renderedPixelBuffer: CVPixelBuffer?
            let createStatus = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pixelBufferPool,
                &renderedPixelBuffer
            )

            guard createStatus == kCVReturnSuccess,
                  let renderedPixelBuffer else {
                throw makeError("無法建立輸出畫格")
            }

            renderSourceFrame(
                sourcePixelBuffer,
                into: renderedPixelBuffer,
                width: outputWidth,
                height: outputHeight,
                context: ciContext,
                colorSpace: colorSpace
            )

            try drawTrails(
                trailEngine.getPointsByTrack(now: timestamp),
                effect: effect,
                into: renderedPixelBuffer,
                width: outputWidth,
                height: outputHeight
            )

            guard adaptor.append(
                renderedPixelBuffer,
                withPresentationTime: presentationTime
            ) else {
                throw writer.error ?? makeError("寫入影片畫格失敗")
            }

            frameIndex += 1

            if frameIndex.isMultiple(of: 3) {
                let value = min(
                    Double(frameIndex) / estimatedFrameCount,
                    0.98
                )

                await MainActor.run {
                    onProgress?(value)
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? makeError("讀取影片失敗")
        }

        videoInput.markAsFinished()

        if let audioOutput,
           let audioInput {
            while let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                try checkCancellation(
                    reader: reader,
                    writer: writer,
                    outputURL: outputURL
                )

                try await waitUntilReady(
                    audioInput,
                    reader: reader,
                    writer: writer,
                    outputURL: outputURL
                )

                guard audioInput.append(sampleBuffer) else {
                    throw writer.error ?? makeError("寫入音訊失敗")
                }
            }

            audioInput.markAsFinished()
        }

        try checkCancellation(
            reader: reader,
            writer: writer,
            outputURL: outputURL
        )

        await finishWriting(writer)

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw writer.error ?? makeError("影片輸出失敗")
        }

        return outputURL
    }

    private func renderSourceFrame(
        _ source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        width: Int,
        height: Int,
        context: CIContext,
        colorSpace: CGColorSpace
    ) {
        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent

        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )

        let scaleX = CGFloat(width) / max(extent.width, 1.0)
        let scaleY = CGFloat(height) / max(extent.height, 1.0)

        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: scaleX,
                y: scaleY
            )
        )

        context.render(
            scaled,
            to: destination,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            ),
            colorSpace: colorSpace
        )
    }

    private func drawTrails(
        _ tracks: [Int: [(TrailPoint, Float)]],
        effect: EffectType,
        into pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw makeError("無法存取輸出畫格記憶體")
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw makeError("無法建立軌跡繪圖 Context")
        }

        // 將 Core Graphics 的左下角原點轉成與 UIKit/Vision 相同的左上角原點。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let canvas = CGSize(
            width: CGFloat(width),
            height: CGFloat(height)
        )

        for points in tracks.values {
            drawTrail(
                points,
                effect: effect,
                canvas: canvas,
                context: context
            )
        }
    }

    private func drawTrail(
        _ points: [(TrailPoint, Float)],
        effect: EffectType,
        canvas: CGSize,
        context: CGContext
    ) {
        guard points.count >= 2 else {
            return
        }

        let glowWidth = CGFloat(14.0 * effect.glowWidthMult)
        let coreWidth = CGFloat(4.0 * effect.coreWidthMult)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let alpha = CGFloat((previous.1 + current.1) / 2.0)

            let from = CGPoint(
                x: previous.0.center.x * canvas.width,
                y: previous.0.center.y * canvas.height
            )

            let to = CGPoint(
                x: current.0.center.x * canvas.width,
                y: current.0.center.y * canvas.height
            )

            let color = effect.colorOverride ?? current.0.color

            context.beginPath()
            context.setLineCap(.round)
            context.setStrokeColor(
                color.withAlphaComponent(alpha * 0.35).cgColor
            )
            context.setLineWidth(glowWidth)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

            context.beginPath()
            context.setStrokeColor(
                color.withAlphaComponent(alpha * 0.90).cgColor
            )
            context.setLineWidth(coreWidth)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }
    }

    private func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputURL: URL
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try checkCancellation(
                reader: reader,
                writer: writer,
                outputURL: outputURL
            )

            if writer.status == .failed {
                throw writer.error ?? makeError("影片輸出器發生錯誤")
            }

            try await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    private func checkCancellation(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputURL: URL
    ) throws {
        guard cancelled else {
            return
        }

        reader.cancelReading()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
        throw CancellationError()
    }

    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private func evenDimension(_ value: CGFloat) -> Int {
        let integer = max(Int(abs(value).rounded(.down)), 2)
        return max((integer / 2) * 2, 2)
    }

    private func calculateBitRate(
        width: Int,
        height: Int,
        fps: Double
    ) -> Int {
        let estimated = Double(width * height) * fps * 0.14
        return Int(min(max(estimated, 4_000_000), 18_000_000))
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "BeyTail.VideoRenderProcessor",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
