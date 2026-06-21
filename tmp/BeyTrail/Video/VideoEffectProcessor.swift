import Foundation
import AVFoundation
import Metal
import CoreVideo
import Photos

/// 離線影片特效處理（對應 Android VideoEffectProcessor）：
///   AVAssetReader 解碼（BGRA）→ 推論（每 2 幀 + Kalman 補位）→ Metal 合成特效
///   → AVAssetWriter 編碼（1080p 上限、原 fps、8/12Mbps）；音軌 passthrough 直拷；
///   rotation 以 preferredTransform 透傳。完成後存暫存檔，預覽頁確認再入相簿。
final class VideoEffectProcessor {

    var onProgress: ((Float) -> Void)?      // 主執行緒
    var onDone: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private var cancelled = false
    func cancel() { cancelled = true }

    private let device: MTLDevice
    private let pipelines: PipelineLibrary
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    init() throws {
        device = MTLCreateSystemDefaultDevice()!
        pipelines = try PipelineLibrary(device: device)
        queue = device.makeCommandQueue()!
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func process(asset inputURL: URL, effect: EffectType) {
        cancelled = false
        Task.detached(priority: .userInitiated) { [self] in
            do { try await run(inputURL: inputURL, effect: effect) }
            catch {
                await MainActor.run { onError?(error.localizedDescription) }
            }
        }
    }

    private func run(inputURL: URL, effect: EffectType) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw err("找不到影片軌")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let totalFrames = max(1, Float(duration.seconds) * max(fps, 1))

        // 1080p 上限（顯示方向：transform 決定長短邊）
        let srcW = Float(naturalSize.width), srcH = Float(naturalSize.height)
        let rotated = abs(transform.b) == 1 && abs(transform.c) == 1
        let dispW = rotated ? srcH : srcW
        let dispH = rotated ? srcW : srcH
        let scale = min(1920 / max(dispW, dispH), 1080 / min(dispW, dispH), 1)
        let outW = Int(srcW * scale) / 2 * 2
        let outH = Int(srcH * scale) / 2 * 2

        // ── Reader ──
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA,
                             kCVPixelBufferMetalCompatibilityKey as String: true])
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let at = audioTrack {
            let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil) // passthrough
            reader.add(ao)
            audioOut = ao
        }

        // ── Writer ──
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beyblade_fx_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: fps > 31 ? 12_000_000 : 8_000_000
            ]
        ])
        vIn.transform = transform   // rotation metadata 透傳
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
                kCVPixelBufferMetalCompatibilityKey as String: true])
        var aIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil) // passthrough
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            aIn = a
        }

        guard reader.startReading(), writer.startWriting() else {
            throw err("無法開始處理")
        }
        writer.startSession(atSourceTime: .zero)

        // ── 引擎（獨立實例） ──
        let inference = InferenceEngine()
        let tracker = BeybladeTracker()
        let trail = TrailEffectEngine(fadeDuration: effect.fadeDuration)
        let ctx = RenderContext(device: device, pipelines: pipelines)
        ctx.viewWidth = outW
        ctx.viewHeight = outH
        ctx.quadScaleX = 1; ctx.quadScaleY = 1
        ctx.dtScale = 30 / max(fps, 1)

        let genericEffect = GenericEffect()
        genericEffect.currentType = effect
        let custom: [EffectType: EffectRenderer] = [
            .wave: WaveEffect(), .thunder: IronShieldEffect(),
            .vortex: BladeEffect(), .dark: IceShatterEffect(),
            .crimson: CrimsonLotusEffect()]
        let renderer: EffectRenderer = custom[effect] ?? genericEffect

        // ── 影片幀迴圈 ──
        var frameIndex = 0
        while !cancelled {
            guard let sample = videoOut.copyNextSampleBuffer() else { break }
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ptsSec = pts.seconds

            // 推論（每 2 幀 + Kalman 補位，同即時管線）
            if frameIndex % 2 == 0 {
                let tracked = tracker.update(inference.infer(pixelBuffer: pb))
                for r in tracked {
                    trail.addPoint(trackId: r.trackId, center: r.center,
                                   color: r.dominantColor, timestamp: ptsSec)
                }
            } else {
                for r in tracker.predictStep() {
                    trail.addPoint(trackId: r.trackId, center: r.center,
                                   color: r.dominantColor, timestamp: ptsSec)
                }
            }
            ctx.time = Float(ptsSec).truncatingRemainder(dividingBy: 120)

            // 渲染：影片幀 + 特效 → writer pixel buffer
            while !vIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw err("buffer pool 失敗") }
            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let outBuffer = outPB,
                  let srcTex = makeTexture(pb),
                  let dstTex = makeTexture(outBuffer) else { throw err("貼圖失敗") }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dstTex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
                throw err("encoder 失敗")
            }
            // 影片幀（1:1，無裁切）
            enc.setRenderPipelineState(pipelines.blit)
            var quad = CameraRenderer.fullQuad
            enc.setVertexBytes(&quad, length: MemoryLayout<Float>.size * quad.count, index: 0)
            enc.setFragmentTexture(srcTex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // 特效
            renderer.draw(trackData: trail.pointsByTrack(now: ptsSec),
                          encoder: enc, ctx: ctx)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            adaptor.append(outBuffer, withPresentationTime: pts)
            frameIndex += 1
            let frac = min(0.97, Float(frameIndex) / totalFrames * 0.97)
            await MainActor.run { onProgress?(frac) }
        }
        vIn.markAsFinished()

        // ── 音軌直拷 ──
        if let audioOut, let aIn {
            while let sample = audioOut.copyNextSampleBuffer(), !cancelled {
                while !aIn.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                aIn.append(sample)
            }
            aIn.markAsFinished()
        }

        reader.cancelReading()
        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            await MainActor.run { onError?("已取消") }
            return
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? err("輸出失敗")
        }
        await MainActor.run {
            onProgress?(1)
            onDone?(outputURL)
        }
    }

    private func makeTexture(_ pb: CVPixelBuffer) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        return cvTex.flatMap(CVMetalTextureGetTexture)
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "BeyTrail", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
