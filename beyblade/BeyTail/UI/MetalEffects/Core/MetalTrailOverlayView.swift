import Metal
@preconcurrency import MetalKit
import QuartzCore
import UIKit

/// 即時 Metal 特效疊加畫面。
///
/// 使用 MTKViewDelegate 原生顯示迴圈，避免自建 CADisplayLink
/// 在 SwiftUI 重新掛載 UIView 後停留於 paused 狀態。
@MainActor
final class MetalTrailOverlayView: MTKView, MTKViewDelegate {
    var effectEngine: TrailEffectEngine?

    var currentEffect: EffectType = .lightning {
        didSet {
            guard currentEffect != oldValue else {
                return
            }

            replaceActiveEffect(
                with: currentEffect
            )
        }
    }

    var debugBoundingBoxes: [(CGRect, Int)] = []

    var resamplesTrailPoints = true
    var trailSampleSpacingPixels: CGFloat = 5

    private let renderContext: MetalRenderContext
    private var activeEffect: MetalEffect
    private var lastFrameTimestamp: CFTimeInterval = 0

    convenience init() {
        self.init(frame: .zero)
    }

    convenience init(frame: CGRect) {
        guard let device =
                MTLCreateSystemDefaultDevice() else {
            fatalError(
                "Metal is unavailable on this device"
            )
        }

        self.init(
            frame: frame,
            device: device
        )
    }

    override init(
        frame frameRect: CGRect,
        device: MTLDevice?
    ) {
        guard let resolvedDevice =
                device
                ?? MTLCreateSystemDefaultDevice() else {
            fatalError(
                "Metal is unavailable on this device"
            )
        }

        renderContext = MetalRenderContext(
            device: resolvedDevice,
            pixelFormat: .bgra8Unorm
        )

        activeEffect =
            MetalEffectFactory.makeEffect(
                for: .lightning
            )

        super.init(
            frame: frameRect,
            device: resolvedDevice
        )

        configureMetalView()
    }

    required init(coder: NSCoder) {
        guard let metalDevice =
                MTLCreateSystemDefaultDevice() else {
            fatalError(
                "Metal is unavailable on this device"
            )
        }

        renderContext = MetalRenderContext(
            device: metalDevice,
            pixelFormat: .bgra8Unorm
        )

        activeEffect =
            MetalEffectFactory.makeEffect(
                for: .lightning
            )

        super.init(coder: coder)

        device = metalDevice

        configureMetalView()
    }

    // MARK: - Configuration

    private func configureMetalView() {
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        sampleCount = 1

        clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        framebufferOnly = true
        autoResizeDrawable = true

        isOpaque = false
        isHidden = false
        alpha = 1
        backgroundColor = .clear
        layer.isOpaque = false

        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false

        /*
         關鍵修正：
         不再將 MTKView 設為 paused，也不再使用自建 CADisplayLink。
         MTKView 會自行以 preferredFramesPerSecond 呼叫 draw(in:)。
         */
        isPaused = false
        delegate = self

        presentsWithTransaction = false

        activeEffect.prepareIfNeeded(
            context: renderContext
        )
    }

    // MARK: - View lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let screenScale =
            window?.windowScene?.screen.scale
            ?? traitCollection.displayScale

        contentScaleFactor = max(
            screenScale,
            1
        )

        isHidden = false
        alpha = 1
        isPaused = window == nil

        if window != nil {
            /*
             SwiftUI 將既有 UIView 重新掛回畫面時，立即要求 drawable，
             不必等待下一次狀態更新。
             */
            setNeedsLayout()
            draw()
        } else {
            lastFrameTimestamp = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        renderContext.update(
            drawableSize: drawableSize,
            deltaTime: 1.0 / 30.0
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        renderContext.update(
            drawableSize: size,
            deltaTime: 1.0 / 30.0
        )
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()

        let deltaTime: CFTimeInterval

        if lastFrameTimestamp == 0 {
            deltaTime = 1.0 / 30.0
        } else {
            deltaTime = max(
                min(
                    now - lastFrameTimestamp,
                    0.1
                ),
                1.0 / 240.0
            )
        }

        lastFrameTimestamp = now

        renderFrame(
            currentTime: now,
            deltaTime: deltaTime
        )
    }

    // MARK: - Effect switching

    func resetTransientState() {
        replaceActiveEffect(
            with: currentEffect
        )
    }

    private func replaceActiveEffect(
        with effectType: EffectType
    ) {
        activeEffect.reset()

        let newEffect =
            MetalEffectFactory.makeEffect(
                for: effectType
            )

        newEffect.prepareIfNeeded(
            context: renderContext
        )

        activeEffect = newEffect
        lastFrameTimestamp = 0

        #if DEBUG
        print(
            "[MetalTrailOverlayView] active:",
            effectType.rawValue,
            String(
                describing:
                    Swift.type(of: activeEffect)
            )
        )
        #endif
    }

    // MARK: - Render frame

    private func renderFrame(
        currentTime: CFTimeInterval,
        deltaTime: CFTimeInterval
    ) {
        autoreleasepool {
            guard window != nil,
                  !isHidden,
                  alpha > 0,
                  bounds.width > 1,
                  bounds.height > 1,
                  drawableSize.width > 1,
                  drawableSize.height > 1,
                  let renderPassDescriptor =
                    currentRenderPassDescriptor,
                  let drawable =
                    currentDrawable,
                  let commandBuffer =
                    renderContext.commandQueue
                    .makeCommandBuffer() else {
                return
            }

            if let colorAttachment =
                renderPassDescriptor
                    .colorAttachments[0] {
                colorAttachment.loadAction =
                    .clear

                colorAttachment.storeAction =
                    .store

                colorAttachment.clearColor =
                    MTLClearColor(
                        red: 0,
                        green: 0,
                        blue: 0,
                        alpha: 0
                    )
            }

            guard let encoder =
                    commandBuffer
                    .makeRenderCommandEncoder(
                        descriptor:
                            renderPassDescriptor
                    ) else {
                return
            }

            encoder.label =
                "BeyTailLiveEffectEncoder"

            encoder.setCullMode(.none)

            renderContext.update(
                drawableSize: drawableSize,
                deltaTime: deltaTime
            )

            renderContext.applyRenderProfile(
                currentEffect
                    .trailRenderProfile
            )

            renderContext.beginFrame(
                commandBuffer: commandBuffer,
                encoder: encoder
            )

            if let effectEngine {
                let originalTracks =
                    effectEngine
                    .getPointsByTrack(
                        now: currentTime
                    )

                let tracks: MetalTrackData

                if resamplesTrailPoints {
                    tracks =
                        TrailResampler.resample(
                            originalTracks,
                            drawableSize:
                                drawableSize,
                            spacingPixels:
                                trailSampleSpacingPixels
                        )
                } else {
                    tracks = originalTracks
                }

                activeEffect.prepareIfNeeded(
                    context: renderContext
                )

                activeEffect.draw(
                    trackData: tracks,
                    context: renderContext,
                    effectType: currentEffect
                )
            }

            _ = debugBoundingBoxes

            renderContext.endFrame()
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
