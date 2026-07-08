import GLKit
import OpenGLES
import UIKit

/// OpenGL ES overlay that keeps the existing MainViewModel API intact.
/// It replaces the previous Core Graphics implementation without changing ContentView.
final class GLTrailOverlayView: GLKView {
  var effectEngine: TrailEffectEngine?

  var currentEffect: EffectType = .lightning {
    didSet {
      guard currentEffect != oldValue else { return }
      activeEffect = effect(for: currentEffect)
      activeEffect.prepareIfNeeded(context: renderContext)
    }
  }

  /// Preserved for MainViewModel compatibility.
  var debugBoundingBoxes: [CGRect] = []

  private let renderContext = GLRenderContext()
  private var effectCache: [EffectType: GLEffect] = [:]
  private var activeEffect: GLEffect
  private var displayLink: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0

  override init(frame: CGRect) {
    let context = EAGLContext(api: .openGLES2)!
    activeEffect = GLEffectFactory.makeEffect(for: .lightning)
    super.init(frame: frame, context: context)
    configureGL()
  }

  required init?(coder: NSCoder) {
    let context = EAGLContext(api: .openGLES2)!
    activeEffect = GLEffectFactory.makeEffect(for: .lightning)
    super.init(coder: coder)
    self.context = context
    configureGL()
  }

  deinit {
    displayLink?.invalidate()
    if EAGLContext.current() === context {
      EAGLContext.setCurrent(nil)
    }
  }

  private func configureGL() {
    isOpaque = false
    backgroundColor = .clear
    layer.isOpaque = false
    drawableColorFormat = .RGBA8888
    drawableDepthFormat = .formatNone
    drawableStencilFormat = .formatNone
    enableSetNeedsDisplay = true
    contentScaleFactor = UIScreen.main.scale

    EAGLContext.setCurrent(context)
    glDisable(GLenum(GL_DEPTH_TEST))
    glDisable(GLenum(GL_CULL_FACE))
    glEnable(GLenum(GL_BLEND))
    glBlendFunc(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE_MINUS_SRC_ALPHA))

    effectCache[.lightning] = activeEffect
    activeEffect.prepareIfNeeded(context: renderContext)
    installDisplayLink()
  }

  private func installDisplayLink() {
    displayLink?.invalidate()
    let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 30,
        maximum: Float(UIScreen.main.maximumFramesPerSecond),
        preferred: Float(UIScreen.main.maximumFramesPerSecond)
      )
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc
  private func frameTick(_ link: CADisplayLink) {
    let dt: CFTimeInterval
    if lastTimestamp == 0 {
      dt = 1.0 / 30.0
    } else {
      dt = max(link.timestamp - lastTimestamp, 1.0 / 240.0)
    }
    lastTimestamp = link.timestamp
    renderContext.update(size: currentDrawableSize(), deltaTime: dt)
    display()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    displayLink?.isPaused = window == nil
    if window == nil { lastTimestamp = 0 }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    renderContext.update(size: currentDrawableSize(), deltaTime: 1.0 / 30.0)
  }

  override func draw(_ rect: CGRect) {
    EAGLContext.setCurrent(context)
    glViewport(0, 0, GLsizei(drawableWidth), GLsizei(drawableHeight))
    glClearColor(0, 0, 0, 0)
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    glEnable(GLenum(GL_BLEND))
    glBlendFunc(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE_MINUS_SRC_ALPHA))

    guard bounds.width > 1,
      bounds.height > 1,
      let effectEngine
    else {
      return
    }

    let tracks = effectEngine.getPointsByTrack(now: CACurrentMediaTime())
    activeEffect.prepareIfNeeded(context: renderContext)
    activeEffect.draw(
      trackData: tracks,
      context: renderContext,
      effectType: currentEffect
    )
  }

  override func setNeedsDisplay() {
    super.setNeedsDisplay()
    if Thread.isMainThread {
      display()
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.display()
      }
    }
  }

  private func currentDrawableSize() -> CGSize {
    let width =
      drawableWidth > 0
      ? CGFloat(drawableWidth)
      : bounds.width * contentScaleFactor
    let height =
      drawableHeight > 0
      ? CGFloat(drawableHeight)
      : bounds.height * contentScaleFactor
    return CGSize(width: max(width, 1), height: max(height, 1))
  }

  private func effect(for type: EffectType) -> GLEffect {
    if let cached = effectCache[type] {
      return cached
    }
    let effect = GLEffectFactory.makeEffect(for: type)
    effectCache[type] = effect
    return effect
  }
}
