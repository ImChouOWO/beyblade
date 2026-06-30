import UIKit

/// Port of MoneyMetalEffect.kt (`IronShieldMetalEffect`): gold ribbon, coins, sparks and impact rings.
final class MoneyMetalEffect: MetalEffect {
  private var goldProgram: MetalProgramID = 0
  private var goldPosLoc: MetalLocation = -1
  private var goldColorLoc: MetalLocation = -1
  private var goldDistLoc: MetalLocation = -1

  private var coinProgram: MetalProgramID = 0
  private var coinPosLoc: MetalLocation = -1
  private var coinUVLoc: MetalLocation = -1
  private var coinColorLoc: MetalLocation = -1

  private final class Coin {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var angle: Float = 0
    var angularVelocity: Float = 0
    var flip: Float = 0
    var flipVelocity: Float = 0
    var sizePx: Float = 20
    var alpha: Float = 0
    var decay: Float = 0.03
    var r: Float = 1
    var g: Float = 0.82
    var b: Float = 0.12
  }

  private final class Spark {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var alpha: Float = 0
    var decay: Float = 0.1
    var halfWidthPx: Float = 2
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
  }

  private final class Ring {
    var active = false
    var x: Float = 0
    var y: Float = 0
    var radiusPx: Float = 0
    var maxRadiusPx: Float = 0
    var alpha: Float = 0
  }

  private let coins = (0..<36).map { _ in Coin() }
  private let sparks = (0..<48).map { _ in Spark() }
  private let rings = (0..<5).map { _ in Ring() }
  private let coinFloats = MetalFloatBuffer(capacity: 36 * 6 * 8)
  private let sparkFloats = MetalFloatBuffer(capacity: 48 * 6 * 7)
  private var lastPosition: [Int: (Float, Float)] = [:]
  private var pointX = [Float](repeating: 0, count: 256)
  private var pointY = [Float](repeating: 0, count: 256)
  private var halfWidth: Float = 1
  private var halfHeight: Float = 1

  override func onMetalReady(context: MetalRenderContext) {
    goldProgram = MetalHelper.makeProgram(.gold)
    goldPosLoc = metalGetAttribLocation(goldProgram, "aPosition")
    goldColorLoc = metalGetAttribLocation(goldProgram, "aColor")
    goldDistLoc = metalGetAttribLocation(goldProgram, "aCenterDist")

    coinProgram = MetalHelper.makeProgram(.coin)
    coinPosLoc = metalGetAttribLocation(coinProgram, "aPosition")
    coinUVLoc = metalGetAttribLocation(coinProgram, "aUV")
    coinColorLoc = metalGetAttribLocation(coinProgram, "aColor")
  }

  override func draw(trackData: MetalTrackData, context: MetalRenderContext, effectType: EffectType) {
    halfWidth = max(Float(context.viewWidth) * 0.5, 1)
    halfHeight = max(Float(context.viewHeight) * 0.5, 1)

    metalUseProgram(goldProgram)
    for (_, points) in trackData where points.count >= 2 {
      drawRibbon(points, context: context)
    }
    spawnFromTrack(trackData, context: context)
    updateRings(dt: context.dtScale)
    drawRings(context: context)
    updateSparks(context: context)
    drawSparks()
    updateCoins(context: context)
    drawCoins()
  }

