import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
@preconcurrency import MetalKit

/// 將來源影格與目前 Pic Metal 特效合成到可交給 AVAssetWriter 的 BGRA PixelBuffer。
///
/// 這個類別不重新實作任何特效；所有幾何與 shader 都由 PicTrailMetalRenderCore 處理。
final class PicTrailPixelBufferCompositor {

    enum CompositorError: LocalizedError {
        case metalDeviceUnavailable
        case commandQueueUnavailable
        case textureCacheUnavailable(OSStatus)
        case unsupportedDestinationPixelFormat(OSType)
        case destinationTextureUnavailable(OSStatus)
        case commandBufferUnavailable
        case commandBufferFailed(String)

        var errorDescription: String? {
            switch self {
            case .metalDeviceUnavailable:
                return "此裝置不支援 Metal"

            case .commandQueueUnavailable:
                return "無法建立 Metal command queue"

            case .textureCacheUnavailable(let status):
                return "無法建立 CVMetalTextureCache：\(status)"

            case .unsupportedDestinationPixelFormat(let format):
                return "錄影輸出 PixelBuffer 格式不是 BGRA：\(format)"

            case .destinationTextureUnavailable(let status):
                return "無法從錄影 PixelBuffer 建立 Metal texture：\(status)"

            case .commandBufferUnavailable:
                return "無法建立 Metal command buffer"

            case .commandBufferFailed(let message):
                return "Metal 合成失敗：\(message)"
            }
        }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let renderCore: PicTrailMetalRenderCore

    /// 目前即時 UI 的常見短邊約為 390 pt。
    /// 離線與錄影輸出以此換算 logical viewport，讓特效粗細與即時畫面接近。
    private let referenceLogicalShortEdge: CGFloat = 390

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CompositorError.metalDeviceUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw CompositorError.commandQueueUnavailable
        }

        var createdCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &createdCache
        )

        guard cacheStatus == kCVReturnSuccess,
              let createdCache else {
            throw CompositorError.textureCacheUnavailable(
                cacheStatus
            )
        }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = createdCache
        self.ciContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false
            ]
        )
        self.renderCore = try PicTrailMetalRenderCore(
            device: device,
            colorPixelFormat: .bgra8Unorm
        )
    }

    func render(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        trackData: [Int: [(TrailPoint, Float)]],
        effect: EffectType,
        now: TimeInterval
    ) throws {
        let destinationFormat = CVPixelBufferGetPixelFormatType(
            destination
        )

        guard destinationFormat == kCVPixelFormatType_32BGRA else {
            throw CompositorError.unsupportedDestinationPixelFormat(
                destinationFormat
            )
        }

        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)

        guard width > 0, height > 0 else {
            return
        }

        renderSourceFrame(
            source,
            into: destination,
            width: width,
            height: height
        )

        let texture = try makeTexture(
            from: destination,
            width: width,
            height: height
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CompositorError.commandBufferUnavailable
        }

        commandBuffer.label = "PicTrailPixelBufferCompositeCommand"

        let passDescriptor = MTLRenderPassDescriptor()

        guard let colorAttachment = passDescriptor.colorAttachments[0] else {
            throw CompositorError.commandBufferUnavailable
        }

        colorAttachment.texture = texture
        colorAttachment.loadAction = .load
        colorAttachment.storeAction = .store

        let logicalViewport = makeLogicalViewport(
            pixelWidth: width,
            pixelHeight: height
        )

        let pixelScale = CGFloat(width) /
            max(logicalViewport.width, 1)

        try renderCore.encode(
            effect: effect,
            trackData: trackData,
            viewportSize: logicalViewport,
            now: now,
            pixelScale: pixelScale,
            passDescriptor: passDescriptor,
            commandBuffer: commandBuffer
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw CompositorError.commandBufferFailed(
                commandBuffer.error?.localizedDescription ?? "unknown"
            )
        }
    }

    private func renderSourceFrame(
        _ source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        width: Int,
        height: Int
    ) {
        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent

        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )

        let scaleX = CGFloat(width) /
            max(extent.width, 1)
        let scaleY = CGFloat(height) /
            max(extent.height, 1)

        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: scaleX,
                y: scaleY
            )
        )

        let destinationBounds = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )

        ciContext.render(
            scaled,
            to: destination,
            bounds: destinationBounds,
            colorSpace: colorSpace
        )
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?

        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        if status != kCVReturnSuccess {
            CVMetalTextureCacheFlush(textureCache, 0)

            status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        }

        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw CompositorError.destinationTextureUnavailable(
                status
            )
        }

        return texture
    }

    private func makeLogicalViewport(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGSize {
        let shortEdge = CGFloat(
            min(pixelWidth, pixelHeight)
        )

        let scale = max(
            shortEdge / referenceLogicalShortEdge,
            1
        )

        return CGSize(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )
    }
}
