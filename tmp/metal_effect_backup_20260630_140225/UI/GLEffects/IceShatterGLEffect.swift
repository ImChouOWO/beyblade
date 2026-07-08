import OpenGLES
import UIKit

/// Direct Swift/OpenGL ES port of IceShatterGLEffect.kt.
final class IceShatterGLEffect: GLEffect {
  private static let bytesPerVertex = 28
  private static let bytesPerBladeVertex = 32
  private static let bytesPerPoint = 28
  private static let maxTrailPoints = 256
  private static let trailHalfWidth: Float = 0.028
  private static let shardDistance: Float = 0.25
  private static let frostPerFrame: Float = 1.6
  private static let fogRate: Float = 0.7
  private static let iceR: Float = 0.73
  private static let iceG: Float = 0.90
  private static let timeWrap: Float = 120

  private var iceProgram: GLuint = 0
  private var icePosition: GLint = -1
  private var iceColor: GLint = -1
  private var iceCenterDistance: GLint = -1

  private var bladeProgram: GLuint = 0
  private var bladePosition: GLint = -1
  private var bladeColor: GLint = -1
  private var bladeCenterDistance: GLint = -1
  private var bladeTrailDistance: GLint = -1
  private var bladeTime: GLint = -1

  private var fogProgram: GLuint = 0
  private var fogPosition: GLint = -1
  private var fogColor: GLint = -1
  private var fogSize: GLint = -1

  private final class Shard {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var angle: Float = 0
    var spin: Float = 0
    var vertexCount = 3
    var offsetX = [Float](repeating: 0, count: 5)
    var offsetY = [Float](repeating: 0, count: 5)
    var alpha: Float = 0
    var decay: Float = 0.14
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
  }
  private final class Frost {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var sizePx: Float = 4
    var alpha: Float = 0
    var decay: Float = 0.02
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
  }
  private final class Fog {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var sizePx: Float = 30
    var alpha: Float = 0
  }

  private let shards = (0..<64).map { _ in Shard() }
  private let frosts = (0..<56).map { _ in Frost() }
  private let fogs = (0..<16).map { _ in Fog() }
  private let shardFloats = GLFloatBuffer(capacity: 64 * 9 * 7)
  private let frostFloats = GLFloatBuffer(capacity: 56 * 7)
  private let fogFloats = GLFloatBuffer(capacity: 16 * 7)
  private var lastPosition: [Int: (Float, Float)] = [:]
  private var time: Float = 0
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var cumulativeLength = [Float](repeating: 0, count: maxTrailPoints)

  override func onGLReady(context: GLRenderContext) {
    iceProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.IceShatter.iceVert,
      fragmentSource: GLEffectShaders.IceShatter.iceFrag
    )
    icePosition = glGetAttribLocation(iceProgram, "aPosition")
    iceColor = glGetAttribLocation(iceProgram, "aColor")
    iceCenterDistance = glGetAttribLocation(iceProgram, "aCenterDist")

    bladeProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.IceShatter.bladeVert,
      fragmentSource: GLEffectShaders.IceShatter.bladeFrag
    )
    bladePosition = glGetAttribLocation(bladeProgram, "aPosition")
    bladeColor = glGetAttribLocation(bladeProgram, "aColor")
    bladeCenterDistance = glGetAttribLocation(bladeProgram, "aCenterDist")
    bladeTrailDistance = glGetAttribLocation(bladeProgram, "aTrailDist")
    bladeTime = glGetUniformLocation(bladeProgram, "uTime")

    fogProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.IceShatter.fogVert,
      fragmentSource: GLEffectShaders.IceShatter.fogFrag
    )
    fogPosition = glGetAttribLocation(fogProgram, "aPosition")
    fogColor = glGetAttribLocation(fogProgram, "aColor")
    fogSize = glGetAttribLocation(fogProgram, "aSize")
  }

  override func draw(trackData: GLTrackData, context: GLRenderContext, effectType: EffectType) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }

    glUseProgram(bladeProgram)
    glUniform1f(bladeTime, time)
    for (_, points) in trackData where points.count >= 2 {
      drawRibbon(points, context: context)
    }

    spawnFromTrack(trackData, context: context)
    updateShards(context: context)
    drawShards(context: context)

    spawnFrostAndFog(trackData, context: context)
    updateFrost(dt: context.dtScale)
    updateFog(context: context)
    drawFrost()
    drawFog()
  }

  private func drawRibbon(_ points: [GLTrailSample], context: GLRenderContext) {
    let n = min(points.count, Self.maxTrailPoints)
    guard n >= 2, n * 2 * Self.bytesPerBladeVertex <= context.ribbonFloats.capacityBytes else {
      return
    }
    let color = GLHelper.rgba(points.last!.first.color)
    for i in 0..<n {
      pointX[i] = Float(points[i].first.center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - points[i].first.center.y * 2) * context.quadScaleY
      cumulativeLength[i] =
        i == 0
        ? 0 : cumulativeLength[i - 1] + hypot(pointX[i] - pointX[i - 1], pointY[i] - pointY[i - 1])
    }
    context.ribbonFloats.clear()
    for i in 0..<n {
      let x = pointX[i]
      let y = pointY[i]
      let normal: (Float, Float)
      if i == 0 {
        normal = GLHelper.segNormal(x, y, pointX[1], pointY[1])
      } else if i == n - 1 {
        normal = GLHelper.segNormal(pointX[n - 2], pointY[n - 2], x, y)
      } else {
        normal = GLHelper.avgNormal(
          pointX[i - 1], pointY[i - 1], x, y, pointX[i + 1], pointY[i + 1])
      }
      let alpha = points[i].second
      let halfWidth = Self.trailHalfWidth * (0.22 + 0.78 * alpha)
      let jaggedness = (1 - alpha) * 0.18
      let left = halfWidth * (1 + Float.random(in: -0.5...0.5) * jaggedness)
      let right = halfWidth * (1 + Float.random(in: -0.5...0.5) * jaggedness)
      context.ribbonFloats.put(x - normal.0 * left).put(y - normal.1 * left).put(color.0).put(
        color.1
      ).put(color.2).put(alpha).put(-1).put(cumulativeLength[i])
      context.ribbonFloats.put(x + normal.0 * right).put(y + normal.1 * right).put(color.0).put(
        color.1
      ).put(color.2).put(alpha).put(1).put(cumulativeLength[i])
    }
    GLHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerBladeVertex,
      attributes: [
        GLVertexAttribute(location: bladePosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: bladeColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: bladeCenterDistance, size: 1, offsetBytes: 24),
        GLVertexAttribute(location: bladeTrailDistance, size: 1, offsetBytes: 28),
      ],
      mode: GLenum(GL_TRIANGLE_STRIP), vertexCount: n * 2
    )
  }

  private func spawnFrostAndFog(_ trackData: GLTrackData, context: GLRenderContext) {
    let minDimension = context.minDimension
    guard minDimension > 0 else { return }
    for (_, points) in trackData where !points.isEmpty {
      let color = points.last!.first.color
      if points.count >= 3 {
        var count = Self.frostPerFrame * context.dtScale
        while count > 0 {
          if count < 1, Float.random(in: 0...1) > count { break }
          let point = points.randomElement()!.first
          spawnFrost(
            x: Float(point.center.x * 2 - 1) * context.quadScaleX,
            y: Float(1 - point.center.y * 2) * context.quadScaleY,
            minDimension: minDimension,
            color: color
          )
          count -= 1
        }
      }
      if Float.random(in: 0...1) < Self.fogRate * context.dtScale {
        let point = points.last!.first
        spawnFog(
          x: Float(point.center.x * 2 - 1) * context.quadScaleX,
          y: Float(1 - point.center.y * 2) * context.quadScaleY,
          minDimension: minDimension
        )
      }
    }
  }

  private func spawnFrost(x: Float, y: Float, minDimension: Float, color: UIColor) {
    guard let frost = frosts.first(where: { !$0.active }) else { return }
    let source = GLHelper.rgba(color)
    frost.active = true
    frost.x = x + Float.random(in: -0.025...0.025)
    frost.y = y + Float.random(in: -0.025...0.025)
    frost.sizePx = minDimension * Float.random(in: 0.004...0.010)
    frost.alpha = Float.random(in: 0.7...1)
    frost.decay = Float.random(in: 0.012...0.024)
    if Double.random(in: 0...1) > 0.3 {
      frost.r = Self.iceR * 0.6 + source.0 * 0.4
      frost.g = Self.iceG * 0.6 + source.1 * 0.4
      frost.b = 1
    } else {
      (frost.r, frost.g, frost.b) = (1, 1, 1)
    }
  }

  private func spawnFog(x: Float, y: Float, minDimension: Float) {
    guard let fog = fogs.first(where: { !$0.active }) else { return }
    fog.active = true
    fog.x = x + Float.random(in: -0.015...0.015)
    fog.y = y + Float.random(in: -0.015...0.015)
    fog.vx = Float.random(in: -0.5...0.5)
    fog.vy = Float.random(in: 0.6...1.6)
    fog.sizePx = minDimension * Float.random(in: 0.05...0.09)
    fog.alpha = 0.16
  }

  private func updateFrost(dt: Float) {
    for frost in frosts where frost.active {
      frost.alpha -= frost.decay * dt
      if frost.alpha <= 0 { frost.active = false }
    }
  }

  private func updateFog(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    for fog in fogs where fog.active {
      fog.x += fog.vx * dt / (width * 0.5)
      fog.y += fog.vy * dt / (height * 0.5)
      fog.sizePx *= 1 + 0.016 * dt
      fog.alpha -= 0.0045 * dt
      if fog.alpha <= 0 { fog.active = false }
    }
  }

  private func drawFrost() {
    frostFloats.clear()
    var count = 0
    for frost in frosts where frost.active {
      let alpha = (frost.alpha * Float.random(in: 0.55...1)).glClamped()
      frostFloats.put(frost.x).put(frost.y).put(frost.r).put(frost.g).put(frost.b).put(alpha).put(
        frost.sizePx)
      count += 1
    }
    drawPointBuffer(frostFloats, count: count)
  }

  private func drawFog() {
    fogFloats.clear()
    var count = 0
    for fog in fogs where fog.active {
      fogFloats.put(fog.x).put(fog.y).put(1).put(1).put(1).put(fog.alpha.glClamped()).put(
        fog.sizePx)
      count += 1
    }
    drawPointBuffer(fogFloats, count: count)
  }

  private func drawPointBuffer(_ buffer: GLFloatBuffer, count: Int) {
    guard count > 0 else { return }
    glUseProgram(fogProgram)
    GLHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: Self.bytesPerPoint,
      attributes: [
        GLVertexAttribute(location: fogPosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: fogColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: fogSize, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_POINTS), vertexCount: count
    )
  }

  private func spawnFromTrack(_ trackData: GLTrackData, context: GLRenderContext) {
    let minDimension = context.minDimension
    for (trackID, points) in trackData where points.count >= 2 {
      let point = points.last!.first
      let previous = points[points.count - 2].first
      let x = Float(point.center.x * 2 - 1) * context.quadScaleX
      let y = Float(1 - point.center.y * 2) * context.quadScaleY
      let x1 = Float(previous.center.x * 2 - 1) * context.quadScaleX
      let y1 = Float(1 - previous.center.y * 2) * context.quadScaleY
      let movement = hypot(x - x1, y - y1)
      let distance =
        lastPosition[trackID].map { hypot(x - $0.0, y - $0.1) } ?? .greatestFiniteMagnitude
      guard distance > 0.006 else { continue }
      lastPosition[trackID] = (x, y)
      let normalized = movement / context.dtScale
      if normalized > 0.007 {
        let chance: Float = normalized > 0.016 ? 1 : 0.75
        if Float.random(in: 0...1) < chance {
          spawnShardsFromTrail(
            points, movement: normalized, minDimension: minDimension, color: point.color,
            context: context)
        }
      }
    }
  }

  private func spawnShardsFromTrail(
    _ points: [GLTrailSample], movement: Float, minDimension: Float, color: UIColor,
    context: GLRenderContext
  ) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let index = Int.random(in: 0..<(points.count - 1))
    let first = points[index].first
    let second = points[index + 1].first
    let x = Float(first.center.x * 2 - 1) * context.quadScaleX
    let y = Float(1 - first.center.y * 2) * context.quadScaleY
    let nextX = Float(second.center.x * 2 - 1) * context.quadScaleX
    let nextY = Float(1 - second.center.y * 2) * context.quadScaleY
    let segmentAngle = atan2((nextY - y) * height, (nextX - x) * width)
    let source = GLHelper.rgba(color)
    let speedPx = movement * minDimension * 0.5
    var spawned = 0
    for shard in shards where !shard.active {
      let side: Float = Bool.random() ? 1 : -1
      let direction = segmentAngle + side * (.pi / 2) + Float.random(in: -0.4...0.4)
      let speed = Float.random(in: 0...6) + speedPx * 0.4
      shard.active = true
      shard.x = x
      shard.y = y
      shard.vx = cos(direction) * speed
      shard.vy = sin(direction) * speed + 1.2
      shard.angle = Float.random(in: 0...(2 * .pi))
      shard.spin = Float.random(in: -0.6...0.6)
      shard.alpha = 1
      shard.decay = Float.random(in: 0.12...0.17)
      let baseRadius =
        Bool.random()
        ? minDimension * Float.random(in: 0.013...0.021)
        : minDimension * Float.random(in: 0.005...0.008)
      shard.vertexCount = Int.random(in: 3...5)
      for vertex in 0..<shard.vertexCount {
        let angle = 2 * Float.pi * Float(vertex) / Float(shard.vertexCount)
        let radius = baseRadius * Float.random(in: 0.3...1.2)
        shard.offsetX[vertex] = cos(angle) * radius
        shard.offsetY[vertex] = sin(angle) * radius
      }
      if Double.random(in: 0...1) > 0.3 {
        shard.r = Self.iceR * 0.7 + source.0 * 0.3
        shard.g = Self.iceG * 0.7 + source.1 * 0.3
        shard.b = 1
      } else {
        (shard.r, shard.g, shard.b) = (1, 1, 1)
      }
      spawned += 1
      if spawned >= 6 { break }
    }
  }

  private func updateShards(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    for shard in shards where shard.active {
      shard.x += shard.vx * dt / (width * 0.5)
      shard.y += shard.vy * dt / (height * 0.5)
      shard.vy -= 0.65 * dt
      shard.angle += shard.spin * dt
      shard.alpha -= shard.decay * dt
      if shard.alpha <= 0 { shard.active = false }
    }
  }

  private func drawShards(context: GLRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    shardFloats.clear()
    var vertexCount = 0
    for shard in shards where shard.active {
      let cosine = cos(shard.angle)
      let sine = sin(shard.angle)
      let alpha = shard.alpha.glClamped()
      func vertex(_ index: Int) -> (Float, Float) {
        let rx = shard.offsetX[index] * cosine - shard.offsetY[index] * sine
        let ry = shard.offsetX[index] * sine + shard.offsetY[index] * cosine
        return (shard.x + rx / (width * 0.5), shard.y + ry / (height * 0.5))
      }
      let first = vertex(0)
      for index in 1..<(shard.vertexCount - 1) {
        for point in [first, vertex(index), vertex(index + 1)] {
          shardFloats.put(point.0).put(point.1).put(shard.r).put(shard.g).put(shard.b).put(alpha)
            .put(Self.shardDistance)
          vertexCount += 1
        }
      }
    }
    guard vertexCount > 0 else { return }
    glUseProgram(iceProgram)
    GLHelper.drawInterleaved(
      buffer: shardFloats,
      strideBytes: Self.bytesPerVertex,
      attributes: [
        GLVertexAttribute(location: icePosition, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: iceColor, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: iceCenterDistance, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_TRIANGLES), vertexCount: vertexCount
    )
  }
}
