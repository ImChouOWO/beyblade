import UIKit

/// 100% feature port of WaveMetalEffect.kt: fluid ribbon, side spray, bubbles and ripples.
final class WaveMetalEffect: MetalEffect {
  private var fluidProgram: MetalProgramID = 0
  private var fluidPosLoc: MetalLocation = -1
  private var fluidColorLoc: MetalLocation = -1
  private var fluidDistLoc: MetalLocation = -1
  private var fluidTrailLoc: MetalLocation = -1
  private var fluidTimeLoc: MetalLocation = -1

  private var waveProgram: MetalProgramID = 0
  private var wavePosLoc: MetalLocation = -1
  private var waveColorLoc: MetalLocation = -1
  private var waveCenterDistLoc: MetalLocation = -1

  private var particleProgram: MetalProgramID = 0
  private var partPosLoc: MetalLocation = -1
  private var partColorLoc: MetalLocation = -1
  private var partSizeLoc: MetalLocation = -1

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
  private var rippleElapsedByTrack: [Int: Float] = [:]

  private let particleFloats = MetalFloatBuffer(capacity: 50 * 7)
  private let ripples = (0..<6).map { _ in Ripple() }

  override func onMetalReady(context: MetalRenderContext) {
    fluidProgram = MetalHelper.makeProgram(.waveFluid)
    fluidPosLoc = metalGetAttribLocation(fluidProgram, "aPosition")
    fluidColorLoc = metalGetAttribLocation(fluidProgram, "aColor")
    fluidDistLoc = metalGetAttribLocation(fluidProgram, "aCenterDist")
    fluidTrailLoc = metalGetAttribLocation(fluidProgram, "aTrailDist")
    fluidTimeLoc = metalGetUniformLocation(fluidProgram, "uTime")

    waveProgram = MetalHelper.makeProgram(.waveTrail)
    wavePosLoc = metalGetAttribLocation(waveProgram, "aPosition")
    waveColorLoc = metalGetAttribLocation(waveProgram, "aColor")
    waveCenterDistLoc = metalGetAttribLocation(waveProgram, "aCenterDist")

    particleProgram = MetalHelper.makeProgram(.waveParticle)
    partPosLoc = metalGetAttribLocation(particleProgram, "aPosition")
    partColorLoc = metalGetAttribLocation(particleProgram, "aColor")
    partSizeLoc = metalGetAttribLocation(particleProgram, "aSize")
  }

  override func draw(
    trackData: MetalTrackData,
    context: MetalRenderContext,
    effectType: EffectType
  ) {
    time += (1 / 30) * context.dtScale
    if time > Self.timeWrap { time -= Self.timeWrap }

    drawRibbons(
      trackData: trackData,
      context: context,
      widthScale: effectType.trailWidthMultiplier
    )
    spawnParticles(trackData: trackData, context: context)
    updateParticles(dt: context.dtScale)
    drawParticles()
    updateRipples(dt: context.dtScale)
    drawRipples(context: context)
  }

  private func drawRibbons(
    trackData: MetalTrackData,
    context: MetalRenderContext,
    widthScale: Float
  ) {
    metalUseProgram(fluidProgram)
    metalUniform1f(fluidTimeLoc, time)
    for (_, points) in trackData where points.count >= 2 {
      drawFluidRibbon(points, context: context, widthScale: widthScale)
    }
  }

