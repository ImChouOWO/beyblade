import UIKit
@preconcurrency import MetalKit

@MainActor
final class PicTrailOverlayView: MTKView {

    var effectEngine: TrailEffectEngine?

    var currentEffect: EffectType = .lightning

    var debugBoundingBoxes: [(CGRect, Int)] = []

    private var picRenderer: PicTrailRenderer?

    convenience init() {
        self.init(
            frame: .zero,
            device: MTLCreateSystemDefaultDevice()
        )
    }

    override init(
        frame frameRect: CGRect,
        device: MTLDevice?
    ) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("此裝置不支援 Metal")
        }

        super.init(
            frame: frameRect,
            device: metalDevice
        )

        configureMetalView()
    }

    required init(coder: NSCoder) {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("此裝置不支援 Metal")
        }

        super.init(coder: coder)

        device = metalDevice
        configureMetalView()
    }

    private func configureMetalView() {
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        sampleCount = 1

        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false

        framebufferOnly = true
        autoResizeDrawable = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        presentsWithTransaction = false

        do {
            let renderer = try PicTrailRenderer(view: self)
            picRenderer = renderer
            delegate = renderer
        } catch {
            assertionFailure(
                "Metal 特效渲染器初始化失敗：\(error.localizedDescription)"
            )
        }
    }
}
