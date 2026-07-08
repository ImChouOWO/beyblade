import OpenGLES
import UIKit

/// Direct Swift/OpenGL ES port of CrimsonLotusGLEffect.kt.
final class CrimsonLotusGLEffect: GLEffect {
  private static let bytesPerPoint = 28
  private static let bytesPerFireVertex = 32
  private static let maxTrailPoints = 256
  private static let maxResample = 64
  private static let tongueHalfWidth: Float = 0.034
  private static let serpentAmplitude: Float = 0.024
  private static let twistFrequency: Float = 2.4
  private static let wriggleSpeed: Float = 8.5
  private static let timeWrap: Float = 120

  private var fireProgram: GLuint = 0
  private var firePosition: GLint = -1
  private var fireColor: GLint = -1
  private var fireCenterDistance: GLint = -1
  private var fireTrailDistance: GLint = -1
  private var fireTime: GLint = -1

  private var polygonProgram: GLuint = 0
  private var polygonPosition: GLint = -1
  private var polygonColor: GLint = -1
  private var polygonCenterDistance: GLint = -1

  private var hazeProgram: GLuint = 0
  private var hazePosition: GLint = -1
  private var hazeColor: GLint = -1
  private var hazeSize: GLint = -1

  private final class Fireball {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var grow: Float = 1
    var scale: Float = 1
    var alpha: Float = 0
    var decay: Float = 0.09
    var vertexCount = 5
    var offsetX = [Float](repeating: 0, count: 6)
    var offsetY = [Float](repeating: 0, count: 6)
    var r: Float = 1
    var g: Float = 0.4
    var b: Float = 0.1
  }
  private final class Ember {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var sizePx: Float = 3
    var alpha: Float = 0
    var decay: Float = 0.06
    var r: Float = 1
    var g: Float = 0.5
    var b: Float = 0.1
  }
  private final class Haze {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var sizePx: Float = 30
    var alpha: Float = 0
  }

  private let fireballs = (0..<16).map { _ in Fireball() }
  private let embers = (0..<24).map { _ in Ember() }
  private let hazes = (0..<20).map { _ in Haze() }
  private let polygonFloats = GLFloatBuffer(capacity: 16 * 18 * 7)
  private let emberFloats = GLFloatBuffer(capacity: 24 * 7)
  private let hazeFloats = GLFloatBuffer(capacity: 20 * 7)
  private var lastPosition: [Int: (Float, Float)] = [:]
  private var time: Float = 0
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var resampledX = [Float](repeating: 0, count: maxResample)
  private var resampledY = [Float](repeating: 0, count: maxResample)
  private var resampledAlpha = [Float](repeating: 0, count: maxResample)
  private var cumulativeLength = [Float](repeating: 0, count: maxResample)

  override func onGLReady(context: GLRenderContext) {
    fireProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.CrimsonLotus.fireVert,
      fragmentSource: GLEffectShaders.CrimsonLotus.fireFrag
    )
    firePosition = glGetAttribLocation(fireProgram, "aPosition")
    fireColor = glGetAttribLocation(fireProgram, "aColor")
    fireCenterDistance = glGetAttribLocation(fireProgram, "aCenterDist")
    fireTrailDistance = glGetAttribLocation(fireProgram, "aTrailDist")
    fireTime = glGetUniformLocation(fireProgram, "uTime")

    polygonProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.CrimsonLotus.polyVert,
      fragmentSource: GLEffectShaders.CrimsonLotus.polyFrag
    )
    polygonPosition = glGetAttribLocation(polygonProgram, "aPosition")
    polygonColor = glGetAttribLocation(polygonProgram, "aColor")
    polygonCenterDistance = glGetAttribLocation(polygonProgram, "aCenterDist")

    hazeProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.CrimsonLotus.hazeVert,
      fragmentSource: GLEffectShaders.CrimsonLotus.hazeFrag
    )
    hazePosition = glGetAttribLocation(hazeProgram, "aPosition")
    hazeColor = glGetAttribLocation(hazeProgram, "aColor")
    hazeSize = glGetAttribLocation(hazeProgram, "aSize")
  }

  override func draw(trackData: GLTrackData, context: GLRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    updateHaze(dt: context.dtScale)
    drawPointPool(hazeFloats, count: fillHazeBuffer())

    glUseProgram(fireProgram)
    glUniform1f(fireTime, time)
    for (_, points) in trackData where points.count >= 3 {
      drawFireTongues(points, context: context)
    }
    spawnFromTrack(trackData, context: context)
    updateFireballs(context: context)
    drawFireballs(context: context)
    updateEmbers(context: context)
    drawEmbers()
  }

  private func drawFireTongues(_ points: [GLTrailSample], context: GLRenderContext) {
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
    guard m * 2 * Self.bytesPerFireVertex <= context.ribbonFloats.capacityBytes else { return }
    let total = cumulativeLength[m - 1]
    let color = GLHelper.rgba(points.last!.first.color)
    for strand in 0..<2 {
      let phase = Float(strand) * .pi
      let widthMultiplier: Float = strand == 0 ? 1 : 0.62
      let alphaMultiplier: Float = strand == 0 ? 1 : 0.7
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
        let u = Float(j) / Float(m - 1)
        let life = resampledAlpha[j]
        let wave = sin(u * Self.twistFrequency * 2 * .pi + phase - time * Self.wriggleSpeed)
        let offset = wave * Self.serpentAmplitude * (1 - u)
        let halfWidth = Self.tongueHalfWidth * widthMultiplier * (0.30 + 0.70 * life)
        let centerX = x + normal.0 * offset
        let centerY = y + normal.1 * offset
        let alpha = life * alphaMultiplier
        let trail = total - cumulativeLength[j]
        context.ribbonFloats.put(centerX - normal.0 * halfWidth).put(centerY - normal.1 * halfWidth)
          .put(color.0).put(color.1).put(color.2).put(alpha).put(-1).put(trail)
        context.ribbonFloats.put(centerX + normal.0 * halfWidth).put(centerY + normal.1 * halfWidth)
          .put(color.0).put(color.1).put(color.2).put(alpha).put(1).put(trail)
      }
      GLHelper.drawInterleaved(
        buffer: context.ribbonFloats,
        strideBytes: Self.bytesPerFireVertex,
        attributes: [
          GLVertexAttribute(location: firePosition, size: 2, offsetBytes: 0),
          GLVertexAttribute(location: fireColor, size: 4, offsetBytes: 8),
          GLVertexAttribute(location: fireCenterDistance, size: 1, offsetBytes: 24),
          GLVertexAttribute(location: fireTrailDistance, size: 1, offsetBytes: 28),
        ],
        mode: GLenum(GL_TRIANGLE_STRIP), vertexCount: m * 2
      )
    }
  }

  private func spawnFromTrack(_ trackData: GLTrackData, context: GLRenderContext) {
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
      let movement = hypot(x - x1, y - y1)

      if points.count >= 4, Float.random(in: 0...1) < 0.55 * context.dtScale {
        let index = min(Int(Float.random(in: 0...1) * Float(points.count) * 0.6), points.count - 1)
        let body = points[index].first
        spawnEmber(
          x: Float(body.center.x * 2 - 1) * context.quadScaleX,
          y: Float(1 - body.center.y * 2) * context.quadScaleY,
          color: point.color
        )
      }
      let distance =
        lastPosition[trackID].map { hypot(x - $0.0, y - $0.1) } ?? .greatestFiniteMagnitude
      guard distance > 0.006 else { continue }
      lastPosition[trackID] = (x, y)
      let normalized = movement / context.dtScale
      if normalized > 0.010, Double.random(in: 0...1) > 0.4 {
        spawnFireball(x: x, y: y, minDimension: minDimension, big: false, color: point.color)
      }
      if normalized > 0.016 {
        for _ in 0..<3 {
          spawnFireball(x: x, y: y, minDimension: minDimension, big: true, color: point.color)
        }
      }
    }
  }

  private func spawnFireball(x: Float, y: Float, minDimension: Float, big: Bool, color: UIColor) {
    guard let fireball = fireballs.first(where: { !$0.active }) else { return }
    let angle = Float.random(in: 0...(2 * .pi))
    let speed = big ? Float.random(in: 8...16) : Float.random(in: 4...9)
    fireball.active = true
    fireball.x = x + Float.random(in: -0.0075...0.0075)
    fireball.y = y + Float.random(in: -0.0075...0.0075)
    fireball.vx = cos(angle) * speed
    fireball.vy = sin(angle) * speed
    fireball.scale = 1
    fireball.grow = big ? 0.17 : 0.12
    fireball.alpha = 1
    fireball.decay = Float.random(in: 0.08...0.12)
    let baseRadius =
      big
      ? minDimension * Float.random(in: 0.012...0.020)
      : minDimension * Float.random(in: 0.006...0.010)
    fireball.vertexCount = Int.random(in: 4...6)
    for index in 0..<fireball.vertexCount {
      let direction = 2 * Float.pi * Float(index) / Float(fireball.vertexCount)
      let radius = baseRadius * Float.random(in: 0.5...1.3)
      fireball.offsetX[index] = cos(direction) * radius
      fireball.offsetY[index] = sin(direction) * radius
    }
    let source = GLHelper.rgba(color)
    switch Int.random(in: 0...2) {
    case 0: (fireball.r, fireball.g, fireball.b) = (source.0 * 0.6, source.1 * 0.6, source.2 * 0.6)
    case 1: (fireball.r, fireball.g, fireball.b) = (source.0, source.1, source.2)
    default:
      (fireball.r, fireball.g, fireball.b) = (
        source.0 * 0.5 + 0.5, source.1 * 0.5 + 0.5, source.2 * 0.5 + 0.5
      )
    }
  }

  private func updateFireballs(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    for fireball in fireballs where fireball.active {
      fireball.x += fireball.vx * dt / (width * 0.5)
      fireball.y += fireball.vy * dt / (height * 0.5)
      fireball.vx *= 1 - 0.06 * dt
      fireball.vy *= 1 - 0.06 * dt
      fireball.scale *= 1 + fireball.grow * dt
      fireball.alpha -= fireball.decay * dt
      if fireball.alpha <= 0 {
        fireball.active = false
        spawnHaze(x: fireball.x, y: fireball.y, minDimension: min(width, height))
      }
    }
  }

  private func drawFireballs(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    polygonFloats.clear()
    var vertexCount = 0
    for fireball in fireballs where fireball.active {
      let alpha = fireball.alpha.glClamped()
      let scale = fireball.scale * Float.random(in: 0.94...1.06)
      for index in 0..<fireball.vertexCount {
        let next = (index + 1) % fireball.vertexCount
        polygonFloats.put(fireball.x).put(fireball.y).put(fireball.r).put(fireball.g).put(
          fireball.b
        ).put(alpha).put(0)
        polygonFloats.put(fireball.x + fireball.offsetX[index] * scale / (width * 0.5)).put(
          fireball.y + fireball.offsetY[index] * scale / (height * 0.5)
        ).put(fireball.r).put(fireball.g).put(fireball.b).put(alpha).put(1)
        polygonFloats.put(fireball.x + fireball.offsetX[next] * scale / (width * 0.5)).put(
          fireball.y + fireball.offsetY[next] * scale / (height * 0.5)
        ).put(fireball.r).put(fireball.g).put(fireball.b).put(alpha).put(1)
        vertexCount += 3
      }
    }
    guard vertexCount > 0 else { return }
    glUseProgram(polygonProgram)
    GLHelper.drawInterleaved(
      buffer: polygonFloats,
      strideBytes: Self.bytesPerPoint,
      attributes: [
        GLVertexAttribute(location: polygonPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: polygonColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: polygonCenterDistance, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_TRIANGLES), vertexCount: vertexCount
    )
  }

  private func spawnEmber(x: Float, y: Float, color: UIColor) {
    guard let ember = embers.first(where: { !$0.active }) else { return }
    let source = GLHelper.rgba(color)
    ember.active = true
    ember.x = x + Float.random(in: -0.01...0.01)
    ember.y = y + Float.random(in: -0.01...0.01)
    ember.vx = Float.random(in: -1.5...1.5)
    ember.vy = Float.random(in: 1.5...4)
    ember.sizePx = Float.random(in: 2...4.5)
    ember.alpha = 0.95
    ember.decay = Float.random(in: 0.045...0.085)
    switch Int.random(in: 0...4) {
    case 0, 1: (ember.r, ember.g, ember.b) = (source.0, source.1, source.2)
    case 2, 3:
      (ember.r, ember.g, ember.b) = (
        source.0 * 0.4 + 0.6, source.1 * 0.4 + 0.6, source.2 * 0.4 + 0.6
      )
    default: (ember.r, ember.g, ember.b) = (source.0 * 0.7, source.1 * 0.7, source.2 * 0.7)
    }
  }

  private func updateEmbers(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    for ember in embers where ember.active {
      ember.x += ember.vx * dt / (width * 0.5)
      ember.y += ember.vy * dt / (height * 0.5)
      ember.vx *= 1 - 0.03 * dt
      ember.alpha -= ember.decay * dt
      if ember.alpha <= 0 { ember.active = false }
    }
  }

  private func drawEmbers() {
    emberFloats.clear()
    var count = 0
    for ember in embers where ember.active {
      let alpha = (ember.alpha * Float.random(in: 0.6...1)).glClamped()
      emberFloats.put(ember.x).put(ember.y).put(ember.r).put(ember.g).put(ember.b).put(alpha).put(
        ember.sizePx)
      count += 1
    }
    drawPointPool(emberFloats, count: count)
  }

  private func spawnHaze(x: Float, y: Float, minDimension: Float) {
    guard let haze = hazes.first(where: { !$0.active }) else { return }
    haze.active = true
    haze.x = x
    haze.y = y
    haze.sizePx = minDimension * Float.random(in: 0.035...0.060)
    haze.alpha = 0.10
  }

  private func updateHaze(dt: Float) {
    for haze in hazes where haze.active {
      haze.sizePx *= 1 + 0.010 * dt
      haze.alpha -= 0.0022 * dt
      if haze.alpha <= 0 { haze.active = false }
    }
  }

  private func fillHazeBuffer() -> Int {
    hazeFloats.clear()
    var count = 0
    for haze in hazes where haze.active {
      hazeFloats.put(haze.x).put(haze.y).put(1).put(0.96).put(0.90).put(haze.alpha.glClamped()).put(
        haze.sizePx)
      count += 1
    }
    return count
  }

  private func drawPointPool(_ buffer: GLFloatBuffer, count: Int) {
    guard count > 0 else { return }
    glUseProgram(hazeProgram)
    GLHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: Self.bytesPerPoint,
      attributes: [
        GLVertexAttribute(location: hazePosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: hazeColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: hazeSize, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_POINTS), vertexCount: count
    )
  }
}
