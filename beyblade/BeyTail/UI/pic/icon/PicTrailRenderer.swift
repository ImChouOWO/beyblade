import Foundation
@preconcurrency import MetalKit

@MainActor
final class PicTrailRenderer: NSObject, MTKViewDelegate {

    enum RendererError: LocalizedError {
        case commandQueueUnavailable

        var errorDescription: String? {
            switch self {
            case .commandQueueUnavailable:
                return "無法建立 Metal command queue"
            }
        }
    }

    private weak var owner: PicTrailOverlayView?
    private let commandQueue: MTLCommandQueue
    private let renderCore: PicTrailMetalRenderCore

    init(view: PicTrailOverlayView) throws {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }

        self.owner = view
        self.commandQueue = commandQueue
        self.renderCore = try PicTrailMetalRenderCore(
            device: device,
            colorPixelFormat: view.colorPixelFormat
        )

        super.init()

        print("[METAL] PicTrailRenderer ready:", device.name)
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        // 幾何座標以 view.bounds 的 point 為基準。
    }

    func draw(in view: MTKView) {
        guard let owner,
              let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              owner.bounds.width > 1,
              owner.bounds.height > 1,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let now = CACurrentMediaTime()
        let trackData = owner.effectEngine?
            .getPointsByTrack(now: now) ?? [:]

        commandBuffer.label = "PicTrailPreviewCommandBuffer"

        do {
            try renderCore.encode(
                effect: owner.currentEffect,
                trackData: trackData,
                debugBoundingBoxes: owner.debugBoundingBoxes,
                viewportSize: owner.bounds.size,
                now: now,
                pixelScale: owner.contentScaleFactor,
                passDescriptor: passDescriptor,
                commandBuffer: commandBuffer
            )
        } catch {
            print(
                "[METAL] preview encode failed:",
                error.localizedDescription
            )
            return
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
