import Foundation
import Metal

/// 所有 render pipeline 一次建好（對應 Android 各 GL program）。
/// 全部使用標準 alpha blending（SRC_ALPHA / ONE_MINUS_SRC_ALPHA，同 Android）。
final class PipelineLibrary {
    let device: MTLDevice
    let pixelFormat: MTLPixelFormat

    // 相機 / blit
    let cameraQuad: MTLRenderPipelineState     // 含 cropScale
    let blit: MTLRenderPipelineState           // uv 直通（錄影旋轉 quad 用）

    // trail 系列（統一 TrailVertex）
    let generic: MTLRenderPipelineState
    let softBand: MTLRenderPipelineState
    let waveFluid: MTLRenderPipelineState
    let shield: MTLRenderPipelineState
    let blade: MTLRenderPipelineState
    let ice: MTLRenderPipelineState
    let fire: MTLRenderPipelineState
    let fireball: MTLRenderPipelineState
    let iceShard: MTLRenderPipelineState

    // 點粒子
    let pointSolid: MTLRenderPipelineState
    let pointHollow: MTLRenderPipelineState
    let pointGauss: MTLRenderPipelineState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        guard let lib = device.makeDefaultLibrary() else {
            throw NSError(domain: "BeyTrail", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Metal library 載入失敗"])
        }

        func make(_ vertex: String, _ fragment: String, blend: Bool = true) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: vertex)
            desc.fragmentFunction = lib.makeFunction(name: fragment)
            let att = desc.colorAttachments[0]!
            att.pixelFormat = pixelFormat
            if blend {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .sourceAlpha
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        cameraQuad  = try make("quadVertex",  "textureFragment", blend: false)
        blit        = try make("blitVertex",  "textureFragment", blend: false)
        generic     = try make("trailVertex", "genericTrailFragment")
        softBand    = try make("trailVertex", "softBandFragment")
        waveFluid   = try make("trailVertex", "waveFluidFragment")
        shield      = try make("trailVertex", "shieldFragment")
        blade       = try make("trailVertex", "bladeFragment")
        ice         = try make("trailVertex", "iceFragment")
        fire        = try make("trailVertex", "fireFragment")
        fireball    = try make("trailVertex", "fireballFragment")
        iceShard    = try make("trailVertex", "iceShardFragment")
        pointSolid  = try make("pointVertex", "pointSolidFragment")
        pointHollow = try make("pointVertex", "pointHollowFragment")
        pointGauss  = try make("pointVertex", "pointGaussFragment")
    }
}

// ── 繪製輔助：以 setVertexBytes 提交小型動態幾何（≤4KB 自動走 setVertexBytes，
//    超過則建臨時 buffer；特效幾何皆為每幀重建的小資料，符合 Metal 最佳實務） ──
extension MTLRenderCommandEncoder {
    func drawTrailStrip(_ verts: [TrailVertex], pipeline: MTLRenderPipelineState,
                        uniforms: FrameUniforms, device: MTLDevice) {
        guard verts.count >= 3 else { return }
        setRenderPipelineState(pipeline)
        bindVerts(verts, device: device)
        var u = uniforms
        setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: verts.count)
    }

    func drawTrailTriangles(_ verts: [TrailVertex], pipeline: MTLRenderPipelineState,
                            uniforms: FrameUniforms, device: MTLDevice) {
        guard verts.count >= 3 else { return }
        setRenderPipelineState(pipeline)
        bindVerts(verts, device: device)
        var u = uniforms
        setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    func drawPoints(_ verts: [PointVertex], pipeline: MTLRenderPipelineState,
                    device: MTLDevice) {
        guard !verts.isEmpty else { return }
        setRenderPipelineState(pipeline)
        let len = verts.count * MemoryLayout<PointVertex>.stride
        if len <= 4096 {
            setVertexBytes(verts, length: len, index: 0)
        } else if let buf = device.makeBuffer(bytes: verts, length: len) {
            setVertexBuffer(buf, offset: 0, index: 0)
        }
        drawPrimitives(type: .point, vertexStart: 0, vertexCount: verts.count)
    }

    private func bindVerts(_ verts: [TrailVertex], device: MTLDevice) {
        let len = verts.count * MemoryLayout<TrailVertex>.stride
        if len <= 4096 {
            setVertexBytes(verts, length: len, index: 0)
        } else if let buf = device.makeBuffer(bytes: verts, length: len) {
            setVertexBuffer(buf, offset: 0, index: 0)
        }
    }
}
