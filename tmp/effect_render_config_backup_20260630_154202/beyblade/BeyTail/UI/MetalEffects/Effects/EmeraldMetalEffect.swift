import UIKit

/// Direct Swift/Metal port of EmeraldMetalEffect.kt.
final class EmeraldMetalEffect: MetalEffect {
  private static let bytesPerVineVertex = 32
  private static let bytesPerLeafVertex = 32
  private static let bytesPerLine = 24
  private static let maxTrailPoints = 256
  private static let maxResample = 64
  private static let maxHeads = 8
  private static let ringCount = 4
  private static let ringSegments = 32
  private static let ringAlpha: Float = 0.16
  private static let vineHalfWidth: Float = 0.030
  private static let vineAmplitude: Float = 0.018
  private static let vineFrequency: Float = 2.0
  private static let vineSpeed: Float = 4.0
  private static let timeWrap: Float = 120

  private var vineProgram: MetalProgramID = 0
  private var vinePosition: MetalLocation = -1
  private var vineColor: MetalLocation = -1
  private var vineCenterDistance: MetalLocation = -1
  private var vineTrailDistance: MetalLocation = -1
  private var vineTime: MetalLocation = -1

  private var leafProgram: MetalProgramID = 0
  private var leafPosition: MetalLocation = -1
  private var leafUV: MetalLocation = -1
  private var leafColor: MetalLocation = -1

  private var ringProgram: MetalProgramID = 0
  private var ringPosition: MetalLocation = -1
  private var ringColor: MetalLocation = -1

  private final class Leaf {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var angle: Float = 0
    var angularVelocity: Float = 0
    var lengthPx: Float = 20
    var widthPx: Float = 5
    var alpha: Float = 0
    var decay: Float = 0.05
    var r: Float = 0.4
    var g: Float = 1
    var b: Float = 0.5
  }

  private let leaves = (0..<48).map { _ in Leaf() }
  private let leafFloats = MetalFloatBuffer(capacity: 48 * 6 * 8)
  private let ringFloats = MetalFloatBuffer(capacity: maxHeads * ringCount * ringSegments * 2 * 6)
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var resampledX = [Float](repeating: 0, count: maxResample)
  private var resampledY = [Float](repeating: 0, count: maxResample)
  private var resampledAlpha = [Float](repeating: 0, count: maxResample)
  private var cumulativeLength = [Float](repeating: 0, count: maxResample)
  private var time: Float = 0
  private var viewHalfWidth: Float = 1
  private var viewHalfHeight: Float = 1

  override func onMetalReady(context: MetalRenderContext) {
    vineProgram = MetalHelper.makeProgram(.emeraldVine)
    vinePosition = metalGetAttribLocation(vineProgram, "aPosition")
    vineColor = metalGetAttribLocation(vineProgram, "aColor")
    vineCenterDistance = metalGetAttribLocation(vineProgram, "aCenterDist")
    vineTrailDistance = metalGetAttribLocation(vineProgram, "aTrailDist")
    vineTime = metalGetUniformLocation(vineProgram, "uTime")

    leafProgram = MetalHelper.makeProgram(.leaf)
    leafPosition = metalGetAttribLocation(leafProgram, "aPosition")
    leafUV = metalGetAttribLocation(leafProgram, "aUV")
    leafColor = metalGetAttribLocation(leafProgram, "aColor")

    ringProgram = MetalHelper.makeProgram(.flatColor)
    ringPosition = metalGetAttribLocation(ringProgram, "aPosition")
    ringColor = metalGetAttribLocation(ringProgram, "aColor")
  }

  override func draw(trackData: MetalTrackData, context: MetalRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    viewHalfWidth = max(Float(context.viewWidth) * 0.5, 1)
    viewHalfHeight = max(Float(context.viewHeight) * 0.5, 1)

    drawTreeRings(trackData, context: context)
    updateLeaves(context: context)
    drawLeafQuads()

    metalUseProgram(vineProgram)
    metalUniform1f(vineTime, time)
    for (_, points) in trackData where points.count >= 3 {
      drawVine(points, context: context, widthScale: effectType.trailWidthMultiplier)
    }
    spawnFromTrack(trackData, context: context)
  }

