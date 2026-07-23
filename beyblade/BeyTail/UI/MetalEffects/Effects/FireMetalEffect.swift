import UIKit

/// Dynamic-color flame trail based on the supplied reference video.
///
/// Visual structure:
/// - a thick irregular ribbon that follows the detected beyblade color
/// - a brighter hot core
/// - sparse detached flame wisps controlled by the global particle profile
final class FireMetalEffect: MetalEffect {
    private final class FlameWisp {
        var active = false
        var x: Float = 0
        var y: Float = 0
        var vx: Float = 0
        var vy: Float = 0
        var alpha: Float = 0
        var sizePixels: Float = 0
        var red: Float = 1
        var green: Float = 1
        var blue: Float = 1
    }

    private var program: MetalProgramID = 0
    private var positionLocation: MetalLocation = -1
    private var colorLocation: MetalLocation = -1

    private var time: Float = 0

    private var pointX = [
        Float
    ](
        repeating: 0,
        count: FireMetalEffect.maximumTrailPoints
    )

    private var pointY = [
        Float
    ](
        repeating: 0,
        count: FireMetalEffect.maximumTrailPoints
    )

    private var cumulativeLength = [
        Float
    ](
        repeating: 0,
        count: FireMetalEffect.maximumTrailPoints
    )

    private let wisps = (0..<FireMetalEffect.maximumWisps).map {
        _ in FlameWisp()
    }

    private let wispFloats = MetalFloatBuffer(
        capacity:
            FireMetalEffect.maximumWisps
            * 3
            * 6
    )

    private var lastPosition: [
        Int: (Float, Float)
    ] = [:]

    override func onMetalReady(
        context: MetalRenderContext
    ) {
        program = MetalHelper.makeProgram(
            .flatColor
        )

        positionLocation = metalGetAttribLocation(
            program,
            "aPosition"
        )

        colorLocation = metalGetAttribLocation(
            program,
            "aColor"
        )
    }

    override func draw(
        trackData: MetalTrackData,
        context: MetalRenderContext,
        effectType: EffectType
    ) {
        guard effectType == .fire else {
            reset()
            return
        }

        time += (1.0 / 30.0) * context.dtScale

        metalUseProgram(program)

        spawnWisps(
            trackData: trackData,
            context: context
        )

        for (trackID, points) in trackData
        where points.count >= 2 {
            drawFlameRibbon(
                points,
                trackID: trackID,
                context: context,
                widthMultiplier:
                    effectType.trailWidthMultiplier
            )
        }

        updateWisps(
            dt: context.dtScale
        )

        drawWisps(
            context: context
        )
    }

    override func reset() {
        time = 0
        lastPosition.removeAll(
            keepingCapacity: true
        )

        for wisp in wisps {
            wisp.active = false
            wisp.x = 0
            wisp.y = 0
            wisp.vx = 0
            wisp.vy = 0
            wisp.alpha = 0
            wisp.sizePixels = 0
            wisp.red = 1
            wisp.green = 1
            wisp.blue = 1
        }

        wispFloats.clear()
    }

    private func drawFlameRibbon(
        _ points: [MetalTrailSample],
        trackID: Int,
        context: MetalRenderContext,
        widthMultiplier: Float
    ) {
        let count = min(
            points.count,
            FireMetalEffect.maximumTrailPoints
        )

        guard count >= 2,
              count
                * 2
                * FireMetalEffect.bytesPerVertex
                <= context.ribbonFloats.capacityBytes else {
            return
        }

        for index in 0..<count {
            let position =
                FreeEffectRenderSupport.clipPosition(
                    points[index].first,
                    context: context
                )

            pointX[index] = position.0
            pointY[index] = position.1

            if index == 0 {
                cumulativeLength[index] = 0
            } else {
                let dx =
                    pointX[index]
                    - pointX[index - 1]

                let dy =
                    pointY[index]
                    - pointY[index - 1]

                cumulativeLength[index] =
                    cumulativeLength[index - 1]
                    + sqrt(dx * dx + dy * dy)
            }
        }

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )

