import UIKit

/// Port of BladeMetalEffect.kt:
/// double-helix blade, metal sparks, cracks, glints and sword-qi waves.
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

    private let sparks = (0..<28).map { _ in
        Spark()
    }

    private let cracks = (0..<4).map { _ in
        Crack()
    }

    private let glints = (0..<10).map { _ in
        Glint()
    }

    private let waves = (0..<4).map { _ in
        SlashWave()
    }

    private let sparkFloats = MetalFloatBuffer(
        capacity: 28 * 6 * 7
    )

    private var lastPosition: [
        Int: (Float, Float)
    ] = [:]

    private var pointX = [
        Float
    ](
        repeating: 0,
        count: 256
    )

    private var pointY = [
        Float
    ](
        repeating: 0,
        count: 256
    )

    private var resampledX = [
        Float
    ](
        repeating: 0,
        count: 64
    )

    private var resampledY = [
        Float
    ](
        repeating: 0,
        count: 64
    )

    private var resampledAlpha = [
        Float
    ](
        repeating: 0,
        count: 64
    )

    // MARK: - Metal setup

    override func onMetalReady(
        context: MetalRenderContext
    ) {
        program = MetalHelper.makeProgram(
            .blade
        )

        posLoc = metalGetAttribLocation(
            program,
            "aPosition"
        )

        colorLoc = metalGetAttribLocation(
            program,
            "aColor"
        )

        distLoc = metalGetAttribLocation(
            program,
            "aCenterDist"
        )
    }

    // MARK: - Draw

    override func draw(
        trackData: MetalTrackData,
        context: MetalRenderContext,
        effectType: EffectType
    ) {
        /*
         防呆保護：

         即使外部錯誤地沿用了 BladeMetalEffect，
         只要目前選擇的不是 vortex，就完全不允許
         繪製任何刀刃、火花、裂紋或劍氣。
         */
        guard effectType == .vortex else {
            reset()
            return
        }

        metalUseProgram(program)

        spawnFromTrack(
            trackData,
            context: context
        )

        for (_, points) in trackData
        where points.count >= 3 {
            drawBlade(
                points,
                context: context,
                widthScale:
                    effectType
                    .trailWidthMultiplier
            )
        }

        updateCracks(
            dt: context.dtScale
        )

        drawCracks(
            context: context
        )

        updateSparks(
            context: context
        )

        drawSparks(
            context: context
        )

        updateWaves(
            context: context
        )

        drawWaves(
            context: context
        )

        updateGlints(
            dt: context.dtScale
        )

        drawGlints(
            context: context
        )
    }

    // MARK: - Reset

    /// 完整清除爆刃亂舞的跨幀狀態。
    ///
    /// 外部切換到其他特效時，應呼叫此方法。
    /// draw() 發現 effectType 不是 vortex 時也會自動呼叫。
    override func reset() {
        for spark in sparks {
            spark.active = false
            spark.x = 0
            spark.y = 0
            spark.vx = 0
            spark.vy = 0
            spark.alpha = 0
            spark.r = 1
            spark.g = 1
            spark.b = 1
        }

        for crack in cracks {
            crack.active = false
            crack.x1 = 0
            crack.y1 = 0
            crack.x2 = 0
            crack.y2 = 0
            crack.alpha = 0
        }

        for glint in glints {
            glint.active = false
            glint.x = 0
            glint.y = 0
            glint.angle = 0
            glint.sizePx = 0
            glint.progress = 0
        }

        for wave in waves {
            wave.active = false
            wave.x = 0
            wave.y = 0
            wave.angle = 0
            wave.vx = 0
            wave.vy = 0
            wave.radiusPx = 0
            wave.alpha = 0
            wave.r = 1
            wave.g = 1
            wave.b = 1
        }

        lastPosition.removeAll(
            keepingCapacity: true
        )

        sparkFloats.clear()

        for index in pointX.indices {
            pointX[index] = 0
        }

        for index in pointY.indices {
            pointY[index] = 0
        }

        for index in resampledX.indices {
            resampledX[index] = 0
        }

        for index in resampledY.indices {
            resampledY[index] = 0
        }

        for index in resampledAlpha.indices {
            resampledAlpha[index] = 0
        }
    }

    // MARK: - Blade body

    private func drawBlade(
        _ points: [MetalTrailSample],
        context: MetalRenderContext,
        widthScale: Float
    ) {
        let pointCount = min(
            points.count,
            256
        )

        guard pointCount >= 3 else {
            return
        }

        for index in 0..<pointCount {
            pointX[index] =
                Float(
                    points[index]
                        .first.center.x * 2 - 1
                )
                * context.quadScaleX

            pointY[index] =
                Float(
                    1
                    - points[index]
                        .first.center.y * 2
                )
                * context.quadScaleY
        }

        let resampledCount = min(
            pointCount * 3,
            64
        )

        for index in 0..<resampledCount {
            let interpolationPosition =
                Float(index)
                / Float(resampledCount - 1)
                * Float(pointCount - 1)

            let sourceIndex = min(
                Int(interpolationPosition),
                pointCount - 2
            )

            let fraction =
                interpolationPosition
                - Float(sourceIndex)

            resampledX[index] =
                pointX[sourceIndex]
                + (
                    pointX[sourceIndex + 1]
                    - pointX[sourceIndex]
                )
                * fraction

            resampledY[index] =
                pointY[sourceIndex]
                + (
                    pointY[sourceIndex + 1]
                    - pointY[sourceIndex]
                )
                * fraction

            resampledAlpha[index] =
                points[sourceIndex].second
                + (
                    points[sourceIndex + 1].second
                    - points[sourceIndex].second
                )
                * fraction
        }

        guard let lastPoint = points.last else {
            return
        }

        let baseColor = MetalHelper.vivid(
            lastPoint.first.color
        )

        let secondaryColor =
            MetalHelper.hueShift(
                baseColor,
                degrees: 38
            )

        for strand in 0..<2 {
            let color = MetalHelper.rgba(
                strand == 0
                    ? baseColor
                    : secondaryColor
            )

            let phase =
                Float(strand) * .pi

            context.ribbonFloats.clear()

            for index in 0..<resampledCount {
                let x = resampledX[index]
                let y = resampledY[index]

                let normal: (Float, Float)

                if index == 0 {
                    normal =
                        MetalHelper.segNormal(
                            x,
                            y,
                            resampledX[1],
                            resampledY[1]
                        )
                } else if index
                            == resampledCount - 1 {
                    normal =
                        MetalHelper.segNormal(
                            resampledX[index - 1],
                            resampledY[index - 1],
                            x,
                            y
                        )
                } else {
                    normal =
                        MetalHelper.avgNormal(
                            resampledX[index - 1],
                            resampledY[index - 1],
                            x,
                            y,
                            resampledX[index + 1],
                            resampledY[index + 1]
                        )
                }

                let progress =
                    Float(index)
                    / Float(resampledCount - 1)

                let envelope =
                    sin(.pi * progress)

                let offset =
                    sin(
                        progress
                        * 2.2
                        * 2
                        * .pi
                        + phase
                    )
                    * 0.016
                    * envelope

                let centerX =
                    x + normal.0 * offset

                let centerY =
                    y + normal.1 * offset

                let halfWidth: Float =
                    0.012
                    * widthScale
                    * envelope

                let alphaTemplate: Float

                if progress < 0.3 {
                    alphaTemplate =
                        progress
                        / 0.3
                        * 0.5
                } else if progress < 0.8 {
                    alphaTemplate =
                        0.5
                        + (
                            progress - 0.3
                        )
                        / 0.5
                        * 0.45
                } else {
                    alphaTemplate =
                        0.95
                        + (
                            progress - 0.8
                        )
                        / 0.2
                        * 0.05
                }

                let alpha =
                    alphaTemplate
                    * sqrt(
                        max(
                            resampledAlpha[index],
                            0
                        )
                    )

                let whiteMix =
                    (
                        (
                            progress - 0.75
                        )
                        / 0.25
                    )
                    .metalClamped()

                let red =
                    color.0
                    + (
                        1 - color.0
                    )
                    * whiteMix

                let green =
                    color.1
                    + (
                        1 - color.1
                    )
                    * whiteMix

                let blue =
                    color.2
                    + (
                        1 - color.2
                    )
                    * whiteMix

                context.ribbonFloats
                    .put(
                        centerX
                        - normal.0
                        * halfWidth
                    )
                    .put(
                        centerY
                        - normal.1
                        * halfWidth
                    )
                    .put(red)
                    .put(green)
                    .put(blue)
                    .put(alpha)
                    .put(-1)

                context.ribbonFloats
                    .put(
                        centerX
                        + normal.0
                        * halfWidth
                    )
                    .put(
                        centerY
                        + normal.1
                        * halfWidth
                    )
                    .put(red)
                    .put(green)
                    .put(blue)
                    .put(alpha)
                    .put(1)
            }

            drawBladeBuffer(
                context.ribbonFloats,
                mode: MGL_TRIANGLE_STRIP,
                count: resampledCount * 2
            )
        }
    }

    // MARK: - Particle spawn

    private func spawnFromTrack(
        _ trackData: MetalTrackData,
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        let minDimension = min(
            width,
            height
        )

        guard minDimension > 0 else {
            return
        }

        for (trackID, points) in trackData
        where points.count >= 2 {
            guard let currentSample =
                    points.last else {
                continue
            }

            let point =
                currentSample.first

            let previous =
                points[
                    points.count - 2
                ].first

            let x =
                Float(
                    point.center.x * 2 - 1
                )
                * context.quadScaleX

            let y =
                Float(
                    1 - point.center.y * 2
                )
                * context.quadScaleY

            let previousX =
                Float(
                    previous.center.x * 2 - 1
                )
                * context.quadScaleX

            let previousY =
                Float(
                    1 - previous.center.y * 2
                )
                * context.quadScaleY

            let deltaX = x - previousX
            let deltaY = y - previousY

            let movement =
                hypot(
                    deltaX,
                    deltaY
                )

            let distance: Float =
                lastPosition[trackID]
                .map {
                    hypot(
                        x - $0.0,
                        y - $0.1
                    )
                }
                ?? .greatestFiniteMagnitude

            guard distance > 0.005 else {
                continue
            }

            lastPosition[trackID] = (
                x,
                y
            )

            let normalizedMovement =
                movement
                / max(
                    context.dtScale,
                    0.0001
                )

            if normalizedMovement > 0.009 {
                let emissionCount =
                    context
                    .particleEmissionCount(
                        baseCount: 1
                    )

                for _ in 0..<emissionCount {
                    emitFromBody(
                        points,
                        minDimension:
                            minDimension,
                        context: context
                    )
                }
            }

            if normalizedMovement > 0.008 {
                let velocityX =
                    deltaX
                    * width
                    * 0.5
                    / max(
                        context.dtScale,
                        0.0001
                    )

                let velocityY =
                    deltaY
                    * height
                    * 0.5
                    / max(
                        context.dtScale,
                        0.0001
                    )

                if context
                    .shouldSpawnParticle(
                        baseProbability: 0.70
                    ) {
                    spawnSpark(
                        x: x,
                        y: y,
                        vx: velocityX,
                        vy: velocityY
                    )
                }

                if context
                    .shouldSpawnParticle(
                        baseProbability: 0.50
                    ) {
                    spawnSpark(
                        x: x,
                        y: y,
                        vx: velocityX,
                        vy: velocityY
                    )
                }

                if context
                    .shouldSpawnParticle(
                        baseProbability: 0.60
                    ) {
                    spawnCrack(
                        x1: previousX,
                        y1: previousY,
                        x2: x,
                        y2: y,
                        minDimension:
                            minDimension,
                        context: context
                    )
                }

                if context
                    .shouldSpawnParticle(
                        baseProbability: 0.60
                    ) {
                    spawnWave(
                        x: x,
                        y: y,
                        movementAngle:
                            atan2(
                                deltaY * height,
                                deltaX * width
                            ),
                        movement:
                            normalizedMovement,
                        minDimension:
                            minDimension,
                        color: point.color
                    )
                }
            }
        }
    }

    private func emitFromBody(
        _ points: [MetalTrailSample],
        minDimension: Float,
        context: MetalRenderContext
    ) {
        guard points.count >= 3 else {
            return
        }

        let index = Int.random(
            in: 1...(points.count - 2)
        )

        let point =
            points[index].first

        let previous =
            points[index - 1].first

        let next =
            points[index + 1].first

        let x =
            Float(
                point.center.x * 2 - 1
            )
            * context.quadScaleX

        let y =
            Float(
                1 - point.center.y * 2
            )
            * context.quadScaleY

        let deltaX =
            Float(
                next.center.x
                - previous.center.x
            )
            * context.quadScaleX
            * Float(context.viewWidth)

        let deltaY =
            -Float(
                next.center.y
                - previous.center.y
            )
            * context.quadScaleY
            * Float(context.viewHeight)

        let length = max(
            hypot(
                deltaX,
                deltaY
            ),
            0.001
        )

        let perpendicularX =
            -deltaY / length

        let perpendicularY =
            deltaX / length

        let emissionCount =
            context
            .particleEmissionCount(
                baseCount:
                    Bool.random()
                    ? 2
                    : 1
            )

        for _ in 0..<emissionCount {
            let side: Float =
                Bool.random()
                ? 1
                : -1

            let burst =
                Float.random(
                    in: 3...8
                )

            spawnSparkRaw(
                x: x,
                y: y,
                vx:
                    perpendicularX
                    * side
                    * burst
                    - deltaX
                    / length
                    * Float.random(
                        in: 0...2.5
                    )
                    + Float.random(
                        in: -1.5...1.5
                    ),
                vy:
                    perpendicularY
                    * side
                    * burst
                    - deltaY
                    / length
                    * Float.random(
                        in: 0...2.5
                    )
                    + Float.random(
                        in: -1.5...1.5
                    )
            )
        }

        if context
            .shouldSpawnParticle(
                baseProbability: 0.55
            ) {
            spawnGlint(
                x: x,
                y: y,
                minDimension:
                    minDimension
            )
        }
    }

    private func spawnGlint(
        x: Float,
        y: Float,
        minDimension: Float
    ) {
        guard let glint =
                glints.first(
                    where: {
                        !$0.active
                    }
                ) else {
            return
        }

        glint.active = true

        glint.x =
            x
            + Float.random(
                in: -0.0075...0.0075
            )

        glint.y =
            y
            + Float.random(
                in: -0.0075...0.0075
            )

        glint.angle =
            Float.random(
                in: 0...Float.pi
            )

        glint.sizePx =
            minDimension
            * Float.random(
                in: 0.008...0.016
            )

        glint.progress = 0
    }

    private func spawnSparkRaw(
        x: Float,
        y: Float,
        vx: Float,
        vy: Float
    ) {
        guard let spark =
                sparks.first(
                    where: {
                        !$0.active
                    }
                ) else {
            return
        }

        spark.active = true
        spark.x = x
        spark.y = y
        spark.vx = vx
        spark.vy = vy
        spark.alpha = 1

        if Double.random(
            in: 0...1
        ) > 0.4 {
            (
                spark.r,
                spark.g,
                spark.b
            ) = (
                0.88,
                0.95,
                1
            )
        } else {
            (
                spark.r,
                spark.g,
                spark.b
            ) = (
                1,
                0.94,
                0.54
            )
        }
    }

    private func spawnSpark(
        x: Float,
        y: Float,
        vx: Float,
        vy: Float
    ) {
        spawnSparkRaw(
            x: x,
            y: y,
            vx:
                vx * 0.4
                + Float.random(
                    in: -5...5
                ),
            vy:
                vy * 0.4
                + Float.random(
                    in: -5...5
                )
        )
    }

    private func spawnCrack(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        minDimension: Float,
        context: MetalRenderContext
    ) {
        guard let crack =
                cracks.first(
                    where: {
                        !$0.active
                    }
                ) else {
            return
        }

        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        let deltaX =
            (x2 - x1) * width

        let deltaY =
            (y2 - y1) * height

        let length = max(
            hypot(
                deltaX,
                deltaY
            ),
            0.001
        )

        let offset =
            Float.random(
                in: -0.5...0.5
            )
            * minDimension
            * 0.030

        let offsetX =
            -deltaY
            / length
            * offset
            / max(
                width / 2,
                1
            )

        let offsetY =
            deltaX
            / length
            * offset
            / max(
                height / 2,
                1
            )

        let extensionX =
            (x2 - x1) * 0.8

        let extensionY =
            (y2 - y1) * 0.8

        crack.active = true

        crack.x1 =
            x1
            + offsetX
            - extensionX

        crack.y1 =
            y1
            + offsetY
            - extensionY

        crack.x2 =
            x2
            + offsetX
            + extensionX

        crack.y2 =
            y2
            + offsetY
            + extensionY

        crack.alpha = 0.9
    }

    // MARK: - Cracks

    private func updateCracks(
        dt: Float
    ) {
        for crack in cracks
        where crack.active {
            crack.alpha -=
                0.25 * dt

            if crack.alpha <= 0 {
                crack.active = false
                crack.alpha = 0
            }
        }
    }

    private func drawCracks(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        context.ribbonFloats.clear()

        var vertexCount = 0

        for crack in cracks
        where crack.active {
            let deltaX =
                (crack.x2 - crack.x1)
                * width

            let deltaY =
                (crack.y2 - crack.y1)
                * height

            let length = max(
                hypot(
                    deltaX,
                    deltaY
                ),
                0.001
            )

            let crackWidthPixels =
                context.scaledParticleSize(
                    1.2
                )

            let normalX =
                -deltaY
                / length
                * crackWidthPixels
                / max(
                    width / 2,
                    1
                )

            let normalY =
                deltaX
                / length
                * crackWidthPixels
                / max(
                    height / 2,
                    1
                )

            let alpha =
                crack.alpha
                .metalClamped()
                * 0.6

            func put(
                _ x: Float,
                _ y: Float,
                _ distance: Float
            ) {
                context.ribbonFloats
                    .put(x)
                    .put(y)
                    .put(0.73)
                    .put(0.90)
                    .put(0.99)
                    .put(alpha)
                    .put(distance)
            }

            put(
                crack.x1 - normalX,
                crack.y1 - normalY,
                -1
            )

            put(
                crack.x1 + normalX,
                crack.y1 + normalY,
                1
            )

            put(
                crack.x2 - normalX,
                crack.y2 - normalY,
                -1
            )

            put(
                crack.x1 + normalX,
                crack.y1 + normalY,
                1
            )

            put(
                crack.x2 + normalX,
                crack.y2 + normalY,
                1
            )

            put(
                crack.x2 - normalX,
                crack.y2 - normalY,
                -1
            )

            vertexCount += 6
        }

        if vertexCount > 0 {
            drawBladeBuffer(
                context.ribbonFloats,
                mode: MGL_TRIANGLES,
                count: vertexCount
            )
        }
    }

    // MARK: - Sparks

    private func updateSparks(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        let deltaTime =
            context.dtScale

        let friction =
            1 - 0.08 * deltaTime

        for spark in sparks
        where spark.active {
            spark.x +=
                spark.vx
                * deltaTime
                / max(
                    width * 0.5,
                    1
                )

            spark.y +=
                spark.vy
                * deltaTime
                / max(
                    height * 0.5,
                    1
                )

            spark.vx *= friction
            spark.vy *= friction

            spark.alpha -=
                0.12 * deltaTime

            if spark.alpha <= 0 {
                spark.active = false
                spark.alpha = 0
            }
        }
    }

    private func drawSparks(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        sparkFloats.clear()

        var vertexCount = 0

        for spark in sparks
        where spark.active {
            let speed = max(
                hypot(
                    spark.vx,
                    spark.vy
                ),
                0.001
            )

            let directionX =
                spark.vx / speed

            let directionY =
                spark.vy / speed

            let sparkLength =
                context.scaledParticleSize(
                    speed * 1.5 + 4
                )

            let endX =
                spark.x
                + directionX
                * sparkLength
                / max(
                    width * 0.5,
                    1
                )

            let endY =
                spark.y
                + directionY
                * sparkLength
                / max(
                    height * 0.5,
                    1
                )

            let sparkWidthPixels =
                context.scaledParticleSize(
                    1.6
                )

            let normalX =
                -directionY
                * sparkWidthPixels
                / max(
                    width * 0.5,
                    1
                )

            let normalY =
                directionX
                * sparkWidthPixels
                / max(
                    height * 0.5,
                    1
                )

            let alpha =
                spark.alpha
                .metalClamped()

            func put(
                _ x: Float,
                _ y: Float,
                _ distance: Float,
                _ vertexAlpha: Float
            ) {
                sparkFloats
                    .put(x)
                    .put(y)
                    .put(spark.r)
                    .put(spark.g)
                    .put(spark.b)
                    .put(vertexAlpha)
                    .put(distance)
            }

            put(
                spark.x - normalX,
                spark.y - normalY,
                -1,
                alpha
            )

            put(
                spark.x + normalX,
                spark.y + normalY,
                1,
                alpha
            )

            put(
                endX - normalX,
                endY - normalY,
                -1,
                alpha * 0.25
            )

            put(
                spark.x + normalX,
                spark.y + normalY,
                1,
                alpha
            )

            put(
                endX + normalX,
                endY + normalY,
                1,
                alpha * 0.25
            )

            put(
                endX - normalX,
                endY - normalY,
                -1,
                alpha * 0.25
            )

            vertexCount += 6
        }

        if vertexCount > 0 {
            drawBladeBuffer(
                sparkFloats,
                mode: MGL_TRIANGLES,
                count: vertexCount
            )
        }
    }

    // MARK: - Slash waves

    private func spawnWave(
        x: Float,
        y: Float,
        movementAngle: Float,
        movement: Float,
        minDimension: Float,
        color: UIColor
    ) {
        guard let wave =
                waves.first(
                    where: {
                        !$0.active
                    }
                ) else {
            return
        }

        let speed =
            10
            + Float.random(
                in: 0...6
            )
            + movement
            * minDimension
            * 0.15

        wave.active = true
        wave.x = x
        wave.y = y

        wave.angle =
            movementAngle
            + Float.random(
                in: -0.2...0.2
            )

        wave.vx =
            cos(wave.angle) * speed

        wave.vy =
            sin(wave.angle) * speed

        wave.radiusPx =
            minDimension
            * Float.random(
                in: 0.035...0.055
            )

        wave.alpha = 0.95

        let colorValues =
            MetalHelper.rgba(
                MetalHelper.vivid(color)
            )

        wave.r =
            colorValues.0
            * 0.75
            + 0.25

        wave.g =
            colorValues.1
            * 0.75
            + 0.25

        wave.b =
            colorValues.2
            * 0.75
            + 0.25
    }

    private func updateWaves(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        let deltaTime =
            context.dtScale

        for wave in waves
        where wave.active {
            wave.x +=
                wave.vx
                * deltaTime
                / max(
                    width * 0.5,
                    1
                )

            wave.y +=
                wave.vy
                * deltaTime
                / max(
                    height * 0.5,
                    1
                )

            wave.radiusPx *=
                1
                + 0.03
                * deltaTime

            wave.alpha -=
                0.10
                * deltaTime

            if wave.alpha <= 0 {
                wave.active = false
                wave.alpha = 0
            }
        }
    }

    private func drawWaves(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        let particleSizeScale =
            context.particleSizeMultiplier

        let maximumBand =
            min(
                width,
                height
            )
            * 0.008
            * particleSizeScale

        for wave in waves
        where wave.active {
            context.ribbonFloats.clear()

            for index in 0...12 {
                let progress =
                    Float(index) / 12

                let angle =
                    wave.angle
                    - Float.pi / 3.2
                    + progress
                    * 2
                    * Float.pi
                    / 3.2

                let band =
                    maximumBand
                    * sin(.pi * progress)

                let radiusPixels =
                    wave.radiusPx
                    * particleSizeScale

                let innerRadius = max(
                    radiusPixels - band,
                    0
                )

                let outerRadius =
                    radiusPixels + band

                let cosine =
                    cos(angle)

                let sine =
                    sin(angle)

                let alpha =
                    wave.alpha
                    .metalClamped()

                context.ribbonFloats
                    .put(
                        wave.x
                        + cosine
                        * innerRadius
                        / max(
                            width / 2,
                            1
                        )
                    )
                    .put(
                        wave.y
                        + sine
                        * innerRadius
                        / max(
                            height / 2,
                            1
                        )
                    )
                    .put(wave.r)
                    .put(wave.g)
                    .put(wave.b)
                    .put(alpha)
                    .put(-1)

                context.ribbonFloats
                    .put(
                        wave.x
                        + cosine
                        * outerRadius
                        / max(
                            width / 2,
                            1
                        )
                    )
                    .put(
                        wave.y
                        + sine
                        * outerRadius
                        / max(
                            height / 2,
                            1
                        )
                    )
                    .put(wave.r)
                    .put(wave.g)
                    .put(wave.b)
                    .put(alpha)
                    .put(1)
            }

            drawBladeBuffer(
                context.ribbonFloats,
                mode: MGL_TRIANGLE_STRIP,
                count: 26
            )
        }
    }

    // MARK: - Glints

    private func updateGlints(
        dt: Float
    ) {
        for glint in glints
        where glint.active {
            glint.progress +=
                0.16 * dt

            if glint.progress >= 1 {
                glint.active = false
                glint.progress = 0
            }
        }
    }

    private func drawGlints(
        context: MetalRenderContext
    ) {
        let width =
            Float(context.viewWidth)

        let height =
            Float(context.viewHeight)

        context.ribbonFloats.clear()

        var vertexCount = 0

        for glint in glints
        where glint.active {
            let alpha =
                sin(
                    .pi
                    * glint.progress
                )

            let glintSizePixels =
                glint.sizePx
                * context
                    .particleSizeMultiplier

            let armWidth =
                glintSizePixels * 0.16

            for arm in 0..<2 {
                let angle =
                    glint.angle
                    + Float(arm)
                    * .pi
                    / 2

                let directionX =
                    cos(angle)

                let directionY =
                    sin(angle)

                let lengthX =
                    directionX
                    * glintSizePixels
                    / max(
                        width / 2,
                        1
                    )

                let lengthY =
                    directionY
                    * glintSizePixels
                    / max(
                        height / 2,
                        1
                    )

                let normalX =
                    -directionY
                    * armWidth
                    / max(
                        width / 2,
                        1
                    )

                let normalY =
                    directionX
                    * armWidth
                    / max(
                        height / 2,
                        1
                    )

                func put(
                    _ x: Float,
                    _ y: Float,
                    _ distance: Float
                ) {
                    context.ribbonFloats
                        .put(x)
                        .put(y)
                        .put(0.95)
                        .put(0.98)
                        .put(1)
                        .put(alpha)
                        .put(distance)
                }

                put(
                    glint.x - lengthX,
                    glint.y - lengthY,
                    0
                )

                put(
                    glint.x + normalX,
                    glint.y + normalY,
                    1
                )

                put(
                    glint.x - normalX,
                    glint.y - normalY,
                    -1
                )

                put(
                    glint.x + normalX,
                    glint.y + normalY,
                    1
                )

                put(
                    glint.x + lengthX,
                    glint.y + lengthY,
                    0
                )

                put(
                    glint.x - normalX,
                    glint.y - normalY,
                    -1
                )

                vertexCount += 6
            }
        }

        if vertexCount > 0 {
            drawBladeBuffer(
                context.ribbonFloats,
                mode: MGL_TRIANGLES,
                count: vertexCount
            )
        }
    }

    // MARK: - Buffer drawing

    private func drawBladeBuffer(
        _ buffer: MetalFloatBuffer,
        mode: MetalPrimitiveCode,
        count: Int
    ) {
        guard count > 0 else {
            return
        }

        metalUseProgram(program)

        MetalHelper.drawInterleaved(
            buffer: buffer,
            strideBytes: 28,
            attributes: [
                MetalVertexAttribute(
                    location: posLoc,
                    size: 2,
                    offsetBytes: 0
                ),
                MetalVertexAttribute(
                    location: colorLoc,
                    size: 4,
                    offsetBytes: 8
                ),
                MetalVertexAttribute(
                    location: distLoc,
                    size: 1,
                    offsetBytes: 24
                )
            ],
            mode: mode,
            vertexCount: count
        )
    }
}