  private func drawVine(
    _ points: [MetalTrailSample],
    context: MetalRenderContext,
    widthScale: Float
  ) {
    let n = min(points.count, Self.maxTrailPoints)
    guard n >= 3 else { return }
    for i in 0..<n {
      pointX[i] = Float(points[i].first.center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - points[i].first.center.y * 2) * context.quadScaleY
    }
    let m = min(n * 3, Self.maxResample)
    for j in 0..<m {
      let f = Float(j) / Float(m - 1) * Float(n - 1)
      let i0 = min(Int(f), n - 2)
      let fraction = f - Float(i0)
      resampledX[j] = pointX[i0] + (pointX[i0 + 1] - pointX[i0]) * fraction
      resampledY[j] = pointY[i0] + (pointY[i0 + 1] - pointY[i0]) * fraction
      resampledAlpha[j] = points[i0].second + (points[i0 + 1].second - points[i0].second) * fraction
      if j == 0 {
        cumulativeLength[j] = 0
      } else {
        cumulativeLength[j] =
          cumulativeLength[j - 1]
          + hypot(resampledX[j] - resampledX[j - 1], resampledY[j] - resampledY[j - 1])
      }
    }
    guard m * 2 * Self.bytesPerVineVertex <= context.ribbonFloats.capacityBytes else { return }
    let totalLength = cumulativeLength[m - 1]
    let color = MetalHelper.rgba(points.last!.first.color)

    context.ribbonFloats.clear()
    for j in 0..<m {
      let x = resampledX[j]
      let y = resampledY[j]
      let normal: (Float, Float)
      if j == 0 {
        normal = MetalHelper.segNormal(x, y, resampledX[1], resampledY[1])
      } else if j == m - 1 {
        normal = MetalHelper.segNormal(resampledX[j - 1], resampledY[j - 1], x, y)
      } else {
        normal = MetalHelper.avgNormal(
          resampledX[j - 1], resampledY[j - 1], x, y, resampledX[j + 1], resampledY[j + 1])
      }
      let u = Float(j) / Float(m - 1)
      let life = resampledAlpha[j]
      let wave = sin(u * Self.vineFrequency * 2 * .pi - time * Self.vineSpeed)
      let offset = wave * Self.vineAmplitude * (1 - u)
      let halfWidth = Self.vineHalfWidth * widthScale * (0.35 + 0.65 * life)
      let centerX = x + normal.0 * offset
      let centerY = y + normal.1 * offset
      let trail = totalLength - cumulativeLength[j]
      context.ribbonFloats
        .put(centerX - normal.0 * halfWidth).put(centerY - normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(life).put(-1).put(trail)
      context.ribbonFloats
        .put(centerX + normal.0 * halfWidth).put(centerY + normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(life).put(1).put(trail)
    }
    MetalHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerVineVertex,
      attributes: [
        MetalVertexAttribute(location: vinePosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: vineColor, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: vineCenterDistance, size: 1, offsetBytes: 24),
        MetalVertexAttribute(location: vineTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: MGL_TRIANGLE_STRIP,
      vertexCount: m * 2
    )
  }

  private func spawnFromTrack(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let minDimension = context.minDimension
    guard minDimension > 0 else { return }
    for (_, points) in trackData where points.count >= 4 {
      let point = points.last!.first
      let previous = points[points.count - 2].first
      let x = Float(point.center.x * 2 - 1) * context.quadScaleX
      let y = Float(1 - point.center.y * 2) * context.quadScaleY
      let x1 = Float(previous.center.x * 2 - 1) * context.quadScaleX
      let y1 = Float(1 - previous.center.y * 2) * context.quadScaleY
      let direction = atan2((y - y1) * viewHalfHeight, (x - x1) * viewHalfWidth)
      guard Float.random(in: 0...1) < 0.5 * context.dtScale else { continue }
      let index = min(Int(Float.random(in: 0...1) * Float(points.count) * 0.7), points.count - 1)
      let body = points[index].first
      spawnTumbleLeaf(
        x: Float(body.center.x * 2 - 1) * context.quadScaleX,
        y: Float(1 - body.center.y * 2) * context.quadScaleY,
        direction: direction,
        minDimension: minDimension,
        color: point.color
      )
    }
  }

  private func spawnTumbleLeaf(
    x: Float, y: Float, direction: Float, minDimension: Float, color: UIColor
  ) {
    guard let leaf = leaves.first(where: { !$0.active }) else { return }
    let backward = direction + .pi + Float.random(in: -0.5...0.5)
    let speed = minDimension * Float.random(in: 0.004...0.010)
    let rgb = MetalHelper.rgba(color)
    leaf.active = true
    leaf.x = x + Float.random(in: -0.015...0.015)
    leaf.y = y + Float.random(in: -0.015...0.015)
    leaf.vx = cos(backward) * speed
    leaf.vy = sin(backward) * speed
    leaf.angle = Float.random(in: 0...(2 * .pi))
    leaf.angularVelocity = Float.random(in: 0.12...0.30) * (Bool.random() ? 1 : -1)
    leaf.lengthPx = minDimension * Float.random(in: 0.018...0.034)
    leaf.widthPx = leaf.lengthPx * Float.random(in: 0.45...0.70)
    leaf.alpha = 0.9
    leaf.decay = Float.random(in: 0.025...0.045)
    let multiplier: Float = Bool.random() ? 0.45 : 1
    leaf.r = rgb.0 * multiplier
    leaf.g = rgb.1 * multiplier
    leaf.b = rgb.2 * multiplier
  }

  private func updateLeaves(context: MetalRenderContext) {
    let dt = context.dtScale
    for leaf in leaves where leaf.active {
      leaf.x += leaf.vx * dt / viewHalfWidth
      leaf.y += leaf.vy * dt / viewHalfHeight
      leaf.vx *= 1 - 0.02 * dt
      leaf.vy *= 1 - 0.02 * dt
      leaf.angle += leaf.angularVelocity * dt
      leaf.alpha -= leaf.decay * dt
      if leaf.alpha <= 0 { leaf.active = false }
    }
  }

  private func drawLeafQuads() {
    leafFloats.clear()
    var count = 0
    for leaf in leaves where leaf.active {
      emitLeafQuad(leaf)
      count += 1
    }
    guard count > 0 else { return }
    metalUseProgram(leafProgram)
    MetalHelper.drawInterleaved(
      buffer: leafFloats,
      strideBytes: Self.bytesPerLeafVertex,
      attributes: [
        MetalVertexAttribute(location: leafPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: leafUV, size: 2, offsetBytes: 8),
        MetalVertexAttribute(location: leafColor, size: 4, offsetBytes: 16),
      ],
      mode: MGL_TRIANGLES,
      vertexCount: count * 6
    )
  }

  private func emitLeafQuad(_ leaf: Leaf) {
    let cosine = cos(leaf.angle)
    let sine = sin(leaf.angle)
    let halfLength = leaf.lengthPx * 0.5
    let halfWidth = leaf.widthPx * 0.5
    let alpha = leaf.alpha.metalClamped()
    func position(_ u: Float, _ v: Float) -> (Float, Float) {
      let localX = u * halfLength
      let localY = v * halfWidth
      return (
        leaf.x + (localX * cosine - localY * sine) / viewHalfWidth,
        leaf.y + (localX * sine + localY * cosine) / viewHalfHeight
      )
    }
    let a = position(-1, -1)
    let b = position(1, -1)
    let c = position(1, 1)
    let d = position(-1, 1)
    func put(_ p: (Float, Float), _ u: Float, _ v: Float) {
      leafFloats.put(p.0).put(p.1).put(u).put(v).put(leaf.r).put(leaf.g).put(leaf.b).put(alpha)
    }
    put(a, -1, -1)
    put(b, 1, -1)
    put(c, 1, 1)
    put(a, -1, -1)
    put(c, 1, 1)
    put(d, -1, 1)
  }

  private func drawTreeRings(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let minDimension = context.minDimension
    guard minDimension > 0 else { return }
    ringFloats.clear()
    var vertexCount = 0
    var heads = 0
    for (_, points) in trackData where !points.isEmpty && heads < Self.maxHeads {
      heads += 1
      let point = points.last!.first
      let centerX = Float(point.center.x * 2 - 1) * context.quadScaleX
      let centerY = Float(1 - point.center.y * 2) * context.quadScaleY
      let color = MetalHelper.rgba(point.color)
      let pulse = 0.92 + 0.08 * sin(time * 1.5)
      for ring in 0..<Self.ringCount {
        let radius = minDimension * (0.045 + Float(ring) * 0.038) * pulse
        let alpha = Self.ringAlpha * (1 - Float(ring) / Float(Self.ringCount) * 0.5)
        var previousX: Float = 0
        var previousY: Float = 0
        for segment in 0...Self.ringSegments {
          let direction: Float = ring.isMultiple(of: 2) ? 1 : -1
          let angle =
            2 * Float.pi * Float(segment) / Float(Self.ringSegments) + time * 0.2 * direction
          let x = centerX + cos(angle) * radius / viewHalfWidth
          let y = centerY + sin(angle) * radius / viewHalfHeight
          if segment > 0 {
            ringFloats.put(previousX).put(previousY).put(color.0).put(color.1).put(color.2).put(
              alpha)
            ringFloats.put(x).put(y).put(color.0).put(color.1).put(color.2).put(alpha)
            vertexCount += 2
          }
          previousX = x
          previousY = y
        }
      }
    }
    guard vertexCount > 0 else { return }
    metalUseProgram(ringProgram)
    metalLineWidth(2)
    MetalHelper.drawInterleaved(
      buffer: ringFloats,
      strideBytes: Self.bytesPerLine,
      attributes: [
        MetalVertexAttribute(location: ringPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: ringColor, size: 4, offsetBytes: 8),
      ],
      mode: MGL_LINES,
      vertexCount: vertexCount
    )
  }
}
