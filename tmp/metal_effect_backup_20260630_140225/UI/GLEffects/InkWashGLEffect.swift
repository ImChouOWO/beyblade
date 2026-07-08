import OpenGLES
import UIKit

/// Direct Swift/OpenGL ES port of InkWashGLEffect.kt.
/// Keeps the three ink strands, dry-brush shader, droplets and dissolve behavior.
final class InkWashGLEffect: GLEffect {
  private static let bytesPerInkVertex = 32
  private static let bytesPerDrop = 32
  private static let maxTrailPoints = 256
  private static let maxResample = 64
  private static let strandCount = 3
  private static let inkHalfWidth: Float = 0.040
  private static let inkAmplitude: Float = 0.022
  private static let inkFrequency: Float = 1.6
  private static let inkSway: Float = 3.0
  private static let dropRate: Float = 0.25
  private static let timeWrap: Float = 120

  private var inkProgram: GLuint = 0
  private var inkPosition: GLint = -1
  private var inkColor: GLint = -1
  private var inkCenterDistance: GLint = -1
  private var inkTrailDistance: GLint = -1
  private var inkTime: GLint = -1
  private var inkStrandAlpha: GLint = -1

  private var dropProgram: GLuint = 0
  private var dropPosition: GLint = -1
  private var dropColor: GLint = -1
  private var dropSize: GLint = -1
  private var dropDissolve: GLint = -1

  private final class Drop {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var sizePx: Float = 6
    var grow: Float = 0.02
    var age: Float = 0
    var life: Float = 30
    var r: Float = 0.2
    var g: Float = 0.2
    var b: Float = 0.2
  }

  private let drops = (0..<32).map { _ in Drop() }
  private let dropFloats = GLFloatBuffer(capacity: 32 * 8)
  private var time: Float = 0
  private var viewHalfWidth: Float = 1
  private var viewHalfHeight: Float = 1
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var resampledX = [Float](repeating: 0, count: maxResample)
  private var resampledY = [Float](repeating: 0, count: maxResample)
  private var resampledAlpha = [Float](repeating: 0, count: maxResample)
  private var cumulativeLength = [Float](repeating: 0, count: maxResample)

  override func onGLReady(context: GLRenderContext) {
    inkProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.InkWash.inkVert,
      fragmentSource: GLEffectShaders.InkWash.inkFrag
    )
    inkPosition = glGetAttribLocation(inkProgram, "aPosition")
    inkColor = glGetAttribLocation(inkProgram, "aColor")
    inkCenterDistance = glGetAttribLocation(inkProgram, "aCenterDist")
    inkTrailDistance = glGetAttribLocation(inkProgram, "aTrailDist")
    inkTime = glGetUniformLocation(inkProgram, "uTime")
    inkStrandAlpha = glGetUniformLocation(inkProgram, "uStrandAlpha")

    dropProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.InkWash.dropVert,
      fragmentSource: GLEffectShaders.InkWash.dropFrag
    )
    dropPosition = glGetAttribLocation(dropProgram, "aPosition")
    dropColor = glGetAttribLocation(dropProgram, "aColor")
    dropSize = glGetAttribLocation(dropProgram, "aSize")
    dropDissolve = glGetAttribLocation(dropProgram, "aDissolve")
  }

  override func draw(trackData: GLTrackData, context: GLRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }
    viewHalfWidth = max(Float(context.viewWidth) * 0.5, 1)
    viewHalfHeight = max(Float(context.viewHeight) * 0.5, 1)

    glUseProgram(inkProgram)
    glUniform1f(inkTime, time)
    for (_, points) in trackData where points.count >= 3 {
      for strand in stride(from: Self.strandCount - 1, through: 0, by: -1) {
        drawInkStrand(points, context: context, strand: strand)
      }
    }
    spawnDrops(trackData, context: context)
    updateDrops(context: context)
    drawDrops()
  }

  private func drawInkStrand(_ points: [GLTrailSample], context: GLRenderContext, strand: Int) {
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
          + hypot(
            resampledX[j] - resampledX[j - 1],
            resampledY[j] - resampledY[j - 1]
          )
      }
    }
    guard m * 2 * Self.bytesPerInkVertex <= context.ribbonFloats.capacityBytes else { return }
    let total = cumulativeLength[m - 1]
    let color = GLHelper.rgba(points[n - 1].first.color)
    let isMain = strand == 0
    let baseHalfWidth = isMain ? Self.inkHalfWidth : Self.inkHalfWidth * 0.16
    let side: Float = strand.isMultiple(of: 2) ? -1 : 1
    let amplitudeMultiplier: Float = isMain ? 0.30 : 1
    let phase = Float(strand) * 1.7
    glUniform1f(inkStrandAlpha, isMain ? 1 : 0.45)

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
      let wave = sin(u * Self.inkFrequency * 2 * .pi + phase - time * Self.inkSway)
      let offset =
        wave * Self.inkAmplitude * amplitudeMultiplier * (1 - 0.4 * u)
        + side * baseHalfWidth * (isMain ? 0 : 2.2)
      let halfWidth = baseHalfWidth * (0.30 + 0.70 * life)
      let centerX = x + normal.0 * offset
      let centerY = y + normal.1 * offset
      let trail = total - cumulativeLength[j]
      context.ribbonFloats
        .put(centerX - normal.0 * halfWidth).put(centerY - normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(life).put(-1).put(trail)
      context.ribbonFloats
        .put(centerX + normal.0 * halfWidth).put(centerY + normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(life).put(1).put(trail)
    }
    GLHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerInkVertex,
      attributes: [
        GLVertexAttribute(location: inkPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: inkColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: inkCenterDistance, size: 1, offsetBytes: 24),
        GLVertexAttribute(location: inkTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: GLenum(GL_TRIANGLE_STRIP),
      vertexCount: m * 2
    )
  }

  private func spawnDrops(_ trackData: GLTrackData, context: GLRenderContext) {
    let minDimension = context.minDimension
    guard minDimension > 0 else { return }
    for (_, points) in trackData where points.count >= 3 {
      guard Float.random(in: 0...1) < Self.dropRate * context.dtScale else { continue }
      let index = min(Int(Float.random(in: 0...1) * Float(points.count) * 0.7), points.count - 1)
      let point = points[index].first
      spawnOneDrop(
        x: Float(point.center.x * 2 - 1) * context.quadScaleX,
        y: Float(1 - point.center.y * 2) * context.quadScaleY,
        minDimension: minDimension,
        color: points.last!.first.color
      )
    }
  }

  private func spawnOneDrop(x: Float, y: Float, minDimension: Float, color: UIColor) {
    guard let drop = drops.first(where: { !$0.active }) else { return }
    let angle = Float.random(in: 0...(2 * .pi))
    let speed = minDimension * Float.random(in: 0.002...0.006)
    let rgb = GLHelper.rgba(color)
    drop.active = true
    drop.x = x + Float.random(in: -0.01...0.01)
    drop.y = y + Float.random(in: -0.01...0.01)
    drop.vx = cos(angle) * speed
    drop.vy = sin(angle) * speed
    drop.sizePx = minDimension * Float.random(in: 0.006...0.016)
    drop.grow = Float.random(in: 0.015...0.035)
    drop.age = 0
    drop.life = Float.random(in: 18...34)
    drop.r = rgb.0 * 0.6
    drop.g = rgb.1 * 0.6
    drop.b = rgb.2 * 0.6
  }

  private func updateDrops(context: GLRenderContext) {
    let dt = context.dtScale
    for drop in drops where drop.active {
      drop.x += drop.vx * dt / viewHalfWidth
      drop.y += drop.vy * dt / viewHalfHeight
      drop.vx *= 1 - 0.04 * dt
      drop.vy *= 1 - 0.04 * dt
      drop.sizePx *= 1 + drop.grow * dt
      drop.age += dt
      if drop.age >= drop.life { drop.active = false }
    }
  }

  private func drawDrops() {
    dropFloats.clear()
    var count = 0
    for drop in drops where drop.active {
      let dissolve = (drop.age / drop.life).glClamped()
      let alpha = (1 - dissolve) * 0.9
      dropFloats
        .put(drop.x).put(drop.y)
        .put(drop.r).put(drop.g).put(drop.b).put(alpha)
        .put(drop.sizePx).put(dissolve)
      count += 1
    }
    guard count > 0 else { return }
    glUseProgram(dropProgram)
    GLHelper.drawInterleaved(
      buffer: dropFloats,
      strideBytes: Self.bytesPerDrop,
      attributes: [
        GLVertexAttribute(location: dropPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: dropColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: dropSize, size: 1, offsetBytes: 24),
        GLVertexAttribute(location: dropDissolve, size: 1, offsetBytes: 28),
      ],
      mode: GLenum(GL_POINTS),
      vertexCount: count
    )
  }
}
