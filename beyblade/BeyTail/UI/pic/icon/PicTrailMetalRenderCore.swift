import Foundation
@preconcurrency import MetalKit

/// Pic 特效共用的 Metal 編碼核心。
///
/// 即時預覽、即時錄影與影片庫離線渲染都透過這個類別建立幾何並編碼，
/// 因此三條輸出路徑會共用同一個 PicTrailSceneBuilder 與同一組 Metal shader。
final class PicTrailMetalRenderCore {

    enum RenderError: LocalizedError {
        case defaultLibraryUnavailable
        case shaderFunctionUnavailable(String)
        case renderEncoderUnavailable

        var errorDescription: String? {
            switch self {
            case .defaultLibraryUnavailable:
                return "無法載入預設 Metal library，請確認 PicTrailShaders.metal 已加入 App Target"

            case .shaderFunctionUnavailable(let name):
                return "找不到 Metal shader function：\(name)"

            case .renderEncoderUnavailable:
                return "無法建立 Metal render encoder"
            }
        }
    }

    private struct DynamicVertexBuffer {
        private(set) var buffer: MTLBuffer?
        private(set) var capacity = 0

        mutating func upload<T>(
            _ values: [T],
            device: MTLDevice,
            label: String
        ) -> MTLBuffer? {
            guard !values.isEmpty else {
                return nil
            }

            let byteCount = values.count * MemoryLayout<T>.stride

            if buffer == nil || capacity < byteCount {
                var newCapacity = max(capacity, 4_096)

                while newCapacity < byteCount {
                    newCapacity *= 2
                }

                guard let newBuffer = device.makeBuffer(
                    length: newCapacity,
                    options: .storageModeShared
                ) else {
                    return nil
                }

                newBuffer.label = label
                buffer = newBuffer
                capacity = newCapacity
            }

            guard let buffer else {
                return nil
            }

            values.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else {
                    return
                }

                buffer.contents().copyMemory(
                    from: UnsafeRawPointer(baseAddress),
                    byteCount: byteCount
                )
            }

            return buffer
        }
    }

    private let device: MTLDevice
    private let ribbonPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    private let sceneBuilder = PicTrailSceneBuilder()

    private var ribbonVertexBuffer = DynamicVertexBuffer()
    private var spriteVertexBuffer = DynamicVertexBuffer()

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat
    ) throws {
        self.device = device

        self.ribbonPipeline = try Self.makePipeline(
            device: device,
            colorPixelFormat: colorPixelFormat,
            vertexFunctionName: "picRibbonVertex",
            fragmentFunctionName: "picRibbonFragment"
        )

        self.spritePipeline = try Self.makePipeline(
            device: device,
            colorPixelFormat: colorPixelFormat,
            vertexFunctionName: "picSpriteVertex",
            fragmentFunctionName: "picSpriteFragment"
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
        let geometry = sceneBuilder.build(
            effect: effect,
            trackData: trackData,
            debugBoundingBoxes: debugBoundingBoxes,
            viewportSize: viewportSize,
            now: now
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: passDescriptor
        ) else {
            throw RenderError.renderEncoderUnavailable
        }

        encoder.label = "PicTrailRenderEncoder"
        encoder.setCullMode(.none)

        var uniforms = PicUniforms(
            viewportSize: SIMD2(
                Float(viewportSize.width),
                Float(viewportSize.height)
            ),
            time: Float(
                now.truncatingRemainder(dividingBy: 4_096)
            ),
            pixelScale: Float(pixelScale)
        )

        if let ribbonBuffer = ribbonVertexBuffer.upload(
            geometry.ribbonVertices,
            device: device,
            label: "PicTrailRibbonVertexBuffer"
        ) {
            encoder.setRenderPipelineState(ribbonPipeline)

            encoder.setVertexBuffer(
                ribbonBuffer,
                offset: 0,
                index: 0
            )

            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PicUniforms>.stride,
                index: 1
            )

            for range in geometry.ribbonRanges where range.count >= 4 {
                encoder.drawPrimitives(
                    type: .triangleStrip,
                    vertexStart: range.start,
                    vertexCount: range.count
                )
            }
        }

        if let spriteBuffer = spriteVertexBuffer.upload(
            geometry.spriteVertices,
            device: device,
            label: "PicTrailSpriteVertexBuffer"
        ) {
            encoder.setRenderPipelineState(spritePipeline)

            encoder.setVertexBuffer(
                spriteBuffer,
                offset: 0,
                index: 0
            )

            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PicUniforms>.stride,
                index: 1
            )

            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: geometry.spriteVertices.count
            )
        }

        encoder.endEncoding()
    }

    private static func makePipeline(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        vertexFunctionName: String,
        fragmentFunctionName: String
    ) throws -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary() else {
            throw RenderError.defaultLibraryUnavailable
        }

        guard let vertexFunction = library.makeFunction(
            name: vertexFunctionName
        ) else {
            throw RenderError.shaderFunctionUnavailable(
                vertexFunctionName
            )
        }

        guard let fragmentFunction = library.makeFunction(
            name: fragmentFunctionName
        ) else {
            throw RenderError.shaderFunctionUnavailable(
                fragmentFunctionName
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label =
            "\(vertexFunctionName)-\(fragmentFunctionName)"

        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        if let attachment = descriptor.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add

            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor =
                .oneMinusSourceAlpha

            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor =
                .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(
            descriptor: descriptor
        )
    }
}
