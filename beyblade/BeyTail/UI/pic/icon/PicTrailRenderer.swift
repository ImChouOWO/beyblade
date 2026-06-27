import Foundation
@preconcurrency import MetalKit

@MainActor
final class PicTrailRenderer: NSObject, MTKViewDelegate {

    enum RendererError: LocalizedError {
        case commandQueueUnavailable
        case defaultLibraryUnavailable
        case shaderFunctionUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .commandQueueUnavailable:
                return "無法建立 Metal command queue"

            case .defaultLibraryUnavailable:
                return "無法載入預設 Metal library，請確認 PicTrailShaders.metal 已加入 Target"

            case .shaderFunctionUnavailable(let name):
                return "找不到 Metal shader function：\(name)"
            }
        }
    }

    /// setVertexBytes 只能傳遞少量資料。
    /// 軌跡與粒子頂點改用可重複使用的 MTLBuffer。
    private struct DynamicVertexBuffer {
        private(set) var buffer: MTLBuffer?
        private(set) var capacity: Int = 0

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

    private weak var owner: PicTrailOverlayView?

    private let commandQueue: MTLCommandQueue
    private let ribbonPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    private let sceneBuilder = PicTrailSceneBuilder()

    private var ribbonVertexBuffer = DynamicVertexBuffer()
    private var spriteVertexBuffer = DynamicVertexBuffer()

    init(view: PicTrailOverlayView) throws {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }

        self.owner = view
        self.commandQueue = commandQueue

        self.ribbonPipeline = try Self.makePipeline(
            device: device,
            view: view,
            vertexFunctionName: "picRibbonVertex",
            fragmentFunctionName: "picRibbonFragment"
        )

        self.spritePipeline = try Self.makePipeline(
            device: device,
            view: view,
            vertexFunctionName: "picSpriteVertex",
            fragmentFunctionName: "picSpriteFragment"
        )

        super.init()

        print("[METAL] PicTrailRenderer ready:", device.name)
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        // 幾何座標以 view.bounds 的 point 為基準，不需在此更新投影矩陣。
    }

    func draw(in view: MTKView) {
        guard let owner,
              let device = view.device,
              let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              owner.bounds.width > 1,
              owner.bounds.height > 1 else {
            return
        }

        let now = CACurrentMediaTime()

        let trackData = owner.effectEngine?
            .getPointsByTrack(now: now) ?? [:]

        let geometry = sceneBuilder.build(
            effect: owner.currentEffect,
            trackData: trackData,
            debugBoundingBoxes: owner.debugBoundingBoxes,
            viewportSize: owner.bounds.size,
            now: now
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
              ) else {
            return
        }

        commandBuffer.label = "PicTrailCommandBuffer"
        encoder.label = "PicTrailRenderEncoder"
        encoder.setCullMode(.none)

        var uniforms = PicUniforms(
            viewportSize: SIMD2(
                Float(owner.bounds.width),
                Float(owner.bounds.height)
            ),
            time: Float(
                now.truncatingRemainder(dividingBy: 4_096)
            ),
            pixelScale: Float(owner.contentScaleFactor)
        )

        // Ribbon 頂點資料可能遠超過 4 KB，必須用 MTLBuffer。
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

            // Uniform 很小，可以繼續使用 setVertexBytes。
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

        // Sprite 頂點資料同樣改用 MTLBuffer。
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(
        device: MTLDevice,
        view: MTKView,
        vertexFunctionName: String,
        fragmentFunctionName: String
    ) throws -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.defaultLibraryUnavailable
        }

        guard let vertexFunction = library.makeFunction(
            name: vertexFunctionName
        ) else {
            throw RendererError.shaderFunctionUnavailable(
                vertexFunctionName
            )
        }

        guard let fragmentFunction = library.makeFunction(
            name: fragmentFunctionName
        ) else {
            throw RendererError.shaderFunctionUnavailable(
                fragmentFunctionName
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label =
            "\(vertexFunctionName)-\(fragmentFunctionName)"

        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat =
            view.colorPixelFormat

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
