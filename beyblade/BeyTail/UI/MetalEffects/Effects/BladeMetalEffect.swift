import UIKit

/// Port of BladeMetalEffect.kt: double-helix blade, metal sparks, cracks, glints and sword-qi waves.
final class BladeMetalEffect: MetalEffect {
  private var program: MetalProgramID = 0
  private var posLoc: MetalLocation = -1
  private var colorLoc: MetalLocation = -1
  private var distLoc: MetalLocation = -1

  private final class Spark {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var alpha: Float = 0
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
  }
  private final class Crack {
    var active = false
    var x1: Float = 0
    var y1: Float = 0
    var x2: Float = 0
    var y2: Float = 0
    var alpha: Float = 0
  }
  private final class Glint {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var angle: Float = 0
    var sizePx: Float = 0
    var progress: Float = 0
  }
  private final class SlashWave {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var angle: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var radiusPx: Float = 0
    var alpha: Float = 0
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
  }

  private let sparks = (0..<28).map { _ in Spark() }
  private let cracks = (0..<4).map { _ in Crack() }
  private let glints = (0..<10).map { _ in Glint() }
  private let waves = (0..<4).map { _ in SlashWave() }
  private let sparkFloats = MetalFloatBuffer(capacity: 28 * 6 * 7)
  private var lastPosition: [Int: (Float, Float)] = [:]
  private var pointX = [Float](repeating: 0, count: 256)
  private var pointY = [Float](repeating: 0, count: 256)
  private var resampledX = [Float](repeating: 0, count: 64)
  private var resampledY = [Float](repeating: 0, count: 64)
  private var resampledAlpha = [Float](repeating: 0, count: 64)

  override func onMetalReady(context: MetalRenderContext) {
    program = MetalHelper.makeProgram(.blade)
    posLoc = metalGetAttribLocation(program, "aPosition")
    colorLoc = metalGetAttribLocation(program, "aColor")
    distLoc = metalGetAttribLocation(program, "aCenterDist")
  }

  override func draw(trackData: MetalTrackData, context: MetalRenderContext, effectType: EffectType) {
    metalUseProgram(program)
    spawnFromTrack(trackData, context: context)
    for (_, points) in trackData where points.count >= 3 { drawBlade(points, context: context, widthScale: effectType.trailWidthMultiplier) }
    updateCracks(dt: context.dtScale)
    drawCracks(context: context)
    updateSparks(context: context)
    drawSparks(context: context)
    updateWaves(context: context)
    drawWaves(context: context)
    updateGlints(dt: context.dtScale)
    drawGlints(context: context)
  }

