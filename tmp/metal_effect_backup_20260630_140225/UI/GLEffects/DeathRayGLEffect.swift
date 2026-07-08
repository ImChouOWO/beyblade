import OpenGLES
import UIKit

/// Direct Swift/OpenGL ES port of DeathRayGLEffect.kt.
final class DeathRayGLEffect: GLEffect {
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

  private var beamProgram: GLuint = 0
  private var beamPosition: GLint = -1
  private var beamColor: GLint = -1
  private var beamCenterDistance: GLint = -1
  private var beamTrailDistance: GLint = -1
  private var beamTime: GLint = -1
  private var beamTint: GLint = -1

  private var pointProgram: GLuint = 0
  private var pointPosition: GLint = -1
  private var pointColor: GLint = -1
  private var pointSize: GLint = -1

  private var lineProgram: GLuint = 0
  private var linePosition: GLint = -1
  private var lineColor: GLint = -1

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
  private let vortexFloats = GLFloatBuffer(capacity: 64 * 7)
  private let hazeFloats = GLFloatBuffer(capacity: 24 * 7)
  private let coreFloats = GLFloatBuffer(capacity: maxHeads * 3 * 7)
  private let arcFloats = GLFloatBuffer(capacity: maxArcVertices * 6)

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

  override func onGLReady(context: GLRenderContext) {
    beamProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.DeathRay.beamVert,
      fragmentSource: GLEffectShaders.DeathRay.beamFrag
    )
    beamPosition = glGetAttribLocation(beamProgram, "aPosition")
    beamColor = glGetAttribLocation(beamProgram, "aColor")
    beamCenterDistance = glGetAttribLocation(beamProgram, "aCenterDist")
    beamTrailDistance = glGetAttribLocation(beamProgram, "aTrailDist")
    beamTime = glGetUniformLocation(beamProgram, "uTime")
    beamTint = glGetUniformLocation(beamProgram, "uTint")

    pointProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.DeathRay.pointVert,
      fragmentSource: GLEffectShaders.DeathRay.pointFrag
    )
    pointPosition = glGetAttribLocation(pointProgram, "aPosition")
    pointColor = glGetAttribLocation(pointProgram, "aColor")
    pointSize = glGetAttribLocation(pointProgram, "aSize")

    lineProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.DeathRay.lineVert,
      fragmentSource: GLEffectShaders.DeathRay.lineFrag
    )
    linePosition = glGetAttribLocation(lineProgram, "aPosition")
    lineColor = glGetAttribLocation(lineProgram, "aColor")
  }

  override func draw(trackData: GLTrackData, context: GLRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    viewHalfWidth = max(Float(context.viewWidth) * 0.5, 1)
    viewHalfHeight = max(Float(context.viewHeight) * 0.5, 1)

    glBlendFunc(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE))
    spawnHaze(trackData, context: context)
    updateHaze(dt: context.dtScale)
    drawPoints(hazeFloats, source: hazes)

    glUseProgram(beamProgram)
    glUniform1f(beamTime, time)
    for (_, points) in trackData where points.count >= 3 {
      let tint = GLHelper.rgba(points.last!.first.color)
      glUniform3f(beamTint, tint.0, tint.1, tint.2)
      drawBeam(points, context: context)
    }

    spawnVortex(trackData, context: context)
    updateVortex(context: context)
    drawVortexPoints()
    drawCoreAndArcs(trackData, context: context)
    glBlendFunc(GLenum(GL_SRC_ALPHA), GLenum(GL_ONE_MINUS_SRC_ALPHA))
  }

  private func drawBeam(_ points: [GLTrailSample], context: GLRenderContext) {
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
        normal = GLHelper.segNormal(x, y, resampledX[1], resampledY[1])
      } else if j == m - 1 {
        normal = GLHelper.segNormal(resampledX[j - 1], resampledY[j - 1], x, y)
      } else {
        normal = GLHelper.avgNormal(
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
    GLHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerBeamVertex,
      attributes: [
        GLVertexAttribute(location: beamPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: beamColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: beamCenterDistance, size: 1, offsetBytes: 24),
        GLVertexAttribute(location: beamTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: GLenum(GL_TRIANGLE_STRIP), vertexCount: m * 2
    )
  }

  private func spawnVortex(_ trackData: GLTrackData, context: GLRenderContext) {
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
    let rgb = GLHelper.rgba(color)
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

  private func updateVortex(context: GLRenderContext) {
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
      let t = (1 - vortex.radiusPx / vortex.spawnRadiusPx).glClamped()
      vortexFloats.put(x).put(y).put(vortex.r).put(vortex.g).put(vortex.b).put(0.35 + 0.65 * t).put(
        vortex.sizePx * (1 - 0.4 * t))
      count += 1
    }
    drawPointBuffer(vortexFloats, count: count)
  }

  private func drawCoreAndArcs(_ trackData: GLTrackData, context: GLRenderContext) {
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
      let tint = GLHelper.rgba(point.color)
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
    glUseProgram(lineProgram)
    glLineWidth(2)
    GLHelper.drawInterleaved(
      buffer: arcFloats,
      strideBytes: Self.bytesPerLine,
      attributes: [
        GLVertexAttribute(location: linePosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: lineColor, size: 4, offsetBytes: 8),
      ],
      mode: GLenum(GL_LINES), vertexCount: arcVertexCount
    )
  }

  private func spawnHaze(_ trackData: GLTrackData, context: GLRenderContext) {
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

  private func drawPoints(_ buffer: GLFloatBuffer, source: [Haze]) {
    buffer.clear()
    var count = 0
    for haze in source where haze.active {
      buffer.put(haze.x).put(haze.y).put(0.80).put(0.90).put(1).put(haze.alpha.glClamped()).put(
        haze.sizePx)
      count += 1
    }
    drawPointBuffer(buffer, count: count)
  }

  private func drawPointBuffer(_ buffer: GLFloatBuffer, count: Int) {
    guard count > 0 else { return }
    glUseProgram(pointProgram)
    GLHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: Self.bytesPerPoint,
      attributes: [
        GLVertexAttribute(location: pointPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: pointColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: pointSize, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_POINTS), vertexCount: count
    )
  }
}
