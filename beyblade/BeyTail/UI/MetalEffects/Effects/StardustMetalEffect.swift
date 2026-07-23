import UIKit

/// Dynamic-color multi-strand stardust trail based on the supplied reference video.
///
/// Visual structure:
/// - five close parallel light strands
/// - angular segment transitions
/// - color-matched strands brightened toward white
/// - sparse cross-shaped glints controlled by the global particle profile
final class StardustMetalEffect: MetalEffect {
    private struct StrandNode {
        let x: Float
        let y: Float
        let alpha: Float
        let color: UIColor
    }

    private final class Glint {
        var active = false
        var x: Float = 0
        var y: Float = 0
        var alpha: Float = 0
        var sizePixels: Float = 0
        var angle: Float = 0
        var red: Float = 1
        var green: Float = 1
        var blue: Float = 1
    }

    private var program: MetalProgramID = 0
    private var positionLocation: MetalLocation = -1
    private var colorLocation: MetalLocation = -1

    private let strandFloats = MetalFloatBuffer(
        capacity:
            StardustMetalEffect.maximumNodes
            * 2
            * 6
    )

    private let glintFloats = MetalFloatBuffer(
        capacity:
            StardustMetalEffect.maximumGlints
            * 16
            * 6
    )

    private let glints = (0..<StardustMetalEffect.maximumGlints).map {
        _ in Glint()
    }

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
        guard effectType == .stardust else {
            reset()
            return
        }

        metalUseProgram(program)

        spawnGlints(
            trackData: trackData,
            context: context
        )

        for (_, points) in trackData
        where points.count >= 2 {
            let nodes = makeNodes(
                points,
                context: context
            )

            guard nodes.count >= 2 else {
                continue
            }

            drawStrands(
                nodes,
                context: context,
                widthMultiplier:
                    effectType.trailWidthMultiplier
            )
        }

        updateGlints(
            dt: context.dtScale
        )