  private func drawRibbon(_ points: [MetalTrailSample], context: MetalRenderContext) {
    let n = min(points.count, 256)
    guard n >= 2 else { return }
    for i in 0..<n {
      pointX[i] = Float(points[i].first.center.x * 2 - 1) * context.quadScaleX
      pointY[i] = Float(1 - points[i].first.center.y * 2) * context.quadScaleY
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
      let width: Float = 0.022 * (0.3 + 0.7 * alpha)
      context.ribbonFloats
        .put(x - normal.0 * width).put(y - normal.1 * width)
        .put(1).put(0.82).put(0.12).put(alpha).put(-1)
      context.ribbonFloats
        .put(x + normal.0 * width).put(y + normal.1 * width)
        .put(1).put(0.82).put(0.12).put(alpha).put(1)
    }
    drawGold(buffer: context.ribbonFloats, mode: MGL_TRIANGLE_STRIP, count: n * 2)
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
      let movement = sqrt(dx * dx + dy * dy)
      let movementAngle = atan2(dy * height, dx * width)
      let distance: Float
      if let last = lastPosition[trackID] {
        distance = hypot(x - last.0, y - last.1)
      } else {
        distance = .greatestFiniteMagnitude
      }
      guard distance > 0.006 else { continue }
      lastPosition[trackID] = (x, y)
      let normalized = movement / context.dtScale

      if normalized > 0.008 {
        let count = 1 + min(Int(normalized * 70), 2)
        let speed = minDimension * (0.006 + normalized * 0.35)
        for _ in 0..<count {
          spawnCoin(
            x: x, y: y,
            angle: movementAngle + .pi + Float.random(in: -0.3...0.3),
            speedPx: speed * Float.random(in: 0.7...1.1),
            minDimension: minDimension
          )
        }
        if Double.random(in: 0...1) > 0.4 {
          spawnSpark(x: x, y: y, angle: movementAngle + .pi, coneHalf: 0.4, count: 1)
        }
      }

      if normalized > 0.018 {
        let back = movementAngle + Float.pi
        let burst = Int.random(in: 3...5)
        for _ in 0..<burst {
          spawnCoin(
            x: x, y: y,
            angle: back + Float.random(in: -0.7...0.7),
            speedPx: minDimension * Float.random(in: 0.008...0.020),
            minDimension: minDimension
          )
        }
        spawnRing(x: x, y: y, movement: normalized, minDimension: minDimension)
        spawnSpark(x: x, y: y, angle: back, coneHalf: 0.7, count: 3)
      }
    }
  }

  private func spawnCoin(x: Float, y: Float, angle: Float, speedPx: Float, minDimension: Float) {
    guard let coin = coins.first(where: { !$0.active }) else { return }
    coin.active = true
    coin.x = x
    coin.y = y
    coin.vx = cos(angle) * speedPx
    coin.vy = sin(angle) * speedPx + minDimension * 0.006
    coin.angle = Float.random(in: 0...(2 * .pi))
    coin.angularVelocity = Float.random(in: -0.25...0.25)
    coin.flip = Float.random(in: 0...(2 * .pi))
    coin.flipVelocity = Float.random(in: 0.25...0.65)
    coin.sizePx = minDimension * Float.random(in: 0.020...0.036)
    coin.alpha = 1
    coin.decay = Float.random(in: 0.045...0.080)
    switch Int.random(in: 0...3) {
    case 0: (coin.r, coin.g, coin.b) = (1, 0.90, 0.35)
    case 3: (coin.r, coin.g, coin.b) = (0.85, 0.60, 0.10)
    default: (coin.r, coin.g, coin.b) = (1, 0.82, 0.12)
    }
  }

  private func updateCoins(context: MetalRenderContext) {
    let dt = context.dtScale
    for coin in coins where coin.active {
      coin.x += coin.vx * dt / halfWidth
      coin.y += coin.vy * dt / halfHeight
      coin.vy -= 0.6 * dt
      coin.vx *= 1 - 0.02 * dt
      coin.angle += coin.angularVelocity * dt
      coin.flip += coin.flipVelocity * dt
      coin.alpha -= coin.decay * dt
      if coin.alpha <= 0 { coin.active = false }
    }
  }

  private func drawCoins() {
    coinFloats.clear()
    var quadCount = 0
    for coin in coins where coin.active {
      let flipScale: Float = 0.18 + 0.82 * abs(cos(coin.flip))
      let hx = coin.sizePx * 0.5 * flipScale
      let hy = coin.sizePx * 0.5
      let cosine = cos(coin.angle)
      let sine = sin(coin.angle)
      let alpha = coin.alpha.metalClamped()

      func corner(_ ux: Float, _ uy: Float) -> (Float, Float) {
        let localX = ux * hx
        let localY = uy * hy
        let rotatedX = localX * cosine - localY * sine
        let rotatedY = localX * sine + localY * cosine
        return (coin.x + rotatedX / halfWidth, coin.y + rotatedY / halfHeight)
      }
      let a = corner(-1, -1)
      let b = corner(1, -1)
      let c = corner(1, 1)
      let d = corner(-1, 1)
      putCoin(a, uv: (-1, -1), coin: coin, alpha: alpha)
      putCoin(b, uv: (1, -1), coin: coin, alpha: alpha)
      putCoin(c, uv: (1, 1), coin: coin, alpha: alpha)
      putCoin(a, uv: (-1, -1), coin: coin, alpha: alpha)
      putCoin(c, uv: (1, 1), coin: coin, alpha: alpha)
      putCoin(d, uv: (-1, 1), coin: coin, alpha: alpha)
      quadCount += 1
    }
    guard quadCount > 0 else { return }
    metalUseProgram(coinProgram)
    MetalHelper.drawInterleaved(
      buffer: coinFloats,
      strideBytes: 32,
      attributes: [
        MetalVertexAttribute(location: coinPosLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: coinUVLoc, size: 2, offsetBytes: 8),
        MetalVertexAttribute(location: coinColorLoc, size: 4, offsetBytes: 16),
      ],
      mode: MGL_TRIANGLES,
      vertexCount: quadCount * 6
    )
  }

  private func putCoin(_ point: (Float, Float), uv: (Float, Float), coin: Coin, alpha: Float) {
    coinFloats.put(point.0).put(point.1).put(uv.0).put(uv.1)
      .put(coin.r).put(coin.g).put(coin.b).put(alpha)
  }

  private func spawnSpark(x: Float, y: Float, angle: Float, coneHalf: Float, count: Int) {
    var spawned = 0
    for spark in sparks where !spark.active {
      let particleAngle = angle + Float.random(in: -coneHalf...coneHalf)
      let speed = Float.random(in: 8...28)
      spark.active = true
      spark.x = x
      spark.y = y
      spark.vx = cos(particleAngle) * speed
      spark.vy = sin(particleAngle) * speed
      spark.alpha = 1
      spark.decay = Float.random(in: 0.07...0.13)
      spark.halfWidthPx = Float.random(in: 1.4...3.2)
      if Double.random(in: 0...1) > 0.4 {
        (spark.r, spark.g, spark.b) = (1, 0.95, 0.6)
      } else {
        (spark.r, spark.g, spark.b) = (1, 1, 1)
      }
      spawned += 1
      if spawned >= count { return }
    }
  }

  private func updateSparks(context: MetalRenderContext) {
    let dt = context.dtScale
    let friction = 1 - 0.08 * dt
    for spark in sparks where spark.active {
      spark.x += spark.vx * dt / halfWidth
      spark.y += spark.vy * dt / halfHeight
      spark.vx *= friction
      spark.vy *= friction
      spark.alpha -= spark.decay * dt
      if spark.alpha <= 0 { spark.active = false }
    }
  }

  private func drawSparks() {
    sparkFloats.clear()
    var vertexCount = 0
    for spark in sparks where spark.active {
      let speed = max(hypot(spark.vx, spark.vy), 0.001)
      let dx = spark.vx / speed
      let dy = spark.vy / speed
      let length = speed * 2.6 + 3
      let endX = spark.x + dx * length / halfWidth
      let endY = spark.y + dy * length / halfHeight
      let nx = -dy * spark.halfWidthPx / halfWidth
      let ny = dx * spark.halfWidthPx / halfHeight
      let alpha = spark.alpha.metalClamped()
      func put(_ x: Float, _ y: Float, _ distance: Float, _ a: Float) {
        sparkFloats.put(x).put(y).put(spark.r).put(spark.g).put(spark.b).put(a).put(distance)
      }
      put(spark.x - nx, spark.y - ny, -1, alpha)
      put(spark.x + nx, spark.y + ny, 1, alpha)
      put(endX - nx, endY - ny, -1, alpha * 0.30)
      put(spark.x + nx, spark.y + ny, 1, alpha)
      put(endX + nx, endY + ny, 1, alpha * 0.30)
      put(endX - nx, endY - ny, -1, alpha * 0.30)
      vertexCount += 6
    }
    guard vertexCount > 0 else { return }
    drawGold(buffer: sparkFloats, mode: MGL_TRIANGLES, count: vertexCount)
  }

  private func spawnRing(x: Float, y: Float, movement: Float, minDimension: Float) {
    guard let ring = rings.first(where: { !$0.active }) else { return }
    ring.active = true
    ring.x = x
    ring.y = y
    ring.radiusPx = minDimension * 0.010
    ring.maxRadiusPx = min(minDimension * (0.035 + movement * 0.4), minDimension * 0.065)
    ring.alpha = 0.7
  }

  private func updateRings(dt: Float) {
    for ring in rings where ring.active {
      ring.radiusPx += (ring.maxRadiusPx - ring.radiusPx) * 0.22 * dt
      ring.alpha -= 0.06 * dt
      if ring.alpha <= 0 || ring.maxRadiusPx - ring.radiusPx < 1 { ring.active = false }
    }
  }

  private func drawRings(context: MetalRenderContext) {
    let minDimension = Float(min(context.viewWidth, context.viewHeight))
    guard minDimension > 0 else { return }
    for ring in rings where ring.active {
      drawRadialBand(
        centerX: ring.x, centerY: ring.y,
        radiusPx: ring.radiusPx,
        halfBandPx: minDimension * 0.0034,
        segments: 24,
        alpha: ring.alpha.metalClamped(),
        context: context
      )
    }
  }

  private func drawRadialBand(
    centerX: Float, centerY: Float, radiusPx: Float,
    halfBandPx: Float, segments: Int, alpha: Float,
    context: MetalRenderContext
  ) {
    let width = Float(context.viewWidth)
    let height = Float(context.viewHeight)
    let inner = max(radiusPx - halfBandPx, 0)
    let outer = radiusPx + halfBandPx
    context.ribbonFloats.clear()
    for i in 0...segments {
      let angle = 2 * Float.pi * Float(i) / Float(segments)
      let cosine = cos(angle)
      let sine = sin(angle)
      context.ribbonFloats
        .put(centerX + inner / (width / 2) * cosine)
        .put(centerY + inner / (height / 2) * sine)
        .put(1).put(0.82).put(0.12).put(alpha).put(-1)
      context.ribbonFloats
        .put(centerX + outer / (width / 2) * cosine)
        .put(centerY + outer / (height / 2) * sine)
        .put(1).put(0.82).put(0.12).put(alpha).put(1)
    }
    drawGold(
      buffer: context.ribbonFloats, mode: MGL_TRIANGLE_STRIP, count: (segments + 1) * 2)
  }

  private func drawGold(buffer: MetalFloatBuffer, mode: MetalPrimitiveCode, count: Int) {
    metalUseProgram(goldProgram)
    MetalHelper.drawInterleaved(
      buffer: buffer,
      strideBytes: 28,
      attributes: [
        MetalVertexAttribute(location: goldPosLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: goldColorLoc, size: 4, offsetBytes: 8),
        MetalVertexAttribute(location: goldDistLoc, size: 1, offsetBytes: 24),
      ],
      mode: mode,
      vertexCount: count
    )
  }
}