        // 深色火焰外層：保留陀螺色相，但降低亮度以增加火焰厚度感。
        drawFlamePass(
            points,
            count: count,
            trackID: trackID,
            context: context,
            widthMultiplier: widthMultiplier,
            widthScale: 1.0,
            brightnessScale: 0.58,
            whiteMix: 0.0,
            alphaScale: 0.88,
            corePulse: false
        )

        // 中層火焰：比外層明亮，但仍維持飽和主色。
        drawFlamePass(
            points,
            count: count,
            trackID: trackID,
            context: context,
            widthMultiplier: widthMultiplier,
            widthScale: 0.58,
            brightnessScale: 0.82,
            whiteMix: 0.08,
            alphaScale: 0.88,
            corePulse: false
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        // 高溫火芯：寬度與透明度沿軌跡跳動，避免形成均勻的白色管線。
        drawFlamePass(
            points,
            count: count,
            trackID: trackID,
            context: context,
            widthMultiplier: widthMultiplier,
            widthScale: 0.22,
            brightnessScale: 1.0,
            whiteMix: 0.72,
            alphaScale: 0.92,
            corePulse: true
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    private func drawFlamePass(
        _ points: [MetalTrailSample],
        count: Int,
        trackID: Int,
        context: MetalRenderContext,
        widthMultiplier: Float,
        widthScale: Float,
        brightnessScale: Float,
        whiteMix: Float,
        alphaScale: Float,
        corePulse: Bool
    ) {
        context.ribbonFloats.clear()

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        let timeStep = floor(
            time * FireMetalEffect.edgeStepsPerSecond
        )

        for index in 0..<count {
            let x = pointX[index]
            let y = pointY[index]

            let normal: (Float, Float)

            if index == 0 {
                normal =
                    MetalHelper.segNormal(
                        x,
                        y,
                        pointX[1],
                        pointY[1]
                    )
            } else if index == count - 1 {
                normal =
                    MetalHelper.segNormal(
                        pointX[index - 1],
                        pointY[index - 1],
                        x,
                        y
                    )
            } else {
                normal =
                    MetalHelper.avgNormal(
                        pointX[index - 1],
                        pointY[index - 1],
                        x,
                        y,
                        pointX[index + 1],
                        pointY[index + 1]
                    )
            }

            let phase =
                cumulativeLength[index]
                * 44
                - time * 4.2
                + Float(trackID) * 0.73

            let steppedNoise =
                FreeEffectRenderSupport.signedHash(
                    Float(trackID) * 19.1
                    + Float(index) * 5.83
                    + timeStep * 2.47
                )

            let turbulence =
                sin(phase) * 0.48
                + sin(
                    phase * 2.35 + 1.7
                ) * 0.27
                + steppedNoise * 0.25

            let centerOffsetPixels =
                turbulence
                * FireMetalEffect.centerJitterPixels
                * context.particleSizeMultiplier

            let centerX =
                x
                + normal.0
                * centerOffsetPixels
                * clipPerPixel

            let centerY =
                y
                + normal.1
                * centerOffsetPixels
                * clipPerPixel

            let alpha =
                points[index].second

            let headTaper =
                1.0
                - 0.34 * alpha

            let widthNoise =
                0.82
                + abs(turbulence) * 0.34

            let heatPulse =
                corePulse
                ? FireMetalEffect.corePulse(
                    phase: phase,
                    noise: steppedNoise,
                    alpha: alpha
                )
                : 1.0

            let halfWidth =
                FireMetalEffect.baseHalfWidth
                * widthMultiplier
                * widthScale
                * headTaper
                * widthNoise
                * heatPulse

            let color =
                FireMetalEffect.flameColor(
                    points[index].first.color,
                    brightnessScale: brightnessScale,
                    whiteMix: whiteMix,
                    alpha:
                        alpha
                        * alphaScale
                        * (corePulse ? heatPulse : 1.0)
                )

            context.ribbonFloats
                .put(
                    centerX
                    - normal.0 * halfWidth
                )
                .put(
                    centerY
                    - normal.1 * halfWidth
                )
                .put(color.0)
                .put(color.1)
                .put(color.2)
                .put(color.3)

            context.ribbonFloats
                .put(
                    centerX
                    + normal.0 * halfWidth
                )
                .put(
                    centerY
                    + normal.1 * halfWidth
                )
                .put(color.0)
                .put(color.1)
                .put(color.2)
                .put(color.3)
        }

        MetalHelper.drawInterleaved(
            buffer: context.ribbonFloats,
            strideBytes: FireMetalEffect.bytesPerVertex,
            attributes: lineAttributes,
            mode: MGL_TRIANGLE_STRIP,
            vertexCount: count * 2
        )
    }


    private static func flameColor(
        _ color: UIColor,
        brightnessScale: Float,
        whiteMix: Float,
        alpha: Float
    ) -> (Float, Float, Float, Float) {
        let vivid = MetalHelper.rgba(
            MetalHelper.vivid(color)
        )

        let darkRed = vivid.0 * brightnessScale
        let darkGreen = vivid.1 * brightnessScale
        let darkBlue = vivid.2 * brightnessScale
        let mix = whiteMix.metalClamped()

        return (
            (darkRed + (1 - darkRed) * mix).metalClamped(),
            (darkGreen + (1 - darkGreen) * mix).metalClamped(),
            (darkBlue + (1 - darkBlue) * mix).metalClamped(),
            alpha.metalClamped()
        )
    }

    private static func corePulse(
        phase: Float,
        noise: Float,
        alpha: Float
    ) -> Float {
        let primary = 0.5 + 0.5 * sin(phase * 1.18 + 0.7)
        let secondary = 0.5 + 0.5 * sin(phase * 2.73 - 1.1)
        let combined = primary * 0.58 + secondary * 0.26 + (noise + 1) * 0.08

        // 火芯在部分區段收細或中斷，頭部附近則維持較高亮度。
        let gated = max((combined - 0.22) / 0.78, 0.12)
        return (gated * (0.72 + 0.28 * alpha)).metalClamped(0.12, 1.0)
    }

    private func spawnWisps(
        trackData: MetalTrackData,
        context: MetalRenderContext
    ) {
        guard context.particleFrequencyMultiplier > 0 else {
            return
        }

        for (trackID, points) in trackData
        where points.count >= 2 {
            let latest =
                FreeEffectRenderSupport.clipPosition(
                    points[points.count - 1].first,
                    context: context
                )

            let previous =
                FreeEffectRenderSupport.clipPosition(
                    points[points.count - 2].first,
                    context: context
                )

            defer {
                lastPosition[trackID] = latest
            }

            guard let last =
                    lastPosition[trackID] else {
                continue
            }

            let movedX =
                latest.0 - last.0

            let movedY =
                latest.1 - last.1

            let movedDistance =
                sqrt(
                    movedX * movedX
                    + movedY * movedY
                )

            guard movedDistance
                    > FireMetalEffect.minimumSpawnDistance,
                  context.shouldSpawnParticle(
                    baseProbability:
                        FireMetalEffect.wispSpawnProbability
                  ) else {
                continue
            }

            let tangentX =
                latest.0 - previous.0

            let tangentY =
                latest.1 - previous.1

            let tangentLength = max(
                sqrt(
                    tangentX * tangentX
                    + tangentY * tangentY
                ),
                0.000_001
            )

            let tx = tangentX / tangentLength
            let ty = tangentY / tangentLength
            let nx = -ty
            let ny = tx

            let color = MetalHelper.rgba(
                points.last?.first.color
                ?? .white
            )

            let emissionCount =
                context.particleEmissionCount(
                    baseCount:
                        FireMetalEffect.baseWispCount
                )

            for emissionIndex in 0..<emissionCount {
                guard let wisp =
                        wisps.first(
                            where: {
                                !$0.active
                            }
                        ) else {
                    break
                }

                let side: Float =
                    emissionIndex.isMultiple(of: 2)
                    ? 1
                    : -1

                let lateral =
                    Float.random(
                        in: 0.0015...0.0045
                    )

                let backward =
                    Float.random(
                        in: 0.0015...0.0040
                    )

                wisp.active = true
                wisp.x =
                    latest.0
                    + nx * side * 0.0015
                wisp.y =
                    latest.1
                    + ny * side * 0.0015
                wisp.vx =
                    nx * side * lateral
                    - tx * backward
                wisp.vy =
                    ny * side * lateral
                    - ty * backward
                    + 0.0012
                wisp.alpha =
                    Float.random(
                        in: 0.55...0.85
                    )
                wisp.sizePixels =
                    Float.random(
                        in: 4.5...8.5
                    )
                wisp.red = color.0
                wisp.green = color.1
                wisp.blue = color.2
            }
        }
    }

    private func updateWisps(
        dt: Float
    ) {
        for wisp in wisps
        where wisp.active {
            wisp.x += wisp.vx * dt
            wisp.y += wisp.vy * dt

            wisp.vx *= max(
                1.0 - 0.06 * dt,
                0.0
            )

            wisp.vy +=
                FireMetalEffect.wispLift
                * dt

            wisp.alpha -=
                FireMetalEffect.wispFade
                * dt

            if wisp.alpha <= 0 {
                wisp.active = false
            }
        }
    }

    private func drawWisps(
        context: MetalRenderContext
    ) {
        wispFloats.clear()

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        var count = 0

        for wisp in wisps
        where wisp.active {
            let length = max(
                sqrt(
                    wisp.vx * wisp.vx
                    + wisp.vy * wisp.vy
                ),
                0.000_001
            )

            let tx = wisp.vx / length
            let ty = wisp.vy / length
            let nx = -ty
            let ny = tx

            let size =
                wisp.sizePixels
                * context.particleSizeMultiplier
                * clipPerPixel

            let tipX =
                wisp.x + tx * size

            let tipY =
                wisp.y + ty * size

            let baseX =
                wisp.x - tx * size * 0.55

            let baseY =
                wisp.y - ty * size * 0.55

            let halfBase =
                size * 0.34

            // 火舌外觀同樣維持深色主體，只在尖端略微提亮。
            let red =
                wisp.red * 0.76
                + (1 - wisp.red * 0.76) * 0.24

            let green =
                wisp.green * 0.76
                + (1 - wisp.green * 0.76) * 0.24

            let blue =
                wisp.blue * 0.76
                + (1 - wisp.blue * 0.76) * 0.24

            appendWispVertex(
                x: tipX,
                y: tipY,
                red: red,
                green: green,
                blue: blue,
                alpha: 0
            )

            appendWispVertex(
                x:
                    baseX
                    + nx * halfBase,
                y:
                    baseY
                    + ny * halfBase,
                red: red,
                green: green,
                blue: blue,
                alpha: wisp.alpha
            )

            appendWispVertex(
                x:
                    baseX
                    - nx * halfBase,
                y:
                    baseY
                    - ny * halfBase,
                red: red,
                green: green,
                blue: blue,
                alpha: wisp.alpha
            )

            count += 1
        }

        guard count > 0 else {
            return
        }

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        MetalHelper.drawInterleaved(
            buffer: wispFloats,
            strideBytes: FireMetalEffect.bytesPerVertex,
            attributes: lineAttributes,
            mode: MGL_TRIANGLES,
            vertexCount: count * 3
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    private func appendWispVertex(
        x: Float,
        y: Float,
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float
    ) {
        wispFloats
            .put(x)
            .put(y)
            .put(red)
            .put(green)
            .put(blue)
            .put(alpha.metalClamped())
    }

    private var lineAttributes: [
        MetalVertexAttribute
    ] {
        [
            MetalVertexAttribute(
                location: positionLocation,
                size: 2,
                offsetBytes: 0
            ),
            MetalVertexAttribute(
                location: colorLocation,
                size: 4,
                offsetBytes: 8
            )
        ]
    }

    private static let bytesPerVertex = 24
    private static let maximumTrailPoints = 256
    private static let maximumWisps = 36

    private static let baseHalfWidth: Float = 0.0052
    private static let centerJitterPixels: Float = 1.35
    private static let edgeStepsPerSecond: Float = 10

    private static let minimumSpawnDistance: Float = 0.004
    private static let wispSpawnProbability: Float = 0.18
    private static let baseWispCount: Float = 0.72
    private static let wispLift: Float = 0.000_30
    private static let wispFade: Float = 0.070
}
