import OpenGLES
import UIKit

/// 100% feature port of WaveGLEffect.kt: fluid ribbon, side spray, bubbles and ripples.
final class WaveGLEffect: GLEffect {
  private var fluidProgram: GLuint = 0
  private var fluidPosLoc: GLint = -1
  private var fluidColorLoc: GLint = -1
  private var fluidDistLoc: GLint = -1
  private var fluidTrailLoc: GLint = -1
  private var fluidTimeLoc: GLint = -1

  private var waveProgram: GLuint = 0
  private var wavePosLoc: GLint = -1
  private var waveColorLoc: GLint = -1
  private var waveCenterDistLoc: GLint = -1

  private var particleProgram: GLuint = 0
  private var partPosLoc: GLint = -1
  private var partColorLoc: GLint = -1
  private var partSizeLoc: GLint = -1

  private var time: Float = 0
  private var pointX = [Float](repeating: 0, count: maxTrailPoints)
  private var pointY = [Float](repeating: 0, count: maxTrailPoints)
  private var cumulativeLength = [Float](repeating: 0, count: maxTrailPoints)

  private final class Particle {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var alpha: Float = 0
    var sizePx: Float = 0
    var isBlue = false
  }

  private final class Ripple {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var radiusPx: Float = 0
    var alpha: Float = 0
  }

  private let particles = (0..<50).map { _ in Particle() }
  private var lastPosition: [Int: (Float, Float)] = [:]
  private let particleFloats = GLFloatBuffer(capacity: 50 * 7)
  private let ripples = (0..<6).map { _ in Ripple() }

  override func onGLReady(context: GLRenderContext) {
    fluidProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.Wave.fluidVert,
      fragmentSource: GLEffectShaders.Wave.fluidFrag
    )
    fluidPosLoc = glGetAttribLocation(fluidProgram, "aPosition")
    fluidColorLoc = glGetAttribLocation(fluidProgram, "aColor")
    fluidDistLoc = glGetAttribLocation(fluidProgram, "aCenterDist")
    fluidTrailLoc = glGetAttribLocation(fluidProgram, "aTrailDist")
    fluidTimeLoc = glGetUniformLocation(fluidProgram, "uTime")

    waveProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.Wave.waveTrailVert,
      fragmentSource: GLEffectShaders.Wave.waveTrailFrag
    )
    wavePosLoc = glGetAttribLocation(waveProgram, "aPosition")
    waveColorLoc = glGetAttribLocation(waveProgram, "aColor")
    waveCenterDistLoc = glGetAttribLocation(waveProgram, "aCenterDist")

    particleProgram = GLHelper.buildProgram(
      vertexSource: GLEffectShaders.Wave.particleVert,
      fragmentSource: GLEffectShaders.Wave.particleFrag
    )
    partPosLoc = glGetAttribLocation(particleProgram, "aPosition")
    partColorLoc = glGetAttribLocation(particleProgram, "aColor")
    partSizeLoc = glGetAttribLocation(particleProgram, "aSize")
  }

  override func draw(
    trackData: GLTrackData,
    context: GLRenderContext,
    effectType: EffectType
  ) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }

    drawRibbons(trackData: trackData, context: context)
    spawnParticles(trackData: trackData, context: context)
    updateParticles(dt: context.dtScale)
    drawParticles()
    updateRipples(dt: context.dtScale)
    drawRipples(context: context)
  }

  private func drawRibbons(trackData: GLTrackData, context: GLRenderContext) {
    glUseProgram(fluidProgram)
    glUniform1f(fluidTimeLoc, time)
    for (_, points) in trackData where points.count >= 2 {
      drawFluidRibbon(points, context: context)
    }
  }

  private func drawFluidRibbon(_ points: [GLTrailSample], context: GLRenderContext) {
    let n = min(points.count, Self.maxTrailPoints)
    guard n >= 2,
      n * 2 * Self.bytesPerFluidVertex <= context.ribbonFloats.capacityBytes
    else {
      return
    }

    let color = GLHelper.rgba(points[n - 1].first.color)
    for i in 0..<n {
      let center = points[i].first.center
      pointX[i] = Float(center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - center.y * 2) * context.quadScaleY
      if i == 0 {
        cumulativeLength[i] = 0
      } else {
        let dx = pointX[i] - pointX[i - 1]
        let dy = pointY[i] - pointY[i - 1]
        cumulativeLength[i] = cumulativeLength[i - 1] + sqrt(dx * dx + dy * dy)
      }
    }
    let totalLength = cumulativeLength[n - 1]

    context.ribbonFloats.clear()
    for i in 0..<n {
      let x = pointX[i]
      let y = pointY[i]
      let normal: (Float, Float)
      if i == 0 {
        normal = GLHelper.segNormal(x, y, pointX[1], pointY[1])
      } else if i == n - 1 {
        normal = GLHelper.segNormal(pointX[i - 1], pointY[i - 1], x, y)
      } else {
        normal = GLHelper.avgNormal(
          pointX[i - 1], pointY[i - 1], x, y, pointX[i + 1], pointY[i + 1]
        )
      }
      let alpha = points[i].second
      let halfWidth: Float = 0.031 * (0.35 + 0.65 * alpha)
      let trail = totalLength - cumulativeLength[i]
      context.ribbonFloats
        .put(x - normal.0 * halfWidth).put(y - normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(alpha).put(-1).put(trail)
      context.ribbonFloats
        .put(x + normal.0 * halfWidth).put(y + normal.1 * halfWidth)
        .put(color.0).put(color.1).put(color.2).put(alpha).put(1).put(trail)
    }

    GLHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerFluidVertex,
      attributes: [
        GLVertexAttribute(location: fluidPosLoc, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: fluidColorLoc, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: fluidDistLoc, size: 1, offsetBytes: 24),
        GLVertexAttribute(location: fluidTrailLoc, size: 1, offsetBytes: 28),
      ],
      mode: GLenum(GL_TRIANGLE_STRIP),
      vertexCount: n * 2
    )
  }

  private func spawnParticles(trackData: GLTrackData, context: GLRenderContext) {
    for (trackID, points) in trackData where points.count >= 2 {
      let point = points.last!.first
      let previous = points[points.count - 2].first
      let x = Float(point.center.x * 2 - 1) * context.quadScaleX
      let y = Float(1 - point.center.y * 2) * context.quadScaleY
      let x1 = Float(previous.center.x * 2 - 1) * context.quadScaleX
      let y1 = Float(1 - previous.center.y * 2) * context.quadScaleY
      let dx = x - x1
      let dy = y - y1
      let movement = max(sqrt(dx * dx + dy * dy), 0.000_01)
      let perpendicularX = -dy / movement
      let perpendicularY = dx / movement

      let distance: Float
      if let last = lastPosition[trackID] {
        let ldx = x - last.0
        let ldy = y - last.1
        distance = sqrt(ldx * ldx + ldy * ldy)
      } else {
        distance = .greatestFiniteMagnitude
      }

      guard distance > 0.008, Double.random(in: 0...1) > 0.3 else { continue }
      lastPosition[trackID] = (x, y)
      let normalizedMovement = movement / context.dtScale
      if normalizedMovement > 0.015, Double.random(in: 0...1) > 0.5 {
        spawnRipple(x: x, y: y)
      }

      var spawned = 0
      for particle in particles where !particle.active {
        particle.active = true
        particle.x = x
        particle.y = y
        let side: Float = spawned.isMultiple(of: 2) ? 1 : -1
        let strength = (normalizedMovement * 1.5).glClamped(0.02, 0.045)
        particle.vx = perpendicularX * side * strength + Float.random(in: -0.5...0.5) * 0.018
        particle.vy =
          perpendicularY * side * strength + Float.random(in: -0.5...0.5) * 0.018 - 0.012
        particle.sizePx = Float.random(in: 6...14)
        particle.alpha = 1
        particle.isBlue = Double.random(in: 0...1) > 0.3
        spawned += 1
        if spawned >= 3 { break }
      }

      if points.count > 4, Double.random(in: 0...1) > 0.6,
        let particle = particles.first(where: { !$0.active })
      {
        let body = points[points.count / 3].first.center
        particle.active = true
        particle.x =
          Float(body.x * 2 - 1) * context.quadScaleX + Float.random(in: -0.5...0.5) * 0.02
        particle.y =
          Float(1 - body.y * 2) * context.quadScaleY + Float.random(in: -0.5...0.5) * 0.02
        particle.vx = Float.random(in: -0.5...0.5) * 0.006
        particle.vy = -Float.random(in: 0.005...0.017)
        particle.sizePx = Float.random(in: 2...6)
        particle.alpha = 0.6
        particle.isBlue = true
      }
    }
  }

  private func updateParticles(dt: Float) {
    for particle in particles where particle.active {
      particle.x += particle.vx * dt
      particle.y += particle.vy * dt
      particle.vy += 0.001 * dt
      particle.alpha -= 0.06 * dt
      if particle.alpha <= 0 { particle.active = false }
    }
  }

  private func drawParticles() {
    particleFloats.clear()
    var count = 0
    for particle in particles where particle.active {
      let r: Float = particle.isBlue ? 0.749 : 1
      let g: Float = particle.isBlue ? 0.906 : 1
      particleFloats
        .put(particle.x).put(particle.y)
        .put(r).put(g).put(1).put(particle.alpha.glClamped()).put(particle.sizePx)
      count += 1
    }
    guard count > 0 else { return }
    glUseProgram(particleProgram)
    GLHelper.drawInterleaved(
      buffer: particleFloats,
      strideBytes: Self.bytesPerParticle,
      attributes: [
        GLVertexAttribute(location: partPosLoc, size: 2, offsetBytes: 0),
        GLVertexAttribute(location: partColorLoc, size: 4, offsetBytes: 8),
        GLVertexAttribute(location: partSizeLoc, size: 1, offsetBytes: 24),
      ],
      mode: GLenum(GL_POINTS),
      vertexCount: count
    )
  }

  private func spawnRipple(x: Float, y: Float) {
    guard let ripple = ripples.first(where: { !$0.active }) else { return }
    ripple.active = true
    ripple.x = x
    ripple.y = y
    ripple.radiusPx = 0
    ripple.alpha = 0.85
  }

  private func updateRipples(dt: Float) {
    for ripple in ripples where ripple.active {
      ripple.radiusPx += 5 * dt
      ripple.alpha -= 0.04 * dt
      if ripple.alpha <= 0 { ripple.active = false }
    }
  }

  private func drawRipples(context: GLRenderContext) {
    guard ripples.contains(where: \.active) else { return }
    glUseProgram(waveProgram)
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)

    for ripple in ripples where ripple.active {
      let innerPx = max(ripple.radiusPx - Self.ringWidthPx, 0)
      let outerPx = ripple.radiusPx + Self.ringWidthPx
      let innerX = innerPx / (width / 2)
      let innerY = innerPx / (height / 2)
      let outerX = outerPx / (width / 2)
      let outerY = outerPx / (height / 2)
      let alpha = ripple.alpha.glClamped()

      context.ribbonFloats.clear()
      for i in 0...Self.ringSegments {
        let angle = Float(i) / Float(Self.ringSegments) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        context.ribbonFloats
          .put(ripple.x + innerX * cosine).put(ripple.y + innerY * sine)
          .put(0.71).put(0.90).put(1).put(alpha).put(-1)
        context.ribbonFloats
          .put(ripple.x + outerX * cosine).put(ripple.y + outerY * sine)
          .put(0.71).put(0.90).put(1).put(alpha).put(1)
      }

      GLHelper.drawInterleaved(
        buffer: context.ribbonFloats,
        strideBytes: Self.bytesPerWaveVertex,
        attributes: [
          GLVertexAttribute(location: wavePosLoc, size: 2, offsetBytes: 0),
          GLVertexAttribute(location: waveColorLoc, size: 4, offsetBytes: 8),
          GLVertexAttribute(location: waveCenterDistLoc, size: 1, offsetBytes: 24),
        ],
        mode: GLenum(GL_TRIANGLE_STRIP),
        vertexCount: (Self.ringSegments + 1) * 2
      )
    }
  }

  private static let bytesPerWaveVertex = 28
  private static let bytesPerFluidVertex = 32
  private static let bytesPerParticle = 28
  private static let maxTrailPoints = 256
  private static let timeWrap: Float = 120
  private static let ringSegments = 24
  private static let ringWidthPx: Float = 5
}
