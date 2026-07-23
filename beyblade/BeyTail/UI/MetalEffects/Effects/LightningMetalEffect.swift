import UIKit

/// 細長、具分支且會跟隨陀螺主色變化的閃電拖尾。
///
/// 視覺結構：
/// - 外層：低透明度的主色光暈
/// - 中層：高飽和度的主色電弧
/// - 內層：略向白色提亮的細電芯
/// - 分支：由主幹節點向側後方分岔，並在末端淡出
final class LightningMetalEffect: MetalEffect {
    private struct BoltNode {
        let x: Float
        let y: Float
        let alpha: Float
        let color: UIColor
    }

    private var program: MetalProgramID = 0
    private var positionLocation: MetalLocation = -1
    private var colorLocation: MetalLocation = -1

    private var time: Float = 0

    private let segmentFloats = MetalFloatBuffer(
        capacity: LightningMetalEffect.maximumNodes * 2 * LightningMetalEffect.floatsPerVertex
    )

    private let branchFloats = MetalFloatBuffer(
        capacity:
            LightningMetalEffect.maximumBranches
            * LightningMetalEffect.maximumVerticesPerBranch
            * LightningMetalEffect.floatsPerVertex
    )

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
        guard effectType == .lightning else {
            reset()
            return
        }

        time += (1.0 / 30.0) * context.dtScale

        if time >= Self.timeWrapSeconds {
            time -= Self.timeWrapSeconds
        }

        metalUseProgram(program)

