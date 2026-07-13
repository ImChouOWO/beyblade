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

/// 即時 Metal 特效疊加畫面。
///
/// 重要規則：
/// 1. 畫面只保留一個 MetalEffect renderer。
/// 2. 切換特效時立即銷毀上一個 renderer。
/// 3. 不再使用 EffectType -> MetalEffect 快取。
/// 4. 每一幀強制清除上一幀畫面。
/// 5. BladeMetalEffect 的粒子不會帶入其他特效。
final class MetalTrailOverlayView: MTKView {
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

    /// 保留 MainViewModel 目前使用的介面。
    var debugBoundingBoxes: [(CGRect, Int)] = []

    var resamplesTrailPoints = true
    var trailSampleSpacingPixels: CGFloat = 5

    private let renderContext: MetalRenderContext

    /// 當前唯一存在的 renderer。
    private var activeEffect: MetalEffect

    private var displayLink: CADisplayLink?
    private var displayLinkProxy: MetalDisplayLinkProxy?

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

    deinit {
        displayLink?.invalidate()
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
        backgroundColor = .clear
        layer.isOpaque = false

        preferredFramesPerSecond = 30

        /*
         此 MTKView 由自己的 CADisplayLink 驅動，
         避免 MTKView 再建立第二個顯示迴圈。
         */
        enableSetNeedsDisplay = false
        isPaused = true

        presentsWithTransaction = false

        activeEffect.prepareIfNeeded(
            context: renderContext
        )

        installDisplayLink()
    }

    private func installDisplayLink() {
        displayLink?.invalidate()

        let proxy = MetalDisplayLinkProxy(
            owner: self
        )

        let link = CADisplayLink(
            target: proxy,
            selector: #selector(
                MetalDisplayLinkProxy.tick(_:)
            )
        )

        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange =
                CAFrameRateRange(
                    minimum: 30,
                    maximum: 30,
                    preferred: 30
                )
        } else {
            link.preferredFramesPerSecond = 30
        }

        link.add(
            to: .main,
            forMode: .common
        )

        link.isPaused = window == nil

        displayLinkProxy = proxy
        displayLink = link
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

        displayLink?.isPaused =
            window == nil

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

    // MARK: - Effect switching

    /// 完整替換目前的 renderer。
    ///
    /// 不從快取取回舊 renderer，因此：
    /// - sparks 不會保留
    /// - cracks 不會保留
    /// - glints 不會保留
    /// - slash waves 不會保留
    /// - lastPosition 不會保留
    private func replaceActiveEffect(
        with effectType: EffectType
    ) {
        /*
         先停止上一個 renderer 的狀態。
         即使某個子類別沒有實作 reset，
         後面仍會直接丟棄整個實例。
         */
        activeEffect.reset()

        let newEffect =
            MetalEffectFactory.makeEffect(
                for: effectType
            )

        newEffect.prepareIfNeeded(
            context: renderContext
        )

        activeEffect = newEffect

        /*
         新特效第一幀重新計算 deltaTime，
         避免上一個 renderer 的幀時間影響粒子速度。
         */
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

    // MARK: - Display link

    fileprivate func handleDisplayLink(
        _ link: CADisplayLink
    ) {
        let deltaTime: CFTimeInterval

        if lastFrameTimestamp == 0 {
            deltaTime = 1.0 / 30.0
        } else {
            deltaTime = max(
                min(
                    link.timestamp
                    - lastFrameTimestamp,
                    0.1
                ),
                1.0 / 240.0
            )
        }

        lastFrameTimestamp =
            link.timestamp

        renderFrame(
            deltaTime: deltaTime
        )
    }

    // MARK: - Render frame

    private func renderFrame(
        deltaTime: CFTimeInterval
    ) {
        autoreleasepool {
            guard drawableSize.width > 1,
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

            /*
             關鍵修正：

             每幀都明確清除成透明背景，
             不讓上一幀 Blade shader 的結果留在 drawable。
             */
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

            let currentTime =
                CACurrentMediaTime()

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

                /*
                 activeEffect 與 currentEffect 必須同步。

                 Factory 只在切換時建立新實例，
                 因此這裡不再重新查快取。
                 */
                activeEffect.prepareIfNeeded(
                    context: renderContext
                )

                activeEffect.draw(
                    trackData: tracks,
                    context: renderContext,
                    effectType: currentEffect
                )
            }

            /*
             目前正式畫面沒有繪製 debug box，
             但保留屬性以相容 MainViewModel。
             */
            _ = debugBoundingBoxes

            renderContext.endFrame()

            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
