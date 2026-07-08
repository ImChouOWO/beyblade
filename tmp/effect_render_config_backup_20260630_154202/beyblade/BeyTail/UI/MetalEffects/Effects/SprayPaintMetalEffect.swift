import UIKit

/// Direct Swift/Metal port of SprayPaintMetalEffect.kt.
final class SprayPaintMetalEffect: MetalEffect {
  private static let bytesPerPaintVertex = 32
  private static let bytesPerBlob = 32
  private static let maxTrailPoints = 256
  private static let mistPerFrame: Float = 2
  private static let trailHalfWidth: Float = 0.034
  private static let timeWrap: Float = 120

  private var paintProgram: MetalProgramID = 0
  private var paintPosition: MetalLocation = -1
  private var paintColor: MetalLocation = -1
  private var paintCenterDistance: MetalLocation = -1
  private var paintTrailDistance: MetalLocation = -1
  private var paintTime: MetalLocation = -1

  private var splatProgram: MetalProgramID = 0
  private var splatPosition: MetalLocation = -1
  private var splatColor: MetalLocation = -1
  private var splatSize: MetalLocation = -1
  private var splatSeed: MetalLocation = -1

  private final class Blob {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var sizePx: Float = 10
    var grow: Float = 0
    var alpha: Float = 0
    var decay: Float = 0.04
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
    var seed: Float = 0
  }

  private let splats = (0..<36).map { _ in Blob() }
  private let mist = (0..<64).map { _ in Blob() }
  private let splatFloats = MetalFloatBuffer(capacity: 36 * 8)
  private let mistFloats = MetalFloatBuffer(capacity: 64 * 8)
  private var lastPosition: [Int: (Float, Float)] = [:]
  private var time: Float = 0
  private var viewHalfWidth: Float = 1
  private var viewHalfHeight: Float = 1
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var cumulativeLength = [Float](repeating: 0, count: maxTrailPoints)

  override func onMetalReady(context: MetalRenderContext) {
    paintProgram = MetalHelper.makeProgram(.sprayPaint)
    paintPosition = metalGetAttribLocation(paintProgram, "aPosition")
    paintColor = metalGetAttribLocation(paintProgram, "aColor")
    paintCenterDistance = metalGetAttribLocation(paintProgram, "aCenterDist")
    paintTrailDistance = metalGetAttribLocation(paintProgram, "aTrailDist")
    paintTime = metalGetUniformLocation(paintProgram, "uTime")

    splatProgram = MetalHelper.makeProgram(.splat)
    splatPosition = metalGetAttribLocation(splatProgram, "aPosition")
    splatColor = metalGetAttribLocation(splatProgram, "aColor")
    splatSize = metalGetAttribLocation(splatProgram, "aSize")
    splatSeed = metalGetAttribLocation(splatProgram, "aSeed")
  }

  override func draw(trackData: MetalTrackData, context: MetalRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    viewHalfWidth = max(Float(context.viewWidth) * 0.5, 1)
    viewHalfHeight = max(Float(context.viewHeight) * 0.5, 1)

    updateBlobs(splats, context: context)
    drawBlobs(splats, buffer: splatFloats)

    metalUseProgram(paintProgram)
    metalUniform1f(paintTime, time)
    for (_, points) in trackData where points.count >= 3 {
      drawPaintTrail(points, context: context, widthScale: effectType.trailWidthMultiplier)
    }

    spawnFromTrack(trackData, context: context)
    updateBlobs(mist, context: context)
    drawBlobs(mist, buffer: mistFloats)
  }