        for (trackID, points) in trackData
        where points.count >= 2 {
            let nodes = makeNodes(
                points,
                trackID: trackID,
                context: context
            )

            guard nodes.count >= 2 else {
                continue
            }

            drawMainBolt(
                nodes,
                widthMultiplier:
                    effectType.trailWidthMultiplier
            )

            drawBranches(
                nodes,
                trackID: trackID,
                context: context,
                widthMultiplier:
                    effectType.trailWidthMultiplier
            )
        }
    }

    override func reset() {
        time = 0
        segmentFloats.clear()
        branchFloats.clear()
    }

    // MARK: - Main bolt nodes

    private func makeNodes(
        _ points: [MetalTrailSample],
        trackID: Int,
        context: MetalRenderContext
    ) -> [BoltNode] {
        let lastIndex = points.count - 1

        var sourceIndices = Array(
            Swift.stride(
                from: 0,
                through: lastIndex,
                by: Self.nodeStride
            )
        )

        if sourceIndices.last != lastIndex {
            sourceIndices.append(lastIndex)
        }

        if sourceIndices.count > Self.maximumNodes {
            sourceIndices = Array(
                sourceIndices.suffix(Self.maximumNodes)
            )
        }

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        let flickerStep = floor(
            time * Self.flickerStepsPerSecond
        )

        var output: [BoltNode] = []
        output.reserveCapacity(sourceIndices.count)

        for (nodeIndex, sourceIndex) in
            sourceIndices.enumerated() {
            let sample = points[sourceIndex]

            var position =
                FreeEffectRenderSupport.clipPosition(
                    sample.first,
                    context: context
                )

            let previousSourceIndex = max(
                sourceIndex - Self.nodeStride,
                0
            )

            let nextSourceIndex = min(
                sourceIndex + Self.nodeStride,
                lastIndex
            )

            let previous =
                FreeEffectRenderSupport.clipPosition(
                    points[previousSourceIndex].first,
                    context: context
                )

            let next =
                FreeEffectRenderSupport.clipPosition(
                    points[nextSourceIndex].first,
                    context: context
                )

            let normal =
                FreeEffectRenderSupport.segmentNormal(
                    x0: previous.0,
                    y0: previous.1,
                    x1: next.0,
                    y1: next.1
                )

            let progress =
                sourceIndices.count > 1
                ? Float(nodeIndex)
                    / Float(sourceIndices.count - 1)
                : 1

            let endpointEnvelope = sin(.pi * progress)

            let primarySeed =
                Float(trackID) * 31.7
                + Float(sourceIndex) * 7.13
                + flickerStep * 11.9

            let secondarySeed =
                Float(trackID) * 13.1
                + Float(nodeIndex) * 19.7
                + flickerStep * 5.3

            let jitter =
                FreeEffectRenderSupport.signedHash(
                    primarySeed
                )
                + FreeEffectRenderSupport.signedHash(
                    secondarySeed
                ) * 0.35

            let jitterPixels =
                Self.jitterPixels
                * endpointEnvelope
                * jitter

            position.0 +=
                normal.0
                * jitterPixels
                * clipPerPixel

            position.1 +=
                normal.1
                * jitterPixels
                * clipPerPixel

            output.append(
                BoltNode(
                    x: position.0,
                    y: position.1,
                    alpha: sample.second,
                    color: MetalHelper.vivid(
                        sample.first.color
                    )
                )
            )
        }

        return output
    }

    // MARK: - Main bolt drawing

    private func drawMainBolt(
        _ nodes: [BoltNode],
        widthMultiplier: Float
    ) {
        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        drawSegments(
            nodes,
            lineWidth:
                Self.glowWidthPixels
                * widthMultiplier,
            whiteMix: 0,
            alphaScale: 0.22
        )

        drawSegments(
            nodes,
            lineWidth:
                Self.bodyWidthPixels
                * widthMultiplier,
            whiteMix: 0.10,
            alphaScale: 0.68
        )

        drawSegments(
            nodes,
            lineWidth:
                Self.coreWidthPixels
                * widthMultiplier,
            whiteMix: 0.48,
            alphaScale: 0.96
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    private func drawSegments(
        _ nodes: [BoltNode],
        lineWidth: Float,
        whiteMix: Float,
        alphaScale: Float
    ) {
        segmentFloats.clear()

        for index in 1..<nodes.count {
            let first = nodes[index - 1]
            let second = nodes[index]

            let firstColor =
                FreeEffectRenderSupport.mixedColor(
                    first.color,
                    whiteMix: whiteMix,
                    alpha:
                        first.alpha
                        * alphaScale
                )

            let secondColor =
                FreeEffectRenderSupport.mixedColor(
                    second.color,
                    whiteMix: whiteMix,
                    alpha:
                        second.alpha
                        * alphaScale
                )

            FreeEffectRenderSupport.appendLineVertex(
                to: segmentFloats,
                x: first.x,
                y: first.y,
                color: firstColor
            )

            FreeEffectRenderSupport.appendLineVertex(
                to: segmentFloats,
                x: second.x,
                y: second.y,
                color: secondColor
            )
        }

        let vertexCount = (nodes.count - 1) * 2

        guard vertexCount > 0 else {
            return
        }

        metalLineWidth(
            max(lineWidth, 1)
        )

        MetalHelper.drawInterleaved(
            buffer: segmentFloats,
            strideBytes: Self.bytesPerVertex,
            attributes: Self.lineAttributes(
                positionLocation:
                    positionLocation,
                colorLocation:
                    colorLocation
            ),
            mode: MGL_LINES,
            vertexCount: vertexCount
        )
    }

    // MARK: - Branches

    private func drawBranches(
        _ nodes: [BoltNode],
        trackID: Int,
        context: MetalRenderContext,
        widthMultiplier: Float
    ) {
        guard nodes.count >= 4,
              context.particleFrequencyMultiplier > 0 else {
            return
        }

        branchFloats.clear()

        let branchStep = floor(
            time * Self.branchStepsPerSecond
        )

        let probability = min(
            Self.branchProbability
                * context.particleFrequencyMultiplier,
            Self.maximumBranchProbability
        )

        let clipPerPixel =
            FreeEffectRenderSupport.clipPerPixel(
                context: context
            )

        var branchCount = 0
        var branchVertexCount = 0

        for index in 1..<(nodes.count - 1) {
            let node = nodes[index]

            guard node.alpha >= Self.minimumBranchAlpha else {
                continue
            }

            let seed =
                Float(trackID) * 17.3
                + Float(index) * 29.1
                + branchStep * 13.7

            guard FreeEffectRenderSupport.hash(seed)
                    < probability else {
                continue
            }

            branchVertexCount += appendBranch(
                at: index,
                nodes: nodes,
                seed: seed,
                clipPerPixel: clipPerPixel,
                particleSizeMultiplier:
                    context.particleSizeMultiplier
            )

            branchCount += 1

            if branchCount >= Self.maximumBranches {
                break
            }
        }

        if branchCount == 0,
           nodes.count >= 6 {
            let fallbackIndex = min(
                max(nodes.count * 2 / 3, 1),
                nodes.count - 2
            )

            let fallbackSeed =
                Float(trackID) * 23.9
                + branchStep * 17.1

            branchVertexCount += appendBranch(
                at: fallbackIndex,
                nodes: nodes,
                seed: fallbackSeed,
                clipPerPixel: clipPerPixel,
                particleSizeMultiplier:
                    context.particleSizeMultiplier
            )
        }

        guard branchVertexCount > 0 else {
            return
        }

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE
        )

        metalLineWidth(
            max(
                Self.branchWidthPixels
                    * widthMultiplier,
                1
            )
        )

        MetalHelper.drawInterleaved(
            buffer: branchFloats,
            strideBytes: Self.bytesPerVertex,
            attributes: Self.lineAttributes(
                positionLocation:
                    positionLocation,
                colorLocation:
                    colorLocation
            ),
            mode: MGL_LINES,
            vertexCount: branchVertexCount
        )

        metalBlendFunc(
            MGL_SRC_ALPHA,
            MGL_ONE_MINUS_SRC_ALPHA
        )
    }

    @discardableResult
    private func appendBranch(
        at index: Int,
        nodes: [BoltNode],
        seed: Float,
        clipPerPixel: Float,
        particleSizeMultiplier: Float
    ) -> Int {
        let previous = nodes[index - 1]
        let current = nodes[index]
        let next = nodes[index + 1]

        let tangentX = next.x - previous.x
        let tangentY = next.y - previous.y

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

        let side: Float =
            FreeEffectRenderSupport.hash(
                seed + 4.7
            ) >= 0.5
            ? 1
            : -1

        let lengthPixels =
            Self.branchLengthPixels
            * (
                0.72
                + FreeEffectRenderSupport.hash(
                    seed + 9.4
                ) * 0.56
            )
            * max(particleSizeMultiplier, 0)

        let backwardAmount =
            0.22
            + FreeEffectRenderSupport.hash(
                seed + 2.8
            ) * 0.22

        let primaryX =
            nx * side
            - tx * backwardAmount

        let primaryY =
            ny * side
            - ty * backwardAmount

        let bendAmount =
            FreeEffectRenderSupport.signedHash(
                seed + 15.2
            ) * 0.28

        let secondaryX =
            nx * side
            + tx * bendAmount

        let secondaryY =
            ny * side
            + ty * bendAmount

        let middleX =
            current.x
            + primaryX
            * lengthPixels
            * Self.branchMiddleRatio
            * clipPerPixel

        let middleY =
            current.y
            + primaryY
            * lengthPixels
            * Self.branchMiddleRatio
            * clipPerPixel

        let endX =
            middleX
            + secondaryX
            * lengthPixels
            * (1 - Self.branchMiddleRatio)
            * clipPerPixel

        let endY =
            middleY
            + secondaryY
            * lengthPixels
            * (1 - Self.branchMiddleRatio)
            * clipPerPixel

        let startColor =
            FreeEffectRenderSupport.mixedColor(
                current.color,
                whiteMix: 0.18,
                alpha:
                    current.alpha * 0.78
            )

        let middleColor =
            FreeEffectRenderSupport.mixedColor(
                current.color,
                whiteMix: 0.42,
                alpha:
                    current.alpha * 0.48
            )

        let endColor =
            FreeEffectRenderSupport.mixedColor(
                current.color,
                whiteMix: 0.58,
                alpha: 0
            )

        appendLine(
            x0: current.x,
            y0: current.y,
            color0: startColor,
            x1: middleX,
            y1: middleY,
            color1: middleColor,
            to: branchFloats
        )

        appendLine(
            x0: middleX,
            y0: middleY,
            color0: middleColor,
            x1: endX,
            y1: endY,
            color1: endColor,
            to: branchFloats
        )

        var vertexCount = 4

        let shouldFork =
            lengthPixels >= Self.minimumForkLengthPixels
            && FreeEffectRenderSupport.hash(
                seed + 21.6
            ) < Self.secondaryForkProbability

        if shouldFork {
            let forkSide: Float = -side
            let forkLength =
                lengthPixels
                * Self.secondaryForkLengthRatio

            let forkX =
                middleX
                + (
                    nx * forkSide
                    - tx * 0.12
                )
                * forkLength
                * clipPerPixel

            let forkY =
                middleY
                + (
                    ny * forkSide
                    - ty * 0.12
                )
                * forkLength
                * clipPerPixel

            appendLine(
                x0: middleX,
                y0: middleY,
                color0: middleColor,
                x1: forkX,
                y1: forkY,
                color1: endColor,
                to: branchFloats
            )

            vertexCount += 2
        }

        return vertexCount
    }

    private func appendLine(
        x0: Float,
        y0: Float,
        color0: (Float, Float, Float, Float),
        x1: Float,
        y1: Float,
        color1: (Float, Float, Float, Float),
        to buffer: MetalFloatBuffer
    ) {
        FreeEffectRenderSupport.appendLineVertex(
            to: buffer,
            x: x0,
            y: y0,
            color: color0
        )

        FreeEffectRenderSupport.appendLineVertex(
            to: buffer,
            x: x1,
            y: y1,
            color: color1
        )
    }

    private static func lineAttributes(
        positionLocation: MetalLocation,
        colorLocation: MetalLocation
    ) -> [MetalVertexAttribute] {
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

    private static let floatsPerVertex = 6
    private static let bytesPerVertex = 24

    private static let maximumNodes = 256
    private static let nodeStride = 2

    private static let timeWrapSeconds: Float = 120
    private static let jitterPixels: Float = 1.45
    private static let flickerStepsPerSecond: Float = 12
    private static let branchStepsPerSecond: Float = 8

    private static let glowWidthPixels: Float = 2.20
    private static let bodyWidthPixels: Float = 1.20
    private static let coreWidthPixels: Float = 0.62

    private static let branchProbability: Float = 0.105
    private static let maximumBranchProbability: Float = 0.42
    private static let minimumBranchAlpha: Float = 0.16

    private static let branchLengthPixels: Float = 12
    private static let branchMiddleRatio: Float = 0.56
    private static let branchWidthPixels: Float = 0.52

    private static let secondaryForkProbability: Float = 0.28
    private static let secondaryForkLengthRatio: Float = 0.42
    private static let minimumForkLengthPixels: Float = 9

    private static let maximumBranches = 7
    private static let maximumVerticesPerBranch = 6
}
