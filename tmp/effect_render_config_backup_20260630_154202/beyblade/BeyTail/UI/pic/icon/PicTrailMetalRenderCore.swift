import Foundation
@preconcurrency import MetalKit

/// Compatibility adapter for the existing recording and offline-video paths.
///
/// The previous implementation generated approximate Pic geometry. This
/// replacement encodes the same MetalEffect classes used by the live overlay,
/// so preview, recording and offline rendering share one effect implementation.
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
    private var effectCache: [EffectType: MetalEffect] = [:]
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
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: passDescriptor
        ) else {
            throw RenderError.renderEncoderUnavailable
        }

        encoder.label = "BeyTailSharedMetalEffectEncoder"
        encoder.setCullMode(.none)

        let drawableSize = CGSize(
            width: max(viewportSize.width * pixelScale, 1),
            height: max(viewportSize.height * pixelScale, 1)
        )
        let deltaTime = lastFrameTime > 0
            ? max(min(now - lastFrameTime, 0.1), 1.0 / 240.0)
            : 1.0 / 30.0
        lastFrameTime = now

        renderContext.update(
            drawableSize: drawableSize,
            deltaTime: deltaTime
        )
        renderContext.beginFrame(
            commandBuffer: commandBuffer,
            encoder: encoder
        )

        let resampledTracks = TrailResampler.resample(
            trackData,
            drawableSize: drawableSize,
            spacingPixels: 5
        )
        let renderer = metalEffect(for: effect)
        renderer.prepareIfNeeded(context: renderContext)
        renderer.draw(
            trackData: resampledTracks,
            context: renderContext,
            effectType: effect
        )

        // The production app passes an empty box list. The parameter remains in
        // the signature so PicTrailRenderer, RecordingManager and offline video
        // rendering do not require API changes.
        _ = debugBoundingBoxes

        renderContext.endFrame()
        encoder.endEncoding()
    }

    private func metalEffect(for type: EffectType) -> MetalEffect {
        if let cached = effectCache[type] {
            return cached
        }
        let effect = MetalEffectFactory.makeEffect(for: type)
        effectCache[type] = effect
        return effect
    }
}
