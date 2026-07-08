import Metal
@preconcurrency import MetalKit
import QuartzCore
import UIKit

@MainActor
private final class MetalDisplayLinkProxy: NSObject {
    weak var owner: MetalTrailOverlayView?

    init(owner: MetalTrailOverlayView) {
        self.owner = owner
    }

    @objc
    func tick(_ link: CADisplayLink) {
        owner?.handleDisplayLink(link)
    }
}

/// Long-term iOS renderer for the Android/Kotlin trail effects.
///
/// The view intentionally renders at 30 Hz because the reference Android
/// videos and the original particle probabilities are authored around a
/// 30 FPS update loop. Rendering at 60/120 Hz would otherwise double or
/// quadruple random particle emission.
final class MetalTrailOverlayView: MTKView {
    var effectEngine: TrailEffectEngine?

    var currentEffect: EffectType = .lightning {
        didSet {
            guard currentEffect != oldValue else { return }
            activeEffect = effect(for: currentEffect)
            activeEffect.prepareIfNeeded(context: renderContext)
        }
    }

    /// Kept for MainViewModel compatibility. Production rendering currently
    /// leaves this empty, matching the existing app behavior.
    var debugBoundingBoxes: [(CGRect, Int)] = []

    var resamplesTrailPoints = true
    var trailSampleSpacingPixels: CGFloat = 5

    private let renderContext: MetalRenderContext
    private var effectCache: [EffectType: MetalEffect] = [:]
    private var activeEffect: MetalEffect
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: MetalDisplayLinkProxy?
    private var lastFrameTimestamp: CFTimeInterval = 0

    convenience init() {
        self.init(frame: .zero)
    }

    convenience init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device")
        }
        self.init(frame: frame, device: device)
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device")
        }

        activeEffect = MetalEffectFactory.makeEffect(for: .lightning)
        renderContext = MetalRenderContext(
            device: resolvedDevice,
            pixelFormat: .bgra8Unorm
        )

        super.init(frame: frameRect, device: resolvedDevice)
        configureMetalView()
    }

    required init(coder: NSCoder) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device")
        }

        activeEffect = MetalEffectFactory.makeEffect(for: .lightning)
        renderContext = MetalRenderContext(
            device: device,
            pixelFormat: .bgra8Unorm
        )

        super.init(coder: coder)
        self.device = device
        configureMetalView()
    }

    deinit {
        displayLink?.invalidate()
    }

    private func configureMetalView() {
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        framebufferOnly = true
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = true
        autoResizeDrawable = true
        presentsWithTransaction = false

        effectCache[.lightning] = activeEffect
        activeEffect.prepareIfNeeded(context: renderContext)
        installDisplayLink()
    }

    private func installDisplayLink() {
        displayLink?.invalidate()
        let proxy = MetalDisplayLinkProxy(owner: self)
        let link = CADisplayLink(
            target: proxy,
            selector: #selector(MetalDisplayLinkProxy.tick(_:))
        )
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: 30,
                preferred: 30
            )
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        link.isPaused = window == nil
        displayLinkProxy = proxy
        displayLink = link
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.windowScene?.screen.scale ??
            traitCollection.displayScale
        contentScaleFactor = max(scale, 1)
        displayLink?.isPaused = window == nil
        if window == nil {
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

    fileprivate func handleDisplayLink(_ link: CADisplayLink) {
        let deltaTime: CFTimeInterval
        if lastFrameTimestamp == 0 {
            deltaTime = 1.0 / 30.0
        } else {
            deltaTime = max(
                min(link.timestamp - lastFrameTimestamp, 0.1),
                1.0 / 240.0
            )
        }
        lastFrameTimestamp = link.timestamp
        renderFrame(deltaTime: deltaTime)
    }

    private func renderFrame(deltaTime: CFTimeInterval) {
        autoreleasepool {
            guard drawableSize.width > 1,
                  drawableSize.height > 1,
                  let descriptor = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let commandBuffer = renderContext.commandQueue
                    .makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: descriptor
                  ) else {
                return
            }

            let now = CACurrentMediaTime()
            renderContext.update(
                drawableSize: drawableSize,
                deltaTime: deltaTime
            )
            renderContext.applyRenderProfile(
                currentEffect.trailRenderProfile
            )
            renderContext.beginFrame(
                commandBuffer: commandBuffer,
                encoder: encoder
            )

            if let effectEngine {
                let rawTracks = effectEngine.getPointsByTrack(now: now)
                let tracks = resamplesTrailPoints
                    ? TrailResampler.resample(
                        rawTracks,
                        drawableSize: drawableSize,
                        spacingPixels: trailSampleSpacingPixels
                    )
                    : rawTracks

                activeEffect.prepareIfNeeded(context: renderContext)
                activeEffect.draw(
                    trackData: tracks,
                    context: renderContext,
                    effectType: currentEffect
                )
            }

            renderContext.endFrame()
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    private func effect(for type: EffectType) -> MetalEffect {
        if let cached = effectCache[type] {
            return cached
        }
        let effect = MetalEffectFactory.makeEffect(for: type)
        effectCache[type] = effect
        return effect
    }
}
