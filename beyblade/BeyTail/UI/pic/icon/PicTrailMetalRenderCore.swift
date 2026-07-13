import Foundation
@preconcurrency import MetalKit

/// 共用的 Metal 特效渲染核心。
///
/// 預覽、錄影及離線影片皆使用相同 MetalEffect 實作。
///
/// 每次只保留目前啟用的 renderer，切換特效時會：
/// 1. reset 前一個 renderer
/// 2. 捨棄前一個 renderer
/// 3. 建立新 renderer
/// 4. 重設幀時間
///
/// 因此 BladeMetalEffect 的火花、裂紋與劍氣狀態
/// 不會被基礎特效沿用。
final class PicTrailMetalRenderCore {
    enum RenderError: LocalizedError {
        case renderEncoderUnavailable

        var errorDescription: String? {
            switch self {
            case .renderEncoderUnavailable:
                return "無法建立 Metal render encoder"
            }
        }
    }

    private let renderContext: MetalRenderContext

    /// 目前正在使用的特效類型。
    private var activeEffectType: EffectType?

    /// 目前唯一保留的 renderer。
    private var activeRenderer: MetalEffect?

    private var lastFrameTime: TimeInterval = 0

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat
    ) throws {
        renderContext = MetalRenderContext(
            device: device,
            pixelFormat: colorPixelFormat
        )
    }

    func encode(
        effect: EffectType,
        trackData: [Int: [(TrailPoint, Float)]],
        debugBoundingBoxes: [(CGRect, Int)] = [],
        viewportSize: CGSize,
        now: TimeInterval,
        pixelScale: CGFloat,
        passDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws {
        /*
         必須先確認 renderer 是否切換。

         切換時 renderer(for:) 會將 lastFrameTime 歸零，
         讓新特效第一幀使用穩定的 deltaTime。
         */
        let renderer = renderer(for: effect)

        guard let encoder =
                commandBuffer.makeRenderCommandEncoder(
                    descriptor: passDescriptor
                ) else {
            throw RenderError.renderEncoderUnavailable
        }

        encoder.label =
            "BeyTailSharedMetalEffectEncoder"

        encoder.setCullMode(.none)

        let drawableSize = CGSize(
            width: max(
                viewportSize.width * pixelScale,
                1
            ),
            height: max(
                viewportSize.height * pixelScale,
                1
            )
        )

        let deltaTime: TimeInterval

        if lastFrameTime > 0 {
            deltaTime = max(
                min(now - lastFrameTime, 0.1),
                1.0 / 240.0
            )
        } else {
            deltaTime = 1.0 / 30.0
        }

        lastFrameTime = now

        renderContext.update(
            drawableSize: drawableSize,
            deltaTime: deltaTime
        )

        renderContext.applyRenderProfile(
            effect.trailRenderProfile
        )

        renderContext.beginFrame(
            commandBuffer: commandBuffer,
            encoder: encoder
        )

        let resampledTracks =
            TrailResampler.resample(
                trackData,
                drawableSize: drawableSize,
                spacingPixels: 5
            )

        renderer.prepareIfNeeded(
            context: renderContext
        )

        renderer.draw(
            trackData: resampledTracks,
            context: renderContext,
            effectType: effect
        )

        /*
         正式 App 通常傳入空的 debugBoundingBoxes。
         保留參數以維持既有 API。
         */
        _ = debugBoundingBoxes

        renderContext.endFrame()
        encoder.endEncoding()
    }

    /// 外部切換影片、重設追蹤或停止渲染時可以呼叫。
    func reset() {
        activeRenderer?.reset()
        activeRenderer = nil
        activeEffectType = nil
        lastFrameTime = 0
    }

    /// 取得目前 renderer。
    ///
    /// 不再使用 EffectType -> MetalEffect 的永久快取，
    /// 避免有狀態的粒子 renderer 長期保留。
    private func renderer(
        for type: EffectType
    ) -> MetalEffect {
        if activeEffectType == type,
           let activeRenderer {
            return activeRenderer
        }

        // 清除上一個特效的跨幀狀態。
        activeRenderer?.reset()

        // 捨棄上一個 renderer，建立新實例。
        let newRenderer =
            MetalEffectFactory.makeEffect(
                for: type
            )

        activeEffectType = type
        activeRenderer = newRenderer

        // 新特效第一幀重新計算時間。
        lastFrameTime = 0

        return newRenderer
    }
}
