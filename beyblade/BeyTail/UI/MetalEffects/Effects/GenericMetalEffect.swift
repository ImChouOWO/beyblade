import UIKit

/// 基礎特效專用的純軌跡 renderer。
///
/// 適用：
/// - lightning
/// - fire
/// - stardust
///
/// 只繪製兩層 Ribbon：
/// 1. 外層 Glow
/// 2. 內層 Core
///
/// 不包含：
/// - Spark
/// - Particle
/// - Sprite
/// - Crack
/// - Glint
/// - Slash wave
final class GenericMetalEffect: MetalEffect {
    private var program: MetalProgramID = 0
    private var positionLocation: MetalLocation = -1
    private var colorLocation: MetalLocation = -1

    override func onMetalReady(
        context: MetalRenderContext
    ) {
        program = MetalHelper.makeProgram(.flatColor)

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
        metalUseProgram(program)

        for (_, points) in trackData {
            guard points.count >= 2 else {
                continue
            }

            let trailColor =
                effectType.colorOverride
                ?? points.last?.first.color
                ?? .white

            // 外層光暈
            drawRibbon(
                points,
                halfWidth:
                    0.070
                    * effectType.glowWidthMult
                    * effectType.trailWidthMultiplier,
                alphaScale: 0.45,
                coreBoost: 0,
                headColor: trailColor,
                context: context
            )

            // 內層核心
            drawRibbon(
                points,
                halfWidth:
                    0.022
                    * effectType.coreWidthMult
                    * effectType.trailWidthMultiplier,
                alphaScale: 0.92,
                coreBoost: 0.55,
                headColor: trailColor,
                context: context
            )
        }
    }

    override func reset() {
        // GenericMetalEffect 沒有粒子池或跨幀狀態，
        // 因此不需要額外清除資料。
    }

    private func drawRibbon(
        _ points: [MetalTrailSample],
        halfWidth: Float,
        alphaScale: Float,
        coreBoost: Float,
        headColor: UIColor,
        context: MetalRenderContext
    ) {
        let pointCount = points.count

        guard pointCount >= 2 else {
            return
        }

        guard pointCount
                * 2
                * Self.bytesPerVertex
                <= context.ribbonFloats.capacityBytes else {
            return
        }

        let baseColor = MetalHelper.rgba(
            headColor
        )

        context.ribbonFloats.clear()

        for index in 0..<pointCount {
            let sample = points[index]
            let point = sample.first
            let alpha = sample.second

            let x =
                Float(point.center.x * 2 - 1)
                * context.quadScaleX

            let y =
                Float(1 - point.center.y * 2)
                * context.quadScaleY

            let normal: (Float, Float)

            if index == 0 {
                let nextPoint =
                    points[1].first.center

                normal = MetalHelper.segNormal(
                    x,
                    y,
                    Float(nextPoint.x * 2 - 1)
                        * context.quadScaleX,
                    Float(1 - nextPoint.y * 2)
                        * context.quadScaleY
                )
            } else if index == pointCount - 1 {
                let previousPoint =
                    points[pointCount - 2]
                        .first.center

                normal = MetalHelper.segNormal(
                    Float(previousPoint.x * 2 - 1)
                        * context.quadScaleX,
                    Float(1 - previousPoint.y * 2)
                        * context.quadScaleY,
                    x,
                    y
                )
            } else {
                let previousPoint =
                    points[index - 1]
                        .first.center

                let nextPoint =
                    points[index + 1]
                        .first.center

                normal = MetalHelper.avgNormal(
                    Float(previousPoint.x * 2 - 1)
                        * context.quadScaleX,
                    Float(1 - previousPoint.y * 2)
                        * context.quadScaleY,
                    x,
                    y,
                    Float(nextPoint.x * 2 - 1)
                        * context.quadScaleX,
                    Float(1 - nextPoint.y * 2)
                        * context.quadScaleY
                )
            }

            let currentHalfWidth =
                halfWidth
                * alpha
                * (1 - alpha * 0.7)

            let red = brighten(
                baseColor.0,
                alpha: alpha,
                coreBoost: coreBoost
            )

            let green = brighten(
                baseColor.1,
                alpha: alpha,
                coreBoost: coreBoost
            )

            let blue = brighten(
                baseColor.2,
                alpha: alpha,
                coreBoost: coreBoost
            )

            let outputAlpha =
                alpha * alphaScale

            context.ribbonFloats
                .put(
                    x
                    - normal.0
                    * currentHalfWidth
                )
                .put(
                    y
                    - normal.1
                    * currentHalfWidth
                )
                .put(red)
                .put(green)
                .put(blue)
                .put(outputAlpha)

            context.ribbonFloats
                .put(
                    x
                    + normal.0
                    * currentHalfWidth
                )
                .put(
                    y
                    + normal.1
                    * currentHalfWidth
                )
                .put(red)
                .put(green)
                .put(blue)
                .put(outputAlpha)
        }

        MetalHelper.drawInterleaved(
            buffer: context.ribbonFloats,
            strideBytes: Self.bytesPerVertex,
            attributes: [
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
            ],
            mode: MGL_TRIANGLE_STRIP,
            vertexCount: pointCount * 2
        )
    }

    private func brighten(
        _ component: Float,
        alpha: Float,
        coreBoost: Float
    ) -> Float {
        (
            component
            + (1 - component)
            * coreBoost
            * alpha
        )
        .metalClamped()
    }

    private static let bytesPerVertex = 24
}
