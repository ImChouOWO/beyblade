import UIKit

/// Direct Swift/Metal port of DeathRayMetalEffect.kt.
final class DeathRayMetalEffect: MetalEffect {
  private static let bytesPerPoint = 28
  private static let bytesPerLine = 24
  private static let bytesPerBeamVertex = 32
  private static let maxTrailPoints = 256
  private static let maxResample = 64
  private static let maxHeads = 8
  private static let maxArcVertices = 1024
  private static let vortexPerFrame: Float = 4
  private static let arcsPerHead = 5
  private static let arcSegments = 4
  private static let hazeSpawnRate: Float = 0.9
  private static let beamHalfWidth: Float = 0.055
  private static let timeWrap: Float = 120

  private var beamProgram: MetalProgramID = 0
  private var beamPosition: MetalLocation = -1
  private var beamColor: MetalLocation = -1
  private var beamCenterDistance: MetalLocation = -1
  private var beamTrailDistance: MetalLocation = -1
  private var beamTime: MetalLocation = -1
  private var beamTint: MetalLocation = -1

  private var pointProgram: MetalProgramID = 0
  private var pointPosition: MetalLocation = -1
  private var pointColor: MetalLocation = -1
  private var pointSize: MetalLocation = -1

  private var lineProgram: MetalProgramID = 0
  private var linePosition: MetalLocation = -1
  private var lineColor: MetalLocation = -1

  private final class Vortex {
    var active = false
    var centerX: Float = 0
    var centerY: Float = 0
    var angle: Float = 0
    var radiusPx: Float = 0
    var angularVelocity: Float = 0
    var inwardVelocityPx: Float = 0
    var spawnRadiusPx: Float = 1
    var sizePx: Float = 4
    var r: Float = 0.8
    var g: Float = 0.92
    var b: Float = 1
  }
  private final class Haze {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var sizePx: Float = 30
    var alpha: Float = 0
  }

  private let vortices = (0..<64).map { _ in Vortex() }
  private let hazes = (0..<24).map { _ in Haze() }
  private let vortexFloats = MetalFloatBuffer(capacity: 64 * 7)
  private let hazeFloats = MetalFloatBuffer(capacity: 24 * 7)
  private let coreFloats = MetalFloatBuffer(capacity: maxHeads * 3 * 7)
  private let arcFloats = MetalFloatBuffer(capacity: maxArcVertices * 6)

  private var time: Float = 0
  private var hazeAccumulator: Float = 0
  private var viewHalfWidth: Float = 1
  private var viewHalfHeight: Float = 1
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var resampledX = [Float](repeating: 0, count: maxResample)
  private var resampledY = [Float](repeating: 0, count: maxResample)
  private var resampledAlpha = [Float](repeating: 0, count: maxResample)
  private var cumulativeLength = [Float](repeating: 0, count: maxResample)

  override func onMetalReady(context: MetalRenderContext) {
    beamProgram = MetalHelper.makeProgram(.deathBeam)
    beamPosition = metalGetAttribLocation(beamProgram, "aPosition")
    beamColor = metalGetAttribLocation(beamProgram, "aColor")
    beamCenterDistance = metalGetAttribLocation(beamProgram, "aCenterDist")
    beamTrailDistance = metalGetAttribLocation(beamProgram, "aTrailDist")
    beamTime = metalGetUniformLocation(beamProgram, "uTime")
    beamTint = metalGetUniformLocation(beamProgram, "uTint")

    pointProgram = MetalHelper.makeProgram(.deathPoint)
    pointPosition = metalGetAttribLocation(pointProgram, "aPosition")
    pointColor = metalGetAttribLocation(pointProgram, "aColor")
    pointSize = metalGetAttribLocation(pointProgram, "aSize")

    lineProgram = MetalHelper.makeProgram(.flatColor)
    linePosition = metalGetAttribLocation(lineProgram, "aPosition")
    lineColor = metalGetAttribLocation(lineProgram, "aColor")
  }

  override func draw(trackData: MetalTrackData, context: MetalRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    viewHalfWidth = max(Float(context.viewWidth) * 0.5, 1)
    viewHalfHeight = max(Float(context.viewHeight) * 0.5, 1)

    metalBlendFunc(MGL_SRC_ALPHA, MGL_ONE)
    spawnHaze(trackData, context: context)
    updateHaze(dt: context.dtScale)
    drawPoints(hazeFloats, source: hazes)

    metalUseProgram(beamProgram)
    metalUniform1f(beamTime, time)
    for (_, points) in trackData where points.count >= 3 {
      let tint = MetalHelper.rgba(points.last!.first.color)
      metalUniform3f(beamTint, tint.0, tint.1, tint.2)
      drawBeam(points, context: context)
    }

    spawnVortex(trackData, context: context)
    updateVortex(context: context)
    drawVortexPoints()
    drawCoreAndArcs(trackData, context: context)
    metalBlendFunc(MGL_SRC_ALPHA, MGL_ONE_MINUS_SRC_ALPHA)
  }