  private func drawFluidRibbon(
    _ points: [MetalTrailSample],
    context: MetalRenderContext,
    widthScale: Float
  ) {
    let n = min(points.count, Self.maxTrailPoints)
    guard n >= 2,
      n * 2 * Self.bytesPerFluidVertex <= context.ribbonFloats.capacityBytes
    else {
      return
    }

    for i in 0..<n {
      let center = points[i].first.center
      pointX[i] = Float(center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - center.y * 2) * context.quadScaleY

      if i == 0 {
        cumulativeLength[i] = 0
      } else {
        let dx = pointX[i] - pointX[i - 1]
        let dy = pointY[i] - pointY[i - 1]
        cumulativeLength[i] =
          cumulativeLength[i - 1] + sqrt(dx * dx + dy * dy)
      }
    }

    let totalLength = cumulativeLength[n - 1]

    context.ribbonFloats.clear()

    for i in 0..<n {
      let color = MetalHelper.rgba(points[i].first.color)
      let x = pointX[i]
      let y = pointY[i]

      let normal: (Float, Float)
      if i == 0 {
        normal = MetalHelper.segNormal(x, y, pointX[1], pointY[1])
      } else if i == n - 1 {
        normal = MetalHelper.segNormal(
          pointX[i - 1],
          pointY[i - 1],
          x,
          y
        )
      } else {
        normal = MetalHelper.avgNormal(
          pointX[i - 1],
          pointY[i - 1],
          x,
          y,
          pointX[i + 1],
          pointY[i + 1]
        )
      }

      let alpha = points[i].second
      let halfWidth =
        Self.baseTrailHalfWidth * widthScale
        * (0.35 + 0.65 * alpha)

      let trail = totalLength - cumulativeLength[i]

      context.ribbonFloats
        .put(x - normal.0 * halfWidth)
        .put(y - normal.1 * halfWidth)
        .put(color.0)
        .put(color.1)
        .put(color.2)
        .put(alpha)
        .put(-1)
        .put(trail)

      context.ribbonFloats
        .put(x + normal.0 * halfWidth)
        .put(y + normal.1 * halfWidth)
        .put(color.0)
        .put(color.1)
        .put(color.2)
        .put(alpha)
        .put(1)
        .put(trail)
    }

    MetalHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerFluidVertex,
      attributes: [
        MetalVertexAttribute(location: fluidPosLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: fluidColorLoc, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: fluidDistLoc, size: 1, offsetBytes: 24),
        MetalVertexAttribute(location: fluidTrailLoc, size: 1, offsetBytes: 28),
      ],
      mode: MGL_TRIANGLE_STRIP,
      vertexCount: n * 2
    )
  }

  private func spawnParticles(trackData: MetalTrackData, context: MetalRenderContext) {
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

      let normalizedMovement = movement / max(context.dtScale, 0.000_1)

      if normalizedMovement > Self.minimumRippleMovement {
        let interval = context.scaledParticleInterval(
          Self.rippleIntervalSeconds
        )

        guard interval.isFinite else {
          rippleElapsedByTrack[trackID] = 0
          continue
        }

        let elapsed =
          (rippleElapsedByTrack[trackID] ?? 0)
          + Self.simulationStepSeconds * context.dtScale

        if elapsed >= interval {
          spawnRipple(x: x, y: y)
          rippleElapsedByTrack[trackID] =
            elapsed.truncatingRemainder(dividingBy: interval)
        } else {
          rippleElapsedByTrack[trackID] = elapsed
        }
      }

      guard distance > 0.008 else {
        continue
      }

      guard context.shouldSpawnParticle(
        baseProbability: 0.70
      ) else {
        continue
      }

      lastPosition[trackID] = (x, y)

      let targetSpawnCount = context.particleEmissionCount(baseCount: 3)
      guard targetSpawnCount > 0 else { continue }
      var spawned = 0
      for particle in particles where !particle.active {
        particle.active = true
        particle.x = x
        particle.y = y
        let side: Float = spawned.isMultiple(of: 2) ? 1 : -1
        let strength =
          (normalizedMovement * 1.5).metalClamped(0.02, 0.045)

        particle.vx =
          perpendicularX * side * strength
          + Float.random(in: -0.5...0.5) * 0.018

        particle.vy =
          perpendicularY * side * strength
          + Float.random(in: -0.5...0.5) * 0.018
          - 0.012

        particle.sizePx = Float.random(in: 6...14)
        particle.alpha = 1
        particle.isBlue = Double.random(in: 0...1) > 0.3

        spawned += 1
        if spawned >= targetSpawnCount { break }
      }

      if points.count > 4,
        Double.random(in: 0...1) > 0.6,
        let particle = particles.first(where: { !$0.active })
      {
        let body = points[points.count / 3].first.center
        particle.active = true
        particle.x =
          Float(body.x * 2 - 1) * context.quadScaleX
          + Float.random(in: -0.5...0.5) * 0.02
        particle.y =
          Float(1 - body.y * 2) * context.quadScaleY
          + Float.random(in: -0.5...0.5) * 0.02
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

      if particle.alpha <= 0 {
        particle.active = false
      }
    }
  }

  private func drawParticles() {
    particleFloats.clear()
    var count = 0

    for particle in particles where particle.active {
      let r: Float = particle.isBlue ? 0.749 : 1
      let g: Float = particle.isBlue ? 0.906 : 1

      particleFloats
        .put(particle.x)
        .put(particle.y)
        .put(r)
        .put(g)
        .put(1)
        .put(particle.alpha.metalClamped())
        .put(particle.sizePx)

      count += 1
    }

    guard count > 0 else {
      return
    }

    metalUseProgram(particleProgram)

    MetalHelper.drawInterleaved(
      buffer: particleFloats,
      strideBytes: Self.bytesPerParticle,
      attributes: [
        MetalVertexAttribute(location: partPosLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: partColorLoc, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: partSizeLoc, size: 1, offsetBytes: 24),
      ],
      mode: MGL_POINTS,
      vertexCount: count
    )
  }

  private func spawnRipple(x: Float, y: Float) {
    guard let ripple = ripples.first(where: { !$0.active }) else {
      return
    }

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

      if ripple.alpha <= 0 {
        ripple.active = false
      }
    }
  }

  private func drawRipples(context: MetalRenderContext) {
    guard ripples.contains(where: \.active) else {
      return
    }

    metalUseProgram(waveProgram)

    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let particleSizeScale = context.particleSizeMultiplier

    for ripple in ripples where ripple.active {
      let radiusPx = ripple.radiusPx * particleSizeScale
      let ringWidthPx = Self.ringWidthPx * particleSizeScale
      let innerPx = max(radiusPx - ringWidthPx, 0)
      let outerPx = radiusPx + ringWidthPx
      let innerX = innerPx / (width / 2)
      let innerY = innerPx / (height / 2)
      let outerX = outerPx / (width / 2)
      let outerY = outerPx / (height / 2)
      let alpha = ripple.alpha.metalClamped()

      context.ribbonFloats.clear()

      for i in 0...Self.ringSegments {
        let angle =
          Float(i) / Float(Self.ringSegments) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)

        context.ribbonFloats
          .put(ripple.x + innerX * cosine)
          .put(ripple.y + innerY * sine)
          .put(0.71)
          .put(0.90)
          .put(1)
          .put(alpha)
          .put(-1)

        context.ribbonFloats
          .put(ripple.x + outerX * cosine)
          .put(ripple.y + outerY * sine)
          .put(0.71)
          .put(0.90)
          .put(1)
          .put(alpha)
          .put(1)
      }

      MetalHelper.drawInterleaved(
        buffer: context.ribbonFloats,
        strideBytes: Self.bytesPerWaveVertex,
        attributes: [
          MetalVertexAttribute(location: wavePosLoc, size: 2, offsetBytes: 0),
          MetalVertexAttribute(location: waveColorLoc, size: 4, offsetBytes: 8),
          MetalVertexAttribute(location: waveCenterDistLoc, size: 1, offsetBytes: 24),
        ],
        mode: MGL_TRIANGLE_STRIP,
        vertexCount: (Self.ringSegments + 1) * 2
      )
    }
  }

  private static let bytesPerWaveVertex = 28
  private static let bytesPerFluidVertex = 32
  private static let bytesPerParticle = 28
  private static let maxTrailPoints = 256
  private static let timeWrap: Float = 120

  private static let baseTrailHalfWidth: Float = 0.031
  private static let simulationStepSeconds: Float = 1.0 / 30.0
  private static let rippleIntervalSeconds: Float = 0.30
  private static let minimumRippleMovement: Float = 0.003

  private static let ringSegments = 24
  private static let ringWidthPx: Float = 5
}