  private func drawPaintTrail(
    _ points: [MetalTrailSample],
    context: MetalRenderContext,
    widthScale: Float
  ) {
    let n = min(points.count, Self.maxTrailPoints)
    guard n >= 3, n * 2 * Self.bytesPerPaintVertex <= context.ribbonFloats.capacityBytes else {
      return
    }
    let color = vivid(points.last!.first.color)

    for i in 0..<n {
      pointX[i] = Float(points[i].first.center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - points[i].first.center.y * 2) * context.quadScaleY
      if i == 0 {
        cumulativeLength[i] = 0
      } else {
        cumulativeLength[i] =
          cumulativeLength[i - 1] + hypot(pointX[i] - pointX[i - 1], pointY[i] - pointY[i - 1])
      }
    }

    context.ribbonFloats.clear()
    for i in 0..<n {
      let x = pointX[i]
      let y = pointY[i]
      let normal: (Float, Float)
      if i == 0 {
        normal = MetalHelper.segNormal(x, y, pointX[1], pointY[1])
      } else if i == n - 1 {
        normal = MetalHelper.segNormal(pointX[n - 2], pointY[n - 2], x, y)
      } else {
        normal = MetalHelper.avgNormal(
          pointX[i - 1], pointY[i - 1], x, y, pointX[i + 1], pointY[i + 1])
      }
      let alpha = points[i].second
      let halfWidth = Self.trailHalfWidth * widthScale * (0.45 + 0.55 * alpha)
      let trail = cumulativeLength[i]
      context.ribbonFloats
        .put(x - normal.0 * halfWidth).put(y - normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(alpha).put(-1).put(trail)
      context.ribbonFloats
        .put(x + normal.0 * halfWidth).put(y + normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(alpha).put(1).put(trail)
    }
    MetalHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerPaintVertex,
      attributes: [
        MetalVertexAttribute(location: paintPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: paintColor, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: paintCenterDistance, size: 1, offsetBytes: 24),
        MetalVertexAttribute(location: paintTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: MGL_TRIANGLE_STRIP,
      vertexCount: n * 2
    )
  }

  private func spawnFromTrack(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let minDimension = min(width, height)
    guard minDimension > 0 else { return }
    for (trackID, points) in trackData where points.count >= 2 {
      let point = points.last!.first
      let previous = points[points.count - 2].first
      let x = Float(point.center.x * 2 - 1) * context.quadScaleX
      let y = Float(1 - point.center.y * 2) * context.quadScaleY
      let x1 = Float(previous.center.x * 2 - 1) * context.quadScaleX
      let y1 = Float(1 - previous.center.y * 2) * context.quadScaleY
      let dx = x - x1
      let dy = y - y1
      let movement = hypot(dx, dy)
      let angle = atan2(dy * height, dx * width)

      var mistCount = Self.mistPerFrame * context.dtScale
      while mistCount > 0 {
        if mistCount < 1, Float.random(in: 0...1) > mistCount { break }
        spawnMist(x: x, y: y, minDimension: minDimension, color: point.color)
        mistCount -= 1
      }

      let distance =
        lastPosition[trackID].map { hypot(x - $0.0, y - $0.1) } ?? .greatestFiniteMagnitude
      guard distance > 0.006 else { continue }
      lastPosition[trackID] = (x, y)
      let normalizedMovement = movement / context.dtScale
      if normalizedMovement > 0.010, Double.random(in: 0...1) > 0.45 {
        let side: Float = Bool.random() ? 1 : -1
        spawnSplat(
          x: x, y: y, angle: angle + side * 1.4, minDimension: minDimension, color: point.color,
          big: false)
      }
      if normalizedMovement > 0.018 {
        let backward = angle + .pi
        for _ in 0..<2 {
          spawnSplat(
            x: x, y: y, angle: backward + Float.random(in: -0.6...0.6), minDimension: minDimension,
            color: point.color, big: true)
        }
      }
    }
  }

  private func spawnSplat(
    x: Float, y: Float, angle: Float, minDimension: Float, color: UIColor, big: Bool
  ) {
    guard let blob = splats.first(where: { !$0.active }) else { return }
    let speed =
      big
      ? minDimension * Float.random(in: 0.006...0.016)
      : minDimension * Float.random(in: 0.004...0.010)
    let rgb = vivid(color, lightJitter: Float.random(in: -0.1...0.1))
    blob.active = true
    blob.x = x + Float.random(in: -0.01...0.01)
    blob.y = y + Float.random(in: -0.01...0.01)
    blob.vx = cos(angle) * speed
    blob.vy = sin(angle) * speed
    blob.sizePx =
      big
      ? minDimension * Float.random(in: 0.020...0.040)
      : minDimension * Float.random(in: 0.010...0.020)
    blob.grow = Float.random(in: 0.12...0.20)
    blob.alpha = 1
    blob.decay = big ? Float.random(in: 0.025...0.045) : Float.random(in: 0.04...0.07)
    blob.seed = Float.random(in: 0...(2 * .pi))
    (blob.r, blob.g, blob.b) = rgb
  }

  private func spawnMist(x: Float, y: Float, minDimension: Float, color: UIColor) {
    guard let blob = mist.first(where: { !$0.active }) else { return }
    let angle = Float.random(in: 0...(2 * .pi))
    let speed = minDimension * Float.random(in: 0.002...0.008)
    let rgb = vivid(color, lightJitter: Float.random(in: -0.1...0.1))
    blob.active = true
    blob.x = x + Float.random(in: -0.02...0.02)
    blob.y = y + Float.random(in: -0.02...0.02)
    blob.vx = cos(angle) * speed
    blob.vy = sin(angle) * speed
    blob.sizePx = minDimension * Float.random(in: 0.004...0.012)
    blob.grow = 0
    blob.alpha = 0.85
    blob.decay = Float.random(in: 0.05...0.10)
    blob.seed = Float.random(in: 0...(2 * .pi))
    (blob.r, blob.g, blob.b) = rgb
  }

  private func updateBlobs(_ pool: [Blob], context: MetalRenderContext) {
    let dt = context.dtScale
    for blob in pool where blob.active {
      blob.x += blob.vx * dt / viewHalfWidth
      blob.y += blob.vy * dt / viewHalfHeight
      blob.vx *= 1 - 0.18 * dt
      blob.vy *= 1 - 0.18 * dt
      if blob.grow != 0 {
        blob.sizePx *= 1 + blob.grow * dt
        blob.grow *= 1 - 0.25 * dt
      }
      blob.alpha -= blob.decay * dt
      if blob.alpha <= 0 { blob.active = false }
    }
  }

  private func drawBlobs(_ pool: [Blob], buffer: MetalFloatBuffer) {
    buffer.clear()
    var count = 0
    for blob in pool where blob.active {
      buffer
        .put(blob.x).put(blob.y)
        .put(blob.r).put(blob.g).put(blob.b).put(blob.alpha.metalClamped())
        .put(blob.sizePx).put(blob.seed)
      count += 1
    }
    guard count > 0 else { return }
    metalUseProgram(splatProgram)
    MetalHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: Self.bytesPerBlob,
      attributes: [
        MetalVertexAttribute(location: splatPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: splatColor, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: splatSize, size: 1, offsetBytes: 24),
        MetalVertexAttribute(location: splatSeed, size: 1, offsetBytes: 28),
      ],
      mode: MGL_POINTS,
      vertexCount: count
    )
  }

  private func vivid(_ color: UIColor, lightJitter: Float = 0) -> (Float, Float, Float) {
    let source = MetalHelper.rgba(color)
    var r = source.0
    var g = source.1
    var b = source.2
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    let saturation: Float = 1.7
    r = luminance + (r - luminance) * saturation
    g = luminance + (g - luminance) * saturation
    b = luminance + (b - luminance) * saturation
    let maximum = max(r, max(g, b))
    if maximum > 0.0001 {
      let scale = min(1 / maximum, 1.5)
      r *= scale
      g *= scale
      b *= scale
    }
    let light = 1 + lightJitter
    return ((r * light).metalClamped(), (g * light).metalClamped(), (b * light).metalClamped())
  }
}