  private func drawBeam(_ points: [MetalTrailSample], context: MetalRenderContext) {
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
      cumulativeLength[j] =
        j == 0
        ? 0
        : cumulativeLength[j - 1]
          + hypot(resampledX[j] - resampledX[j - 1], resampledY[j] - resampledY[j - 1])
    }
    guard m * 2 * Self.bytesPerBeamVertex <= context.ribbonFloats.capacityBytes else { return }
    let total = cumulativeLength[m - 1]
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
      let life = resampledAlpha[j]
      let halfWidth = Self.beamHalfWidth * (0.72 + 0.28 * life)
      let trail = total - cumulativeLength[j]
      context.ribbonFloats.put(x - normal.0 * halfWidth).put(y - normal.1 * halfWidth).put(1).put(1)
        .put(1).put(life).put(-1).put(trail)
      context.ribbonFloats.put(x + normal.0 * halfWidth).put(y + normal.1 * halfWidth).put(1).put(1)
        .put(1).put(life).put(1).put(trail)
    }
    MetalHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerBeamVertex,
      attributes: [
        MetalVertexAttribute(location: beamPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: beamColor, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: beamCenterDistance, size: 1, offsetBytes: 24),
        MetalVertexAttribute(location: beamTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: MGL_TRIANGLE_STRIP, vertexCount: m * 2
    )
  }

  private func spawnVortex(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let minDimension = context.minDimension
    guard minDimension > 0 else { return }
    for (_, points) in trackData where !points.isEmpty {
      let point = points.last!.first
      let centerX = Float(point.center.x * 2 - 1) * context.quadScaleX
      let centerY = Float(1 - point.center.y * 2) * context.quadScaleY
      var count = Self.vortexPerFrame * context.dtScale
      while count > 0 {
        if count < 1, Float.random(in: 0...1) > count { break }
        spawnOneVortex(
          centerX: centerX, centerY: centerY, minDimension: minDimension, color: point.color)
        count -= 1
      }
    }
  }

  private func spawnOneVortex(centerX: Float, centerY: Float, minDimension: Float, color: UIColor) {
    guard let vortex = vortices.first(where: { !$0.active }) else { return }
    let rgb = MetalHelper.rgba(color)
    vortex.active = true
    vortex.centerX = centerX
    vortex.centerY = centerY
    vortex.angle = Float.random(in: 0...(2 * .pi))
    vortex.spawnRadiusPx = minDimension * Float.random(in: 0.07...0.13)
    vortex.radiusPx = vortex.spawnRadiusPx
    vortex.angularVelocity = Float.random(in: 0.16...0.28)
    vortex.inwardVelocityPx = minDimension * Float.random(in: 0.009...0.015)
    vortex.sizePx = Float.random(in: 3...6)
    if Double.random(in: 0...1) < 0.35 {
      (vortex.r, vortex.g, vortex.b) = (1, 1, 1)
    } else {
      (vortex.r, vortex.g, vortex.b) = (rgb.0, rgb.1, rgb.2)
    }
  }

  private func updateVortex(context: MetalRenderContext) {
    let dt = context.dtScale
    let threshold = context.minDimension * 0.010
    for vortex in vortices where vortex.active {
      vortex.inwardVelocityPx *= 1 + 0.05 * dt
      vortex.radiusPx -= vortex.inwardVelocityPx * dt
      vortex.angle += vortex.angularVelocity * dt
      if vortex.radiusPx <= threshold { vortex.active = false }
    }
  }

  private func drawVortexPoints() {
    vortexFloats.clear()
    var count = 0
    for vortex in vortices where vortex.active {
      let x = vortex.centerX + cos(vortex.angle) * vortex.radiusPx / viewHalfWidth
      let y = vortex.centerY + sin(vortex.angle) * vortex.radiusPx / viewHalfHeight
      let t = (1 - vortex.radiusPx / vortex.spawnRadiusPx).metalClamped()
      vortexFloats.put(x).put(y).put(vortex.r).put(vortex.g).put(vortex.b).put(0.35 + 0.65 * t).put(
        vortex.sizePx * (1 - 0.4 * t))
      count += 1
    }
    drawPointBuffer(vortexFloats, count: count)
  }

  private func drawCoreAndArcs(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let minDimension = context.minDimension
    coreFloats.clear()
    arcFloats.clear()
    var coreCount = 0
    var arcVertexCount = 0
    var headCount = 0
    for (_, points) in trackData where !points.isEmpty && headCount < Self.maxHeads {
      headCount += 1
      let point = points.last!.first
      let centerX = Float(point.center.x * 2 - 1) * context.quadScaleX
      let centerY = Float(1 - point.center.y * 2) * context.quadScaleY
      let tint = MetalHelper.rgba(point.color)
      let jitterX = Float.random(in: -0.5...0.5) * minDimension * 0.010 / viewHalfWidth
      let jitterY = Float.random(in: -0.5...0.5) * minDimension * 0.010 / viewHalfHeight
      let flicker = Float.random(in: 0.7...1.3)
      coreFloats.put(centerX + jitterX).put(centerY + jitterY).put(tint.0).put(tint.1).put(tint.2)
        .put(0.9).put(minDimension * 0.075 * flicker)
      coreCount += 1
      coreFloats.put(centerX + jitterX).put(centerY + jitterY).put(1).put(1).put(1).put(1).put(
        minDimension * 0.030 * flicker)
      coreCount += 1
      if Bool.random() {
        coreFloats.put(centerX).put(centerY).put(1).put(1).put(1).put(0.8).put(
          minDimension * 0.11 * flicker)
        coreCount += 1
      }
      for _ in 0..<Self.arcsPerHead {
        guard arcVertexCount + Self.arcSegments * 2 <= Self.maxArcVertices else { break }
        var x = centerX
        var y = centerY
        var angle = Float.random(in: 0...(2 * .pi))
        let segmentLength = minDimension * Float.random(in: 0.018...0.038)
        for segment in 0..<Self.arcSegments {
          angle += Float.random(in: -0.8...0.8)
          let nextX = x + cos(angle) * segmentLength / viewHalfWidth
          let nextY = y + sin(angle) * segmentLength / viewHalfHeight
          let fade = 1 - Float(segment) / Float(Self.arcSegments)
          let r = tint.0 * 0.4 + 0.6
          let g = tint.1 * 0.4 + 0.6
          let b = tint.2 * 0.4 + 0.6
          arcFloats.put(x).put(y).put(r).put(g).put(b).put(0.85 * fade)
          arcFloats.put(nextX).put(nextY).put(r).put(g).put(b).put(
            0.85 * (1 - Float(segment + 1) / Float(Self.arcSegments)))
          arcVertexCount += 2
          x = nextX
          y = nextY
        }
      }
    }
    drawPointBuffer(coreFloats, count: coreCount)
    guard arcVertexCount > 0 else { return }
    metalUseProgram(lineProgram)
    metalLineWidth(2)
    MetalHelper.drawInterleaved(
      buffer: arcFloats,
      strideBytes: Self.bytesPerLine,
      attributes: [
        MetalVertexAttribute(location: linePosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: lineColor, size: 4, offsetBytes: 8),
      ],
      mode: MGL_LINES, vertexCount: arcVertexCount
    )
  }

  private func spawnHaze(_ trackData: MetalTrackData, context: MetalRenderContext) {
    let tracks = Array(trackData.values).filter { $0.count >= 2 }
    guard !tracks.isEmpty else { return }
    hazeAccumulator += Self.hazeSpawnRate * context.dtScale
    while hazeAccumulator >= 1 {
      hazeAccumulator -= 1
      let points = tracks.randomElement()!
      let point = points.randomElement()!.first
      guard let haze = hazes.first(where: { !$0.active }) else { break }
      haze.active = true
      haze.x = Float(point.center.x * 2 - 1) * context.quadScaleX + Float.random(in: -0.025...0.025)
      haze.y = Float(1 - point.center.y * 2) * context.quadScaleY + Float.random(in: -0.025...0.025)
      haze.sizePx = context.minDimension * Float.random(in: 0.04...0.07)
      haze.alpha = 0.08
    }
  }

  private func updateHaze(dt: Float) {
    for haze in hazes where haze.active {
      haze.sizePx *= 1 + 0.012 * dt
      haze.alpha -= 0.0020 * dt
      if haze.alpha <= 0 { haze.active = false }
    }
  }

  private func drawPoints(_ buffer: MetalFloatBuffer, source: [Haze]) {
    buffer.clear()
    var count = 0
    for haze in source where haze.active {
      buffer.put(haze.x).put(haze.y).put(0.80).put(0.90).put(1).put(haze.alpha.metalClamped()).put(
        haze.sizePx)
      count += 1
    }
    drawPointBuffer(buffer, count: count)
  }

  private func drawPointBuffer(_ buffer: MetalFloatBuffer, count: Int) {
    guard count > 0 else { return }
    metalUseProgram(pointProgram)
    MetalHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: Self.bytesPerPoint,
      attributes: [
        MetalVertexAttribute(location: pointPosition, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: pointColor, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: pointSize, size: 1, offsetBytes: 24),
      ],
      mode: MGL_POINTS, vertexCount: count
    )
  }
}