        drawGlints(
            context: context,
            widthMultiplier:
                effectType.trailWidthMultiplier
        )
    }

    override func reset() {
        lastPosition.removeAll(
            keepingCapacity: true
        )

        strandFloats.clear()
        glintFloats.clear()

        for glint in glints {
            glint.active = false
            glint.x = 0
            glint.y = 0
            glint.alpha = 0
            glint.sizePixels = 0
            glint.angle = 0
            glint.red = 1
            glint.green = 1
            glint.blue = 1
        }
    }

    private func makeNodes(
        _ points: [MetalTrailSample],
        context: MetalRenderContext
    ) -> [StrandNode] {
        let lastIndex = points.count - 1

        var sourceIndices = Array(
            Swift.stride(
                from: 0,
                through: lastIndex,
                by: StardustMetalEffect.nodeStride
            )
        )

        if sourceIndices.last != lastIndex {
            sourceIndices.append(lastIndex)
        }

        if sourceIndices.count
            > StardustMetalEffect.maximumNodes {
            sourceIndices = Array(
                sourceIndices.suffix(
                    StardustMetalEffect.maximumNodes
                )
            )
        }

        return sourceIndices.map {
            sourceIndex in
            let sample = points[sourceIndex]
            let position =
                FreeEffectRenderSupport.clipPosition(
                    sample.first,
                    context: context
                )

            return StrandNode(
                x: position.0,
                y: position.1,
                alpha: sample.second,
                color: sample.first.color
            )
        }
    }

    private func drawStrands(
        _ nodes: [StrandNode],
        context: MetalRenderContext,
        widthMultiplier: Float
    ) {
        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        for strand in (-StardustMetalEffect.outerStrandCount)...StardustMetalEffect.outerStrandCount {
            let absoluteStrand =
                abs(strand)

            let intensity =
                absoluteStrand == 0
                ? Float(1)
                : absoluteStrand == 1
                    ? Float(0.78)
                    : Float(0.56)

            drawStrand(
                nodes,
                strand: strand,
                context: context,
                widthMultiplier:
                    widthMultiplier,
                lineWidth:
                    StardustMetalEffect.glowWidthPixels
                    * widthMultiplier,
                whiteMix: 0.62,
                alphaScale:
                    0.11 * intensity
            )

            drawStrand(
                nodes,
                strand: strand,
                context: context,
                widthMultiplier:
                    widthMultiplier,
                lineWidth:
                    StardustMetalEffect.coreWidthPixels
                    * widthMultiplier,
                whiteMix:
                    absoluteStrand == 0
                    ? 0.66
                    : 0.76,
                alphaScale:
                    0.68 * intensity
            )
        }

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    private func drawStrand(
        _ nodes: [StrandNode],
        strand: Int,
        context: MetalRenderContext,
        widthMultiplier: Float,
        lineWidth: Float,
        whiteMix: Float,
        alphaScale: Float
    ) {
        strandFloats.clear()

        let offsetPixels =
            Float(strand)
            * StardustMetalEffect.strandSpacingPixels
            * widthMultiplier

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        for index in 1..<nodes.count {
            let previous = nodes[index - 1]
            let current = nodes[index]

            let normal =
                FreeEffectRenderSupport.segmentNormal(
                    x0: previous.x,
                    y0: previous.y,
                    x1: current.x,
                    y1: current.y
                )

            let offsetX =
                normal.0
                * offsetPixels
                * clipPerPixel

            let offsetY =
                normal.1
                * offsetPixels
                * clipPerPixel

            let previousColor =
                FreeEffectRenderSupport.mixedColor(
                    previous.color,
                    whiteMix: whiteMix,
                    alpha:
                        previous.alpha
                        * alphaScale
                )

            let currentColor =
                FreeEffectRenderSupport.mixedColor(
                    current.color,
                    whiteMix: whiteMix,
                    alpha:
                        current.alpha
                        * alphaScale
                )

            FreeEffectRenderSupport.appendLineVertex(
                to: strandFloats,
                x:
                    previous.x + offsetX,
                y:
                    previous.y + offsetY,
                color: previousColor
            )

            FreeEffectRenderSupport.appendLineVertex(
                to: strandFloats,
                x:
                    current.x + offsetX,
                y:
                    current.y + offsetY,
                color: currentColor
            )
        }

        let vertexCount =
            (nodes.count - 1) * 2

        guard vertexCount > 0 else {
            return
        }

        metalLineWidth(
            max(lineWidth, 1)
        )

        MetalHelper.drawInterleaved(
            buffer: strandFloats,
            strideBytes: StardustMetalEffect.bytesPerVertex,
            attributes: lineAttributes,
            mode: MGL_LINES,
            vertexCount: vertexCount
        )
    }

    private func spawnGlints(
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

            defer {
                lastPosition[trackID] = latest
            }

            guard let last =
                    lastPosition[trackID] else {
                continue
            }

            let dx = latest.0 - last.0
            let dy = latest.1 - last.1
            let distance =
                sqrt(dx * dx + dy * dy)

            guard distance
                    > StardustMetalEffect.minimumSpawnDistance,
                  context.shouldSpawnParticle(
                    baseProbability:
                        StardustMetalEffect.glintSpawnProbability
                  ),
                  let glint =
                    glints.first(
                        where: {
                            !$0.active
                        }
                    ) else {
                continue
            }

            let recentCount = min(
                points.count,
                StardustMetalEffect.glintRecentPointCount
            )

            let sourceIndex =
                points.count - 1
                - Int.random(
                    in: 0..<recentCount
                )

            let source = points[sourceIndex]
            let position =
                FreeEffectRenderSupport.clipPosition(
                    source.first,
                    context: context
                )

            let color =
                MetalHelper.rgba(
                    source.first.color
                )

            glint.active = true
            glint.x = position.0
            glint.y = position.1
            glint.alpha =
                Float.random(
                    in: 0.45...0.75
                )
            glint.sizePixels =
                Float.random(
                    in: 3.5...6.5
                )
            glint.angle =
                Float.random(
                    in: 0...(2 * .pi)
                )
            glint.red = color.0
            glint.green = color.1
            glint.blue = color.2
        }
    }

    private func updateGlints(
        dt: Float
    ) {
        for glint in glints
        where glint.active {
            glint.alpha -=
                StardustMetalEffect.glintFade * dt

            glint.sizePixels +=
                StardustMetalEffect.glintGrowthPixels * dt

            if glint.alpha <= 0 {
                glint.active = false
            }
        }
    }

    private func drawGlints(
        context: MetalRenderContext,
        widthMultiplier: Float
    ) {
        glintFloats.clear()

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        var segmentCount = 0

        for glint in glints
        where glint.active {
            let size =
                glint.sizePixels
                * context.particleSizeMultiplier
                * clipPerPixel

            let diagonal =
                size * 0.68

            let color =
                (
                    glint.red
                        + (1 - glint.red) * 0.82,
                    glint.green
                        + (1 - glint.green) * 0.82,
                    glint.blue
                        + (1 - glint.blue) * 0.82,
                    glint.alpha
                )

            appendRay(
                glint: glint,
                angle: glint.angle,
                halfLength: size,
                color: color
            )

            appendRay(
                glint: glint,
                angle:
                    glint.angle + .pi / 2,
                halfLength: size,
                color: color
            )

            appendRay(
                glint: glint,
                angle:
                    glint.angle + .pi / 4,
                halfLength: diagonal,
                color:
                    (
                        color.0,
                        color.1,
                        color.2,
                        color.3 * 0.55
                    )
            )

            appendRay(
                glint: glint,
                angle:
                    glint.angle - .pi / 4,
                halfLength: diagonal,
                color:
                    (
                        color.0,
                        color.1,
                        color.2,
                        color.3 * 0.55
                    )
            )

            segmentCount += 8
        }

        guard segmentCount > 0 else {
            return
        }

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        metalLineWidth(
            max(
                StardustMetalEffect.glintLineWidthPixels
                * widthMultiplier,
                1
            )
        )

        MetalHelper.drawInterleaved(
            buffer: glintFloats,
            strideBytes: StardustMetalEffect.bytesPerVertex,
            attributes: lineAttributes,
            mode: MGL_LINES,
            vertexCount: segmentCount * 2
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    private func appendRay(
        glint: Glint,
        angle: Float,
        halfLength: Float,
        color: (Float, Float, Float, Float)
    ) {
        let dx = cos(angle) * halfLength
        let dy = sin(angle) * halfLength

        FreeEffectRenderSupport.appendLineVertex(
            to: glintFloats,
            x: glint.x,
            y: glint.y,
            color: color
        )

        FreeEffectRenderSupport.appendLineVertex(
            to: glintFloats,
            x: glint.x + dx,
            y: glint.y + dy,
            color:
                (
                    color.0,
                    color.1,
                    color.2,
                    0
                )
        )

        FreeEffectRenderSupport.appendLineVertex(
            to: glintFloats,
            x: glint.x,
            y: glint.y,
            color: color
        )

        FreeEffectRenderSupport.appendLineVertex(
            to: glintFloats,
            x: glint.x - dx,
            y: glint.y - dy,
            color:
                (
                    color.0,
                    color.1,
                    color.2,
                    0
                )
        )
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
    private static let maximumNodes = 128
    private static let maximumGlints = 24

    private static let nodeStride = 2
    private static let outerStrandCount = 2

    private static let strandSpacingPixels: Float = 1.20
    private static let glowWidthPixels: Float = 2.10
    private static let coreWidthPixels: Float = 0.55

    private static let minimumSpawnDistance: Float = 0.004
    private static let glintSpawnProbability: Float = 0.075
    private static let glintRecentPointCount = 10
    private static let glintFade: Float = 0.095
    private static let glintGrowthPixels: Float = 0.20
    private static let glintLineWidthPixels: Float = 0.42
}
