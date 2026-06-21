import Foundation
import Metal
import MetalKit
import CoreVideo
import AVFoundation
import simd

/// 渲染核心（對應 Android CameraGLThread）：
///   相機 BGRA buffer → Metal 紋理 → 離屏紋理（相機 aspect-fill + 特效）
///   → blit 到螢幕；錄影時另外以「中央裁切 + 烘焙旋轉」blit 進 writer 的 pixel buffer。
///   推論節流：每 N 幀 YOLO、其餘 Kalman 補位（30fps N=2、60fps N=4）。
final class CameraRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let pipelines: PipelineLibrary
    let ctx: RenderContext
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    // 引擎（與 Android 對應）
    let inference = InferenceEngine()
    let tracker = BeybladeTracker()
    let trailEngine = TrailEffectEngine()

    // 特效實例
    private let genericEffect = GenericEffect()
    private lazy var customEffects: [EffectType: EffectRenderer] = [
        .wave:    WaveEffect(),
        .thunder: IronShieldEffect(),
        .vortex:  BladeEffect(),
        .dark:    IceShatterEffect(),
        .crimson: CrimsonLotusEffect(),
    ]

    var effectType: EffectType = .lightning {
        didSet { trailEngine.fadeDuration = effectType.fadeDuration }
    }

    // 最新相機幀（camera queue 寫入、render 讀取）
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestPTS = CMTime.zero
    private let bufferLock = NSLock()

    // 推論節流
    private var analyzerFrameCount = 0

    // 離屏場景紋理（= Android FBO）
    private var sceneTexture: MTLTexture?

    // 錄影
    let recording = RecordingManager()
    /// 實體方向（0/90/180/270），由 UI 的方向監聽更新
    var deviceOrientationDegrees = 0

    // HUD 回呼（主執行緒）
    var onHudUpdate: ((Float, InferenceHardware, Int) -> Void)?   // fps, hw, trackCount

    init(device: MTLDevice) throws {
        self.device = device
        self.pipelines = try PipelineLibrary(device: device)
        self.ctx = RenderContext(device: device, pipelines: pipelines)
        self.queue = device.makeCommandQueue()!
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // ── 相機幀進入（camera queue） ────────────────────────────────────────

    func onCameraFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        latestPTS = pts
        bufferLock.unlock()

        // 推論節流（同 Android analyzer：每 N 幀 YOLO，其餘 predictStep）
        analyzerFrameCount += 1
        let now = CACurrentMediaTime()
        if analyzerFrameCount % inference.inferenceFrameInterval == 0 {
            let detections = inference.infer(pixelBuffer: pixelBuffer)
            let tracked = tracker.update(detections)
            for r in tracked {
                trailEngine.addPoint(trackId: r.trackId, center: r.center,
                                     color: r.dominantColor, timestamp: now)
            }
            DispatchQueue.main.async { [self] in
                onHudUpdate?(inference.currentFps, inference.hardware, tracked.count)
            }
        } else {
            let stepScale = 2 / Float(inference.inferenceFrameInterval)
            for r in tracker.predictStep(stepScale: stepScale) {
                trailEngine.addPoint(trackId: r.trackId, center: r.center,
                                     color: r.dominantColor, timestamp: now)
            }
        }
    }

    // ── MTKViewDelegate ──────────────────────────────────────────────────

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildSceneTexture(width: Int(size.width), height: Int(size.height))
    }

    private func rebuildSceneTexture(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        sceneTexture = device.makeTexture(descriptor: desc)
        ctx.viewWidth = width
        ctx.viewHeight = height
    }

    func draw(in view: MTKView) {
        bufferLock.lock()
        let pixelBuffer = latestPixelBuffer
        let pts = latestPTS
        bufferLock.unlock()
        guard let pb = pixelBuffer,
              let scene = sceneTexture,
              let drawable = view.currentDrawable,
              let cameraTex = makeTexture(from: pb) else { return }

        // 幀時間倍率（特效以 30fps 為基準）
        ctx.dtScale = 30 / Float(view.preferredFramesPerSecond)
        ctx.time += (1.0 / 30.0) * ctx.dtScale
        if ctx.time > 120 { ctx.time -= 120 }

        // 相機 aspect-fill 裁切（同 Android quadScale）
        let camW = Float(CVPixelBufferGetWidth(pb))
        let camH = Float(CVPixelBufferGetHeight(pb))
        let camAspect = camW / camH
        let viewAspect = Float(ctx.viewWidth) / Float(ctx.viewHeight)
        if camAspect > viewAspect {
            ctx.quadScaleX = camAspect / viewAspect; ctx.quadScaleY = 1
        } else {
            ctx.quadScaleX = 1; ctx.quadScaleY = viewAspect / camAspect
        }

        let trackData = trailEngine.pointsByTrack(now: CACurrentMediaTime())

        guard let cmd = queue.makeCommandBuffer() else { return }

        // ── Pass 1：場景（相機 + 特效）→ 離屏紋理 ──
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: scenePass) {
            drawCameraQuad(enc, texture: cameraTex)
            (customEffects[effectType] ?? genericEffect)
                .draw(trackData: trackData, encoder: enc, ctx: ctx)
            // 通用特效的 effectType 寬度係數
            if customEffects[effectType] == nil {
                genericEffect.currentType = effectType
            }
            enc.endEncoding()
        }

        // ── Pass 2：離屏 → 螢幕 ──
        let screenPass = MTLRenderPassDescriptor()
        screenPass.colorAttachments[0].texture = drawable.texture
        screenPass.colorAttachments[0].loadAction = .dontCare
        screenPass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: screenPass) {
            drawBlit(enc, source: scene, quad: Self.fullQuad)
            enc.endEncoding()
        }

        // ── Pass 3：錄影（中央裁切 + 烘焙旋轉 → writer pixel buffer） ──
        var recordPB: CVPixelBuffer?
        if recording.isRecording, let outPB = recording.dequeuePixelBuffer(),
           let outTex = makeRenderTexture(from: outPB) {
            let recPass = MTLRenderPassDescriptor()
            recPass.colorAttachments[0].texture = outTex
            recPass.colorAttachments[0].loadAction = .dontCare
            recPass.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: recPass) {
                let quad = Self.recordQuad(
                    rotation: recording.contentRotation,
                    srcW: Float(ctx.viewWidth), srcH: Float(ctx.viewHeight),
                    dstW: Float(recording.outputWidth), dstH: Float(recording.outputHeight))
                drawBlit(enc, source: scene, quad: quad)
                enc.endEncoding()
            }
            recordPB = outPB
        }

        cmd.present(drawable)
        if let outPB = recordPB {
            cmd.addCompletedHandler { [recording] _ in
                recording.append(pixelBuffer: outPB, pts: pts)
            }
        }
        cmd.commit()
    }

    // ── 繪製輔助 ─────────────────────────────────────────────────────────

    private func drawCameraQuad(_ enc: MTLRenderCommandEncoder, texture: MTLTexture) {
        enc.setRenderPipelineState(pipelines.cameraQuad)
        var quad = Self.fullQuad
        enc.setVertexBytes(&quad, length: MemoryLayout<Float>.size * quad.count, index: 0)
        var u = ctx.uniforms
        enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawBlit(_ enc: MTLRenderCommandEncoder, source: MTLTexture, quad: [Float]) {
        enc.setRenderPipelineState(pipelines.blit)
        var q = quad
        enc.setVertexBytes(&q, length: MemoryLayout<Float>.size * q.count, index: 0)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func makeTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        return cvTex.flatMap(CVMetalTextureGetTexture)
    }

    private func makeRenderTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        makeTexture(from: pb)   // Metal-compatible pool buffer 可直接作 render target
    }

    // ── Quad 幾何 ────────────────────────────────────────────────────────
    // Metal 紋理座標 v=0 在上（與 GL 相反）— fullQuad 直接 1:1 映射

    static let fullQuad: [Float] = [
        // x, y, u, v
        -1, -1, 0, 1,
         1, -1, 1, 1,
        -1,  1, 0, 0,
         1,  1, 1, 0,
    ]

    /// 錄影 quad：中央裁切 + 旋轉烘焙（對應 Android startRecording 的 texcoords 計算）
    static func recordQuad(rotation: Int, srcW: Float, srcH: Float,
                           dstW: Float, dstH: Float) -> [Float] {
        let rotated = rotation == 90 || rotation == 270
        let srcWr = rotated ? srcH : srcW
        let srcHr = rotated ? srcW : srcH
        let targetAspect = dstW / dstH
        let srcAspect = srcWr / srcHr
        var u0: Float = 0, u1: Float = 1, v0: Float = 0, v1: Float = 1
        if srcAspect > targetAspect {
            let frac = targetAspect / srcAspect
            let lo = (1 - frac) / 2, hi = 1 - lo
            if rotated { v0 = lo; v1 = hi } else { u0 = lo; u1 = hi }
        } else if srcAspect < targetAspect {
            let frac = srcAspect / targetAspect
            let lo = (1 - frac) / 2, hi = 1 - lo
            if rotated { u0 = lo; u1 = hi } else { v0 = lo; v1 = hi }
        }
        // 各角 texcoord（Metal v=0 在上；映射方向與 Android GL 版對應翻轉後相同）
        switch rotation {
        case 90:
            return [-1, -1, u1, v1,   1, -1, u1, v0,   -1, 1, u0, v1,   1, 1, u0, v0]
        case 270:
            return [-1, -1, u0, v0,   1, -1, u0, v1,   -1, 1, u1, v0,   1, 1, u1, v1]
        case 180:
            return [-1, -1, u1, v0,   1, -1, u0, v0,   -1, 1, u1, v1,   1, 1, u0, v1]
        default:
            return [-1, -1, u0, v1,   1, -1, u1, v1,   -1, 1, u0, v0,   1, 1, u1, v0]
        }
    }
}
