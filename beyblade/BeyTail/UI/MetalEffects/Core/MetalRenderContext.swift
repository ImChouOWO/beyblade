import Foundation
import CoreGraphics
import Metal
import MetalKit

struct MetalVertexAttribute {
    let location: MetalLocation
    let size: Int32
    let offsetBytes: Int
}

private struct MetalDrawUniforms {
    // strideFloats, positionOffset, colorOffset, uvOffset
    var layout0: SIMD4<UInt32>
    // centerDistanceOffset, trailDistanceOffset, sizeOffset, extraOffset
    var layout1: SIMD4<Int32>
    // time, strandAlpha, lineWidth, unused
    var scalar0: SIMD4<Float>
    // tint.rgb, unused
    var tint: SIMD4<Float>
    // shaderKind, viewportWidth, viewportHeight, unused
    var meta: SIMD4<UInt32>
}

final class MetalRenderContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var viewWidth: Int = 1
    var viewHeight: Int = 1
    var quadScaleX: Float = 1
    var quadScaleY: Float = 1
    var dtScale: Float = 1

    private(set) var renderProfile = TrailRenderProfile.fallback

    var particleSizeMultiplier: Float {
        max(renderProfile.particleSizeMultiplier, 0)
    }

    var particleFrequencyMultiplier: Float {
        max(renderProfile.particleFrequencyMultiplier, 0)
    }

    let ribbonFloats = MetalFloatBuffer(capacity: 65_536)

    var currentShader: MetalShaderKind = .flatColor
    var blendMode: MetalBlendMode = .alpha
    var timeUniform: Float = 0
    var strandAlphaUniform: Float = 1
    var tintUniform = SIMD3<Float>(1, 1, 1)
    var lineWidth: Float = 1

    private let pipelineLibrary: MetalPipelineLibrary
    private let frameAllocator: MetalFrameAllocator
    private var encoder: MTLRenderCommandEncoder?

    var minDimension: Float {
        Float(min(viewWidth, viewHeight))
    }


    func applyRenderProfile(_ profile: TrailRenderProfile) {
        renderProfile = profile
    }

    func scaledParticleSize(_ value: Float) -> Float {
        value * particleSizeMultiplier
    }

    func scaledParticleRate(_ value: Float) -> Float {
        value * particleFrequencyMultiplier
    }

    func scaledParticleInterval(_ baseInterval: Float) -> Float {
        guard particleFrequencyMultiplier > 0 else {
            return .greatestFiniteMagnitude
        }

        return max(
            baseInterval / particleFrequencyMultiplier,
            0.001
        )
    }

    func particleEmissionCount(baseCount: Float) -> Int {
        let expected = max(baseCount, 0) * particleFrequencyMultiplier
        let whole = Int(expected.rounded(.down))
        let fraction = expected - Float(whole)

        if fraction > 0,
           Float.random(in: 0..<1) < fraction {
            return whole + 1
        }

        return whole
    }

    func shouldSpawnParticle(baseProbability: Float) -> Bool {
        let probability = max(min(baseProbability, 1), 0)
        let frequency = particleFrequencyMultiplier

        guard probability > 0,
              frequency > 0 else {
            return false
        }

        let adjusted = min(probability * frequency, 1)
        return Float.random(in: 0..<1) < adjusted
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Unable to create Metal command queue")
        }
        self.commandQueue = commandQueue
        self.pipelineLibrary = MetalPipelineLibrary(
            device: device,
            pixelFormat: pixelFormat
        )
        self.frameAllocator = MetalFrameAllocator(device: device)
    }

    func update(
        drawableSize: CGSize,
        deltaTime: CFTimeInterval
    ) {
        viewWidth = max(Int(drawableSize.width.rounded()), 1)
        viewHeight = max(Int(drawableSize.height.rounded()), 1)
        dtScale = Float(max(min(deltaTime * 30.0, 3.0), 0.1))
    }

    func beginFrame(
        commandBuffer: MTLCommandBuffer,
        encoder: MTLRenderCommandEncoder
    ) {
        frameAllocator.beginFrame(commandBuffer: commandBuffer)
        self.encoder = encoder
        currentShader = .flatColor
        blendMode = .alpha
        timeUniform = 0
        strandAlphaUniform = 1
        tintUniform = SIMD3<Float>(1, 1, 1)
        lineWidth = 1
        MetalRuntime.current = self
    }

    func endFrame() {
        encoder = nil
        MetalRuntime.current = nil
    }

    func drawInterleaved(
        buffer: MetalFloatBuffer,
        strideBytes: Int,
        attributes: [MetalVertexAttribute],
        primitiveCode: MetalPrimitiveCode,
        vertexCount: Int
    ) {
        guard vertexCount > 0,
              strideBytes > 0,
              let encoder else {
            return
        }

        var sourceValues: [Float]
        let sourceCount: Int
        let resolvedPrimitive: MTLPrimitiveType

        if primitiveCode == MGL_LINES && lineWidth > 1.01 {
            let expanded = expandLines(
                buffer: buffer,
                strideBytes: strideBytes,
                attributes: attributes,
                vertexCount: vertexCount,
                lineWidth: lineWidth
            )
            sourceValues = expanded.values
            sourceCount = expanded.vertexCount
            resolvedPrimitive = .triangle
        } else {
            sourceValues = Array(buffer.usedValues())
            sourceCount = vertexCount
            resolvedPrimitive = primitiveType(for: primitiveCode)
        }

        sourceValues = applyParticleSizeMultiplier(
            sourceValues,
            strideBytes: strideBytes,
            attributes: attributes,
            vertexCount: sourceCount
        )

        guard sourceCount > 0,
              let slice = frameAllocator.copyFloats(
                  sourceValues,
                  count: sourceValues.count
              ) else {
            return
        }

        var uniforms = makeUniforms(
            strideBytes: strideBytes,
            attributes: attributes
        )

        let pipeline = pipelineLibrary.pipeline(
            blendMode: blendMode,
            pointShader: currentShader.isPointShader
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(
            slice.buffer,
            offset: slice.offset,
            index: 0
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<MetalDrawUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<MetalDrawUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: resolvedPrimitive,
            vertexStart: 0,
            vertexCount: sourceCount
        )
    }

    private func applyParticleSizeMultiplier(
        _ values: [Float],
        strideBytes: Int,
        attributes: [MetalVertexAttribute],
        vertexCount: Int
    ) -> [Float] {
        let multiplier = particleSizeMultiplier

        guard abs(multiplier - 1) > 0.000_1,
              strideBytes > 0,
              let sizeAttribute = attributes.first(where: {
                  $0.location == MetalAttributeSemantic.size.rawValue
              }) else {
            return values
        }

        let stride = strideBytes / MemoryLayout<Float>.stride
        let offset = sizeAttribute.offsetBytes / MemoryLayout<Float>.stride

        guard stride > 0,
              offset >= 0,
              offset < stride else {
            return values
        }

        var output = values
        let availableVertices = output.count / stride
        let count = min(vertexCount, availableVertices)

        for index in 0..<count {
            output[index * stride + offset] *= multiplier
        }

        return output
    }

    private func primitiveType(
        for code: MetalPrimitiveCode
    ) -> MTLPrimitiveType {
        switch code {
        case MGL_POINTS:
            return .point
        case MGL_LINES:
            return .line
        case MGL_LINE_STRIP:
            return .lineStrip
        case MGL_TRIANGLE_STRIP:
            return .triangleStrip
        default:
            return .triangle
        }
    }

    private func makeUniforms(
        strideBytes: Int,
        attributes: [MetalVertexAttribute]
    ) -> MetalDrawUniforms {
        let missing = UInt32.max
        var position = missing
        var color = missing
        var uv = missing
        var center: Int32 = -1
        var trail: Int32 = -1
        var size: Int32 = -1
        var extra: Int32 = -1

        for attribute in attributes where attribute.location >= 0 {
            let offset = UInt32(attribute.offsetBytes / MemoryLayout<Float>.stride)
            switch MetalAttributeSemantic(rawValue: attribute.location) {
            case .position:
                position = offset
            case .color:
                color = offset
            case .centerDistance:
                center = Int32(offset)
            case .trailDistance:
                trail = Int32(offset)
            case .size:
                size = Int32(offset)
            case .uv:
                uv = offset
            case .extra:
                extra = Int32(offset)
            case .none:
                break
            }
        }

        return MetalDrawUniforms(
            layout0: SIMD4<UInt32>(
                UInt32(strideBytes / MemoryLayout<Float>.stride),
                position,
                color,
                uv
            ),
            layout1: SIMD4<Int32>(center, trail, size, extra),
            scalar0: SIMD4<Float>(
                timeUniform,
                strandAlphaUniform,
                lineWidth,
                0
            ),
            tint: SIMD4<Float>(
                tintUniform.x,
                tintUniform.y,
                tintUniform.z,
                0
            ),
            meta: SIMD4<UInt32>(
                currentShader.rawValue,
                UInt32(viewWidth),
                UInt32(viewHeight),
                0
            )
        )
    }

    private func expandLines(
        buffer: MetalFloatBuffer,
        strideBytes: Int,
        attributes: [MetalVertexAttribute],
        vertexCount: Int,
        lineWidth: Float
    ) -> (values: [Float], vertexCount: Int) {
        let stride = strideBytes / MemoryLayout<Float>.stride
        guard stride > 0,
              vertexCount >= 2,
              let positionAttribute = attributes.first(where: {
                  $0.location == MetalAttributeSemantic.position.rawValue
              }) else {
            return (Array(buffer.usedValues()), vertexCount)
        }

        let positionOffset = positionAttribute.offsetBytes /
            MemoryLayout<Float>.stride
        let source = Array(buffer.usedValues())
        let pairCount = vertexCount / 2
        var output: [Float] = []
        output.reserveCapacity(pairCount * 6 * stride)

        func appendVertex(
            sourceIndex: Int,
            x: Float,
            y: Float
        ) {
            let base = sourceIndex * stride
            var vertex = Array(source[base..<(base + stride)])
            vertex[positionOffset] = x
            vertex[positionOffset + 1] = y
            output.append(contentsOf: vertex)
        }

        let halfWidth = lineWidth * 0.5
        let clipPerPixelX = 2.0 / Float(max(viewWidth, 1))
        let clipPerPixelY = 2.0 / Float(max(viewHeight, 1))

        for pair in 0..<pairCount {
            let i0 = pair * 2
            let i1 = i0 + 1
            let b0 = i0 * stride + positionOffset
            let b1 = i1 * stride + positionOffset
            let x0 = source[b0]
            let y0 = source[b0 + 1]
            let x1 = source[b1]
            let y1 = source[b1 + 1]

            let dxPx = (x1 - x0) / clipPerPixelX
            let dyPx = (y1 - y0) / clipPerPixelY
            let length = max(sqrt(dxPx * dxPx + dyPx * dyPx), 0.000_1)
            let nx = -dyPx / length
            let ny = dxPx / length
            let ox = nx * halfWidth * clipPerPixelX
            let oy = ny * halfWidth * clipPerPixelY

            appendVertex(sourceIndex: i0, x: x0 - ox, y: y0 - oy)
            appendVertex(sourceIndex: i1, x: x1 - ox, y: y1 - oy)
            appendVertex(sourceIndex: i1, x: x1 + ox, y: y1 + oy)

            appendVertex(sourceIndex: i0, x: x0 - ox, y: y0 - oy)
            appendVertex(sourceIndex: i1, x: x1 + ox, y: y1 + oy)
            appendVertex(sourceIndex: i0, x: x0 + ox, y: y0 + oy)
        }

        return (output, pairCount * 6)
    }
}