  private func drawBlade(
    _ points: [MetalTrailSample],
    context: MetalRenderContext,
    widthScale: Float
  ) {
    let n = min(points.count, 256)
    guard n >= 3 else { return }
    for i in 0..<n {
      pointX[i] = Float(points[i].first.center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - points[i].first.center.y * 2) * context.quadScaleY
    }
    let m = min(n * 3, 64)
    for j in 0..<m {
      let f = Float(j) / Float(m - 1) * Float(n - 1)
      let i0 = min(Int(f), n - 2)
      let fraction = f - Float(i0)
      resampledX[j] = pointX[i0] + (pointX[i0 + 1] - pointX[i0]) * fraction
      resampledY[j] = pointY[i0] + (pointY[i0 + 1] - pointY[i0]) * fraction
      resampledAlpha[j] = points[i0].second + (points[i0 + 1].second - points[i0].second) * fraction
    }

    let base = MetalHelper.vivid(points.last!.first.color)
    let twin = MetalHelper.hueShift(base, degrees: 38)
    for strand in 0..<2 {
      let color = MetalHelper.rgba(strand == 0 ? base : twin)
      let phase = Float(strand) * .pi
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
        let envelope = sin(.pi * u)
        let offset = sin(u * 2.2 * 2 * .pi + phase) * 0.016 * envelope
        let centerX = x + normal.0 * offset
        let centerY = y + normal.1 * offset
        let half: Float = 0.012 * widthScale * envelope
        let alphaTemplate: Float
        if u < 0.3 {
          alphaTemplate = u / 0.3 * 0.5
        } else if u < 0.8 {
          alphaTemplate = 0.5 + (u - 0.3) / 0.5 * 0.45
        } else {
          alphaTemplate = 0.95 + (u - 0.8) / 0.2 * 0.05
        }
        let alpha = alphaTemplate * sqrt(max(resampledAlpha[j], 0))
        let whiteMix = ((u - 0.75) / 0.25).metalClamped()
        let r = color.0 + (1 - color.0) * whiteMix
        let g = color.1 + (1 - color.1) * whiteMix
        let b = color.2 + (1 - color.2) * whiteMix
        context.ribbonFloats
          .put(centerX - normal.0 * half).put(centerY - normal.1 * half)
          .put(r).put(g).put(b).put(alpha).put(-1)
        context.ribbonFloats
          .put(centerX + normal.0 * half).put(centerY + normal.1 * half)
          .put(r).put(g).put(b).put(alpha).put(1)
      }
      drawBladeBuffer(context.ribbonFloats, mode: MGL_TRIANGLE_STRIP, count: m * 2)
    }
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
      let distance: Float =
        lastPosition[trackID].map { hypot(x - $0.0, y - $0.1) } ?? .greatestFiniteMagnitude
      guard distance > 0.005 else { continue }
      lastPosition[trackID] = (x, y)
      let normalized = movement / context.dtScale
      if normalized > 0.009 {
        for _ in 0..<context.particleEmissionCount(baseCount: 1) {
          emitFromBody(points, minDimension: minDimension, context: context)
        }
      }
      if normalized > 0.008 {
        let vx = dx * width * 0.5 / context.dtScale
        let vy = dy * height * 0.5 / context.dtScale
        if context.shouldSpawnParticle(baseProbability: 0.70) { spawnSpark(x: x, y: y, vx: vx, vy: vy) }
        if context.shouldSpawnParticle(baseProbability: 0.50) { spawnSpark(x: x, y: y, vx: vx, vy: vy) }
        if context.shouldSpawnParticle(baseProbability: 0.60) {
          spawnCrack(x1: x1, y1: y1, x2: x, y2: y, minDimension: minDimension, context: context)
        }
        if context.shouldSpawnParticle(baseProbability: 0.6) {
          spawnWave(
            x: x, y: y, movementAngle: atan2(dy * height, dx * width), movement: normalized,
            minDimension: minDimension, color: point.color)
        }
      }
    }
  }

  private func emitFromBody(
    _ points: [MetalTrailSample], minDimension: Float, context: MetalRenderContext
  ) {
    guard points.count >= 3 else { return }
    let index = Int.random(in: 1...(points.count - 2))
    let point = points[index].first
    let previous = points[index - 1].first
    let next = points[index + 1].first
    let x = Float(point.center.x * 2 - 1) * context.quadScaleX
    let y = Float(1 - point.center.y * 2) * context.quadScaleY
    let dx =
      Float(next.center.x - previous.center.x) * context.quadScaleX * Float(context.viewWidth)
    let dy =
      -Float(next.center.y - previous.center.y) * context.quadScaleY * Float(context.viewHeight)
    let length = max(hypot(dx, dy), 0.001)
    let perpendicularX = -dy / length
    let perpendicularY = dx / length
    let emissionCount = context.particleEmissionCount(
      baseCount: Float(Bool.random() ? 2 : 1)
    )
    for _ in 0..<emissionCount {
      let side: Float = Bool.random() ? 1 : -1
      let burst = Float.random(in: 3...8)
      spawnSparkRaw(
        x: x, y: y,
        vx: perpendicularX * side * burst - dx / length * Float.random(in: 0...2.5)
          + Float.random(in: -1.5...1.5),
        vy: perpendicularY * side * burst - dy / length * Float.random(in: 0...2.5)
          + Float.random(in: -1.5...1.5)
      )
    }
    if context.shouldSpawnParticle(baseProbability: 0.55) { spawnGlint(x: x, y: y, minDimension: minDimension) }
  }

  private func spawnGlint(x: Float, y: Float, minDimension: Float) {
    guard let glint = glints.first(where: { !$0.active }) else { return }
    glint.active = true
    glint.x = x + Float.random(in: -0.0075...0.0075)
    glint.y = y + Float.random(in: -0.0075...0.0075)
    glint.angle = Float.random(in: 0...Float.pi)
    glint.sizePx = minDimension * Float.random(in: 0.008...0.016)
    glint.progress = 0
  }

  private func spawnSparkRaw(x: Float, y: Float, vx: Float, vy: Float) {
    guard let spark = sparks.first(where: { !$0.active }) else { return }
    spark.active = true
    spark.x = x
    spark.y = y
    spark.vx = vx
    spark.vy = vy
    spark.alpha = 1
    if Double.random(in: 0...1) > 0.4 {
      (spark.r, spark.g, spark.b) = (0.88, 0.95, 1)
    } else {
      (spark.r, spark.g, spark.b) = (1, 0.94, 0.54)
    }
  }

  private func spawnSpark(x: Float, y: Float, vx: Float, vy: Float) {
    spawnSparkRaw(
      x: x, y: y, vx: vx * 0.4 + Float.random(in: -5...5), vy: vy * 0.4 + Float.random(in: -5...5))
  }

  private func spawnCrack(
    x1: Float, y1: Float, x2: Float, y2: Float, minDimension: Float, context: MetalRenderContext
  ) {
    guard let crack = cracks.first(where: { !$0.active }) else { return }
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dx = (x2 - x1) * width
    let dy = (y2 - y1) * height
    let length = max(hypot(dx, dy), 0.001)
    let offset = Float.random(in: -0.5...0.5) * minDimension * 0.030
    let ox = -dy / length * offset / (width / 2)
    let oy = dx / length * offset / (height / 2)
    let extensionX = (x2 - x1) * 0.8
    let extensionY = (y2 - y1) * 0.8
    crack.active = true
    crack.x1 = x1 + ox - extensionX
    crack.y1 = y1 + oy - extensionY
    crack.x2 = x2 + ox + extensionX
    crack.y2 = y2 + oy + extensionY
    crack.alpha = 0.9
  }

  private func updateCracks(dt: Float) {
    for crack in cracks where crack.active {
      crack.alpha -= 0.25 * dt
      if crack.alpha <= 0 { crack.active = false }
    }
  }

  private func drawCracks(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    context.ribbonFloats.clear()
    var count = 0
    for crack in cracks where crack.active {
      let dx = (crack.x2 - crack.x1) * width
      let dy = (crack.y2 - crack.y1) * height
      let length = max(hypot(dx, dy), 0.001)
      let crackWidthPx = context.scaledParticleSize(1.2)
      let nx = -dy / length * crackWidthPx / (width / 2)
      let ny = dx / length * crackWidthPx / (height / 2)
      let alpha = crack.alpha.metalClamped() * 0.6
      func put(_ x: Float, _ y: Float, _ d: Float) {
        context.ribbonFloats.put(x).put(y).put(0.73).put(0.90).put(0.99).put(alpha).put(d)
      }
      put(crack.x1 - nx, crack.y1 - ny, -1)
      put(crack.x1 + nx, crack.y1 + ny, 1)
      put(crack.x2 - nx, crack.y2 - ny, -1)
      put(crack.x1 + nx, crack.y1 + ny, 1)
      put(crack.x2 + nx, crack.y2 + ny, 1)
      put(crack.x2 - nx, crack.y2 - ny, -1)
      count += 6
    }
    if count > 0 { drawBladeBuffer(context.ribbonFloats, mode: MGL_TRIANGLES, count: count) }
  }

  private func updateSparks(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    let friction = 1 - 0.08 * dt
    for spark in sparks where spark.active {
      spark.x += spark.vx * dt / (width * 0.5)
      spark.y += spark.vy * dt / (height * 0.5)
      spark.vx *= friction
      spark.vy *= friction
      spark.alpha -= 0.12 * dt
      if spark.alpha <= 0 { spark.active = false }
    }
  }

  private func drawSparks(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    sparkFloats.clear()
    var count = 0
    for spark in sparks where spark.active {
      let speed = max(hypot(spark.vx, spark.vy), 0.001)
      let dx = spark.vx / speed
      let dy = spark.vy / speed
      let length = context.scaledParticleSize(speed * 1.5 + 4)
      let endX = spark.x + dx * length / (width * 0.5)
      let endY = spark.y + dy * length / (height * 0.5)
      let sparkWidthPx = context.scaledParticleSize(1.6)
      let nx = -dy * sparkWidthPx / (width * 0.5)
      let ny = dx * sparkWidthPx / (height * 0.5)
      let alpha = spark.alpha.metalClamped()
      func put(_ x: Float, _ y: Float, _ d: Float, _ a: Float) {
        sparkFloats.put(x).put(y).put(spark.r).put(spark.g).put(spark.b).put(a).put(d)
      }
      put(spark.x - nx, spark.y - ny, -1, alpha)
      put(spark.x + nx, spark.y + ny, 1, alpha)
      put(endX - nx, endY - ny, -1, alpha * 0.25)
      put(spark.x + nx, spark.y + ny, 1, alpha)
      put(endX + nx, endY + ny, 1, alpha * 0.25)
      put(endX - nx, endY - ny, -1, alpha * 0.25)
      count += 6
    }
    if count > 0 { drawBladeBuffer(sparkFloats, mode: MGL_TRIANGLES, count: count) }
  }

  private func spawnWave(
    x: Float, y: Float, movementAngle: Float, movement: Float,
    minDimension: Float, color: UIColor
  ) {
    guard let wave = waves.first(where: { !$0.active }) else { return }
    let speed = 10 + Float.random(in: 0...6) + movement * minDimension * 0.15
    wave.active = true
    wave.x = x
    wave.y = y
    wave.angle = movementAngle + Float.random(in: -0.2...0.2)
    wave.vx = cos(wave.angle) * speed
    wave.vy = sin(wave.angle) * speed
    wave.radiusPx = minDimension * Float.random(in: 0.035...0.055)
    wave.alpha = 0.95
    let c = MetalHelper.rgba(MetalHelper.vivid(color))
    wave.r = c.0 * 0.75 + 0.25
    wave.g = c.1 * 0.75 + 0.25
    wave.b = c.2 * 0.75 + 0.25
  }

  private func updateWaves(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let dt = context.dtScale
    for wave in waves where wave.active {
      wave.x += wave.vx * dt / (width * 0.5)
      wave.y += wave.vy * dt / (height * 0.5)
      wave.radiusPx *= 1 + 0.03 * dt
      wave.alpha -= 0.10 * dt
      if wave.alpha <= 0 { wave.active = false }
    }
  }

  private func drawWaves(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let particleSizeScale = context.particleSizeMultiplier
    let maxBand = min(width, height) * 0.008 * particleSizeScale
    for wave in waves where wave.active {
      context.ribbonFloats.clear()
      for i in 0...12 {
        let t = Float(i) / 12
        let angle = wave.angle - Float.pi / 3.2 + t * 2 * Float.pi / 3.2
        let band = maxBand * sin(.pi * t)
        let radiusPx = wave.radiusPx * particleSizeScale
        let inner = max(radiusPx - band, 0)
        let outer = radiusPx + band
        let cosine = cos(angle)
        let sine = sin(angle)
        let alpha = wave.alpha.metalClamped()
        context.ribbonFloats.put(wave.x + cosine * inner / (width / 2)).put(
          wave.y + sine * inner / (height / 2)
        )
        .put(wave.r).put(wave.g).put(wave.b).put(alpha).put(-1)
        context.ribbonFloats.put(wave.x + cosine * outer / (width / 2)).put(
          wave.y + sine * outer / (height / 2)
        )
        .put(wave.r).put(wave.g).put(wave.b).put(alpha).put(1)
      }
      drawBladeBuffer(context.ribbonFloats, mode: MGL_TRIANGLE_STRIP, count: 26)
    }
  }

  private func updateGlints(dt: Float) {
    for glint in glints where glint.active {
      glint.progress += 0.16 * dt
      if glint.progress >= 1 { glint.active = false }
    }
  }

  private func drawGlints(context: MetalRenderContext) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    context.ribbonFloats.clear()
    var count = 0
    for glint in glints where glint.active {
      let alpha = sin(.pi * glint.progress)
      let glintSizePx = glint.sizePx * context.particleSizeMultiplier
      let armWidth = glintSizePx * 0.16
      for arm in 0..<2 {
        let angle = glint.angle + Float(arm) * .pi / 2
        let dx = cos(angle)
        let dy = sin(angle)
        let lx = dx * glintSizePx / (width / 2)
        let ly = dy * glintSizePx / (height / 2)
        let nx = -dy * armWidth / (width / 2)
        let ny = dx * armWidth / (height / 2)
        func put(_ x: Float, _ y: Float, _ d: Float) {
          context.ribbonFloats.put(x).put(y).put(0.95).put(0.98).put(1).put(alpha).put(d)
        }
        put(glint.x - lx, glint.y - ly, 0)
        put(glint.x + nx, glint.y + ny, 1)
        put(glint.x - nx, glint.y - ny, -1)
        put(glint.x + nx, glint.y + ny, 1)
        put(glint.x + lx, glint.y + ly, 0)
        put(glint.x - nx, glint.y - ny, -1)
        count += 6
      }
    }
    if count > 0 { drawBladeBuffer(context.ribbonFloats, mode: MGL_TRIANGLES, count: count) }
  }

  private func drawBladeBuffer(_ buffer: MetalFloatBuffer, mode: MetalPrimitiveCode, count: Int) {
    metalUseProgram(program)
    MetalHelper.drawInterleaved(
      buffer: buffer, strideBytes: 28,
      attributes: [
        MetalVertexAttribute(location: posLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: colorLoc, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: distLoc, size: 1, offsetBytes: 24),
      ], mode: mode, vertexCount: count
    )
  }
}
