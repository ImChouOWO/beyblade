import UIKit

/// 金錢衝擊：金色拖尾、金幣、火花與衝擊環。
///
/// 所有隨機參數皆由當前軌跡區段產生固定種子，讓即時預覽、錄影與
/// 影片庫渲染在相同軌跡輸入下使用一致的粒子外觀與生成規則。
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

        func reset() {
            active = false
            x = 0
            y = 0
            vx = 0
            vy = 0
            angle = 0
            angularVelocity = 0
            flip = 0
            flipVelocity = 0
            sizePx = 20
            alpha = 0
            decay = 0.03
            r = 1
            g = 0.82
            b = 0.12
        }
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

        func reset() {
            active = false
            x = 0
            y = 0
            vx = 0
            vy = 0
            alpha = 0
            decay = 0.1
            halfWidthPx = 2
            r = 1
            g = 1
            b = 1
        }
    }

    private final class Ring {
        var active = false
        var x: Float = 0
        var y: Float = 0
        var radiusPx: Float = 0
        var maxRadiusPx: Float = 0
        var alpha: Float = 0

        func reset() {
            active = false
            x = 0
            y = 0
            radiusPx = 0
            maxRadiusPx = 0
            alpha = 0
        }
    }

    private let coinCapacity = 96
    private let sparkCapacity = 144
    private let ringCapacity = 12

    private lazy var coins = (0..<coinCapacity).map { _ in Coin() }
    private lazy var sparks = (0..<sparkCapacity).map { _ in Spark() }
    private lazy var rings = (0..<ringCapacity).map { _ in Ring() }

    private lazy var coinFloats = MetalFloatBuffer(
        capacity: coinCapacity * 6 * 8
    )
    private lazy var sparkFloats = MetalFloatBuffer(
        capacity: sparkCapacity * 6 * 7
    )

    private var lastPosition: [Int: (Float, Float)] = [:]
    private var pointX = [Float](repeating: 0, count: 256)
    private var pointY = [Float](repeating: 0, count: 256)
    private var halfWidth: Float = 1
    private var halfHeight: Float = 1

    /// 每個軌跡區段都會重新設定種子，不依賴前一個渲染流程的隨機狀態。
    private var randomState: UInt64 = 0x4D4F_4E45_595F_4658

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

    override func draw(
        trackData: MetalTrackData,
        context: MetalRenderContext,
        effectType: EffectType
    ) {
        halfWidth = max(Float(context.viewWidth) * 0.5, 1)
        halfHeight = max(Float(context.viewHeight) * 0.5, 1)

        metalUseProgram(goldProgram)

        for (_, points) in trackData where points.count >= 2 {
            drawRibbon(
                points,
                context: context,
                widthScale: effectType.trailWidthMultiplier
            )
        }

        spawnFromTrack(trackData, context: context)
        updateRings(dt: context.dtScale)
        drawRings(context: context)
        updateSparks(context: context)
        drawSparks(context: context)
        updateCoins(context: context)
        drawCoins(context: context)
    }

    override func reset() {
        lastPosition.removeAll(keepingCapacity: true)
        randomState = 0x4D4F_4E45_595F_4658

        for coin in coins {
            coin.reset()
        }

        for spark in sparks {
            spark.reset()
        }

        for ring in rings {
            ring.reset()
        }

        coinFloats.clear()
        sparkFloats.clear()
    }

    private func drawRibbon(
        _ points: [MetalTrailSample],
        context: MetalRenderContext,
        widthScale: Float
    ) {
        let count = min(points.count, pointX.count)

        guard count >= 2 else {
            return
        }

        for index in 0..<count {
            pointX[index] =
                Float(points[index].first.center.x * 2 - 1)
                * context.quadScaleX
            pointY[index] =
                Float(1 - points[index].first.center.y * 2)
                * context.quadScaleY
        }

        context.ribbonFloats.clear()

        for index in 0..<count {
            let x = pointX[index]
            let y = pointY[index]
            let normal: (Float, Float)

            if index == 0 {
                normal = MetalHelper.segNormal(
                    x,
                    y,
                    pointX[1],
                    pointY[1]
                )
            } else if index == count - 1 {
                normal = MetalHelper.segNormal(
                    pointX[count - 2],
                    pointY[count - 2],
                    x,
                    y
                )
            } else {
                normal = MetalHelper.avgNormal(
                    pointX[index - 1],
                    pointY[index - 1],
                    x,
                    y,
                    pointX[index + 1],
                    pointY[index + 1]
                )
            }

            let alpha = points[index].second
            let ribbonWidth: Float =
                0.022 * widthScale * (0.3 + 0.7 * alpha)

            context.ribbonFloats
                .put(x - normal.0 * ribbonWidth)
                .put(y - normal.1 * ribbonWidth)
                .put(1).put(0.82).put(0.12).put(alpha).put(-1)

            context.ribbonFloats
                .put(x + normal.0 * ribbonWidth)
                .put(y + normal.1 * ribbonWidth)
                .put(1).put(0.82).put(0.12).put(alpha).put(1)
        }

        drawGold(
            buffer: context.ribbonFloats,
            mode: MGL_TRIANGLE_STRIP,
            count: count * 2
        )
    }

    private func spawnFromTrack(
        _ trackData: MetalTrackData,
        context: MetalRenderContext
    ) {
        let viewWidth = Float(context.viewWidth)
        let viewHeight = Float(context.viewHeight)
        let minDimension = min(viewWidth, viewHeight)

        guard minDimension > 0 else {
            return
        }

        for (trackID, points) in trackData where points.count >= 2 {
            let point = points[points.count - 1].first
            let previous = points[points.count - 2].first

            let x =
                Float(point.center.x * 2 - 1)
                * context.quadScaleX
            let y =
                Float(1 - point.center.y * 2)
                * context.quadScaleY
            let previousX =
                Float(previous.center.x * 2 - 1)
                * context.quadScaleX
            let previousY =
                Float(1 - previous.center.y * 2)
                * context.quadScaleY

            let dx = x - previousX
            let dy = y - previousY
            let movement = hypot(dx, dy)
            let movementAngle = atan2(
                dy * viewHeight,
                dx * viewWidth
            )

            let distance: Float
            if let last = lastPosition[trackID] {
                distance = hypot(x - last.0, y - last.1)
            } else {
                distance = .greatestFiniteMagnitude
            }

            guard distance > 0.0035 else {
                continue
            }

            lastPosition[trackID] = (x, y)

            /// 依軌跡區段建立固定種子，讓不同渲染入口產生同一組粒子參數。
            seedRandom(
                x: x,
                y: y,
                previousX: previousX,
                previousY: previousY
            )

            let safeDeltaScale = max(context.dtScale, 0.1)
            let normalizedMovement = movement / safeDeltaScale

            if normalizedMovement > 0.005 {
                let baseCount = Float(
                    1 + min(Int(normalizedMovement * 70), 2)
                )
                let count = deterministicEmissionCount(
                    baseCount: baseCount,
                    context: context
                )
                let speed = minDimension
                    * (0.006 + normalizedMovement * 0.35)

                for _ in 0..<count {
                    spawnCoin(
                        x: x,
                        y: y,
                        angle: movementAngle
                            + .pi
                            + randomFloat(in: -0.3...0.3),
                        speedPx: speed
                            * randomFloat(in: 0.7...1.1),
                        minDimension: minDimension
                    )
                }

                if deterministicShouldSpawn(
                    baseProbability: 0.60,
                    context: context
                ) {
                    spawnSpark(
                        x: x,
                        y: y,
                        angle: movementAngle + .pi,
                        coneHalf: 0.4,
                        count: 1,
                        context: context
                    )
                }
            }

            if normalizedMovement > 0.012 {
                let backAngle = movementAngle + Float.pi
                let burst = deterministicEmissionCount(
                    baseCount: Float(randomInt(in: 3...5)),
                    context: context
                )

                for _ in 0..<burst {
                    spawnCoin(
                        x: x,
                        y: y,
                        angle: backAngle
                            + randomFloat(in: -0.7...0.7),
                        speedPx: minDimension
                            * randomFloat(in: 0.008...0.020),
                        minDimension: minDimension
                    )
                }

                let ringCount = deterministicEmissionCount(
                    baseCount: 1,
                    context: context
                )

                for _ in 0..<ringCount {
                    spawnRing(
                        x: x,
                        y: y,
                        movement: normalizedMovement,
                        minDimension: minDimension
                    )
                }

                spawnSpark(
                    x: x,
                    y: y,
                    angle: backAngle,
                    coneHalf: 0.7,
                    count: 3,
                    context: context
                )
            }
        }
    }

    private func spawnCoin(
        x: Float,
        y: Float,
        angle: Float,
        speedPx: Float,
        minDimension: Float
    ) {
        guard let coin = coins.first(where: { !$0.active }) else {
            return
        }

        coin.active = true
        coin.x = x
        coin.y = y
        coin.vx = cos(angle) * speedPx
        coin.vy = sin(angle) * speedPx + minDimension * 0.006
        coin.angle = randomFloat(in: 0...(2 * Float.pi))
        coin.angularVelocity = randomFloat(in: -0.25...0.25)
        coin.flip = randomFloat(in: 0...(2 * Float.pi))
        coin.flipVelocity = randomFloat(in: 0.25...0.65)
        coin.sizePx = minDimension * randomFloat(in: 0.020...0.036)
        coin.alpha = 1
        coin.decay = randomFloat(in: 0.045...0.080)

        switch randomInt(in: 0...3) {
        case 0:
            (coin.r, coin.g, coin.b) = (1, 0.90, 0.35)
        case 3:
            (coin.r, coin.g, coin.b) = (0.85, 0.60, 0.10)
        default:
            (coin.r, coin.g, coin.b) = (1, 0.82, 0.12)
        }
    }

    private func updateCoins(context: MetalRenderContext) {
        let deltaScale = context.dtScale

        for coin in coins where coin.active {
            coin.x += coin.vx * deltaScale / halfWidth
            coin.y += coin.vy * deltaScale / halfHeight
            coin.vy -= 0.6 * deltaScale
            coin.vx *= max(1 - 0.02 * deltaScale, 0)
            coin.angle += coin.angularVelocity * deltaScale
            coin.flip += coin.flipVelocity * deltaScale
            coin.alpha -= coin.decay * deltaScale

            if coin.alpha <= 0 {
                coin.active = false
            }
        }
    }

    private func drawCoins(context: MetalRenderContext) {
        coinFloats.clear()
        var quadCount = 0

        for coin in coins where coin.active {
            let flipScale: Float =
                0.18 + 0.82 * abs(cos(coin.flip))
            let sizeScale = context.particleSizeMultiplier
            let halfCoinWidth = coin.sizePx * 0.5 * flipScale * sizeScale
            let halfCoinHeight = coin.sizePx * 0.5 * sizeScale
            let cosine = cos(coin.angle)
            let sine = sin(coin.angle)
            let alpha = coin.alpha.metalClamped()

            func corner(_ unitX: Float, _ unitY: Float) -> (Float, Float) {
                let localX = unitX * halfCoinWidth
                let localY = unitY * halfCoinHeight
                let rotatedX = localX * cosine - localY * sine
                let rotatedY = localX * sine + localY * cosine

                return (
                    coin.x + rotatedX / halfWidth,
                    coin.y + rotatedY / halfHeight
                )
            }

            let topLeft = corner(-1, -1)
            let topRight = corner(1, -1)
            let bottomRight = corner(1, 1)
            let bottomLeft = corner(-1, 1)

            putCoin(topLeft, uv: (-1, -1), coin: coin, alpha: alpha)
            putCoin(topRight, uv: (1, -1), coin: coin, alpha: alpha)
            putCoin(bottomRight, uv: (1, 1), coin: coin, alpha: alpha)
            putCoin(topLeft, uv: (-1, -1), coin: coin, alpha: alpha)
            putCoin(bottomRight, uv: (1, 1), coin: coin, alpha: alpha)
            putCoin(bottomLeft, uv: (-1, 1), coin: coin, alpha: alpha)
            quadCount += 1
        }

        guard quadCount > 0 else {
            return
        }

        metalUseProgram(coinProgram)
        MetalHelper.drawInterleaved(
            buffer: coinFloats,
            strideBytes: 32,
            attributes: [
                MetalVertexAttribute(
                    location: coinPosLoc,
                    size: 2,
                    offsetBytes: 0
                ),
                MetalVertexAttribute(
                    location: coinUVLoc,
                    size: 2,
                    offsetBytes: 8
                ),
                MetalVertexAttribute(
                    location: coinColorLoc,
                    size: 4,
                    offsetBytes: 16
                )
            ],
            mode: MGL_TRIANGLES,
            vertexCount: quadCount * 6
        )
    }

    private func putCoin(
        _ point: (Float, Float),
        uv: (Float, Float),
        coin: Coin,
        alpha: Float
    ) {
        coinFloats
            .put(point.0).put(point.1)
            .put(uv.0).put(uv.1)
            .put(coin.r).put(coin.g).put(coin.b).put(alpha)
    }

    private func spawnSpark(
        x: Float,
        y: Float,
        angle: Float,
        coneHalf: Float,
        count: Int,
        context: MetalRenderContext
    ) {
        let targetCount = deterministicEmissionCount(
            baseCount: Float(count),
            context: context
        )

        guard targetCount > 0 else {
            return
        }

        var spawned = 0

        for spark in sparks where !spark.active {
            let particleAngle =
                angle + randomFloat(in: -coneHalf...coneHalf)
            let speed = randomFloat(in: 8...28)

            spark.active = true
            spark.x = x
            spark.y = y
            spark.vx = cos(particleAngle) * speed
            spark.vy = sin(particleAngle) * speed
            spark.alpha = 1
            spark.decay = randomFloat(in: 0.07...0.13)
            spark.halfWidthPx = randomFloat(in: 1.4...3.2)

            if randomUnit() > 0.4 {
                (spark.r, spark.g, spark.b) = (1, 0.95, 0.6)
            } else {
                (spark.r, spark.g, spark.b) = (1, 1, 1)
            }

            spawned += 1

            if spawned >= targetCount {
                return
            }
        }
    }

    private func updateSparks(context: MetalRenderContext) {
        let deltaScale = context.dtScale
        let friction = max(1 - 0.08 * deltaScale, 0)

        for spark in sparks where spark.active {
            spark.x += spark.vx * deltaScale / halfWidth
            spark.y += spark.vy * deltaScale / halfHeight
            spark.vx *= friction
            spark.vy *= friction
            spark.alpha -= spark.decay * deltaScale

            if spark.alpha <= 0 {
                spark.active = false
            }
        }
    }

    private func drawSparks(context: MetalRenderContext) {
        sparkFloats.clear()
        var vertexCount = 0

        for spark in sparks where spark.active {
            let speed = max(hypot(spark.vx, spark.vy), 0.001)
            let directionX = spark.vx / speed
            let directionY = spark.vy / speed
            let length = context.scaledParticleSize(speed * 2.6 + 3)
            let endX = spark.x + directionX * length / halfWidth
            let endY = spark.y + directionY * length / halfHeight
            let halfSparkWidth = context.scaledParticleSize(
                spark.halfWidthPx
            )
            let normalX = -directionY * halfSparkWidth / halfWidth
            let normalY = directionX * halfSparkWidth / halfHeight
            let alpha = spark.alpha.metalClamped()

            func put(
                _ x: Float,
                _ y: Float,
                _ distance: Float,
                _ vertexAlpha: Float
            ) {
                sparkFloats
                    .put(x).put(y)
                    .put(spark.r).put(spark.g).put(spark.b)
                    .put(vertexAlpha).put(distance)
            }

            put(spark.x - normalX, spark.y - normalY, -1, alpha)
            put(spark.x + normalX, spark.y + normalY, 1, alpha)
            put(endX - normalX, endY - normalY, -1, alpha * 0.30)
            put(spark.x + normalX, spark.y + normalY, 1, alpha)
            put(endX + normalX, endY + normalY, 1, alpha * 0.30)
            put(endX - normalX, endY - normalY, -1, alpha * 0.30)
            vertexCount += 6
        }

        guard vertexCount > 0 else {
            return
        }

        drawGold(
            buffer: sparkFloats,
            mode: MGL_TRIANGLES,
            count: vertexCount
        )
    }

    private func spawnRing(
        x: Float,
        y: Float,
        movement: Float,
        minDimension: Float
    ) {
        guard let ring = rings.first(where: { !$0.active }) else {
            return
        }

        ring.active = true
        ring.x = x
        ring.y = y
        ring.radiusPx = minDimension * 0.010
        ring.maxRadiusPx = min(
            minDimension * (0.035 + movement * 0.4),
            minDimension * 0.065
        )
        ring.alpha = 0.7
    }

    private func updateRings(dt: Float) {
        for ring in rings where ring.active {
            ring.radiusPx +=
                (ring.maxRadiusPx - ring.radiusPx) * 0.22 * dt
            ring.alpha -= 0.06 * dt

            if ring.alpha <= 0 ||
                ring.maxRadiusPx - ring.radiusPx < 1 {
                ring.active = false
            }
        }
    }

    private func drawRings(context: MetalRenderContext) {
        let minDimension = Float(
            min(context.viewWidth, context.viewHeight)
        )

        guard minDimension > 0 else {
            return
        }

        for ring in rings where ring.active {
            drawRadialBand(
                centerX: ring.x,
                centerY: ring.y,
                radiusPx: context.scaledParticleSize(ring.radiusPx),
                halfBandPx: context.scaledParticleSize(
                    minDimension * 0.0034
                ),
                segments: 24,
                alpha: ring.alpha.metalClamped(),
                context: context
            )
        }
    }

    private func drawRadialBand(
        centerX: Float,
        centerY: Float,
        radiusPx: Float,
        halfBandPx: Float,
        segments: Int,
        alpha: Float,
        context: MetalRenderContext
    ) {
        let width = Float(context.viewWidth)
        let height = Float(context.viewHeight)
        let inner = max(radiusPx - halfBandPx, 0)
        let outer = radiusPx + halfBandPx

        context.ribbonFloats.clear()

        for index in 0...segments {
            let angle =
                2 * Float.pi * Float(index) / Float(segments)
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
            buffer: context.ribbonFloats,
            mode: MGL_TRIANGLE_STRIP,
            count: (segments + 1) * 2
        )
    }

    private func drawGold(
        buffer: MetalFloatBuffer,
        mode: MetalPrimitiveCode,
        count: Int
    ) {
        metalUseProgram(goldProgram)
        MetalHelper.drawInterleaved(
            buffer: buffer,
            strideBytes: 28,
            attributes: [
                MetalVertexAttribute(
                    location: goldPosLoc,
                    size: 2,
                    offsetBytes: 0
                ),
                MetalVertexAttribute(
                    location: goldColorLoc,
                    size: 4,
                    offsetBytes: 8
                ),
                MetalVertexAttribute(
                    location: goldDistLoc,
                    size: 1,
                    offsetBytes: 24
                )
            ],
            mode: mode,
            vertexCount: count
        )
    }

    // MARK: - Deterministic particle generation

    private func seedRandom(
        x: Float,
        y: Float,
        previousX: Float,
        previousY: Float
    ) {
        func quantized(_ value: Float) -> UInt64 {
            let scaled = Int64((value * 100_000).rounded())
            return UInt64(bitPattern: scaled)
        }

        var seed = quantized(x) &* 0x9E37_79B9_7F4A_7C15
        seed ^= quantized(y) &* 0xBF58_476D_1CE4_E5B9
        seed ^= quantized(previousX) &* 0x94D0_49BB_1331_11EB
        seed ^= quantized(previousY) &* 0xD6E8_FEB8_6659_FD93

        randomState = seed == 0
            ? 0x4D4F_4E45_595F_4658
            : seed
    }

    private func randomUnit() -> Float {
        randomState &+= 0x9E37_79B9_7F4A_7C15

        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31

        let fraction = value >> 40
        return Float(fraction) / Float(1 << 24)
    }

    private func randomFloat(
        in range: ClosedRange<Float>
    ) -> Float {
        range.lowerBound
            + (range.upperBound - range.lowerBound) * randomUnit()
    }

    private func randomInt(
        in range: ClosedRange<Int>
    ) -> Int {
        let count = max(range.upperBound - range.lowerBound + 1, 1)
        let index = min(Int(randomUnit() * Float(count)), count - 1)
        return range.lowerBound + index
    }

    private func deterministicEmissionCount(
        baseCount: Float,
        context: MetalRenderContext
    ) -> Int {
        let expected = max(baseCount, 0)
            * context.particleFrequencyMultiplier
        let whole = Int(expected.rounded(.down))
        let fraction = expected - Float(whole)

        if fraction > 0,
           randomUnit() < fraction {
            return whole + 1
        }

        return whole
    }

    private func deterministicShouldSpawn(
        baseProbability: Float,
        context: MetalRenderContext
    ) -> Bool {
        let probability = max(min(baseProbability, 1), 0)
        let frequency = context.particleFrequencyMultiplier

        guard probability > 0,
              frequency > 0 else {
            return false
        }

        return randomUnit() < min(probability * frequency, 1)
    }
}
