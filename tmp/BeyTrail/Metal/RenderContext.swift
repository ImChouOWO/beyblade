import Foundation
import Metal
import simd

/// 統一頂點格式（與 Shaders.metal 的 TrailVertexIn 對應）— 8 floats / 32 bytes
struct TrailVertex {
    var x: Float, y: Float
    var r: Float, g: Float, b: Float, a: Float
    var centerDist: Float
    var trailDist: Float
}

/// 點粒子頂點 — 7 floats / 28 bytes
struct PointVertex {
    var x: Float, y: Float
    var r: Float, g: Float, b: Float, a: Float
    var size: Float
}

struct FrameUniforms {
    var time: Float = 0
    var cropScale: SIMD2<Float> = SIMD2(1, 1)
    var pad: SIMD2<Float> = SIMD2(0, 0)
}

/// 每幀傳給特效的共用資源（對應 Android GLRenderContext）
final class RenderContext {
    let device: MTLDevice
    let pipelines: PipelineLibrary

    /// 渲染目標像素尺寸
    var viewWidth: Int = 0
    var viewHeight: Int = 0
    /// 相機裁切縮放（特效座標映射用，影片處理 = 1）
    var quadScaleX: Float = 1
    var quadScaleY: Float = 1
    /// 30fps 基準的幀時間倍率：30fps = 1.0、60fps = 0.5（特效每幀常數乘此值）
    var dtScale: Float = 1
    /// 給雜訊 shader 的時間（秒）
    var time: Float = 0

    var uniforms: FrameUniforms {
        FrameUniforms(time: time, cropScale: SIMD2(1 / quadScaleX, 1 / quadScaleY))
    }

    init(device: MTLDevice, pipelines: PipelineLibrary) {
        self.device = device
        self.pipelines = pipelines
    }

    var minDim: Float { Float(min(viewWidth, viewHeight)) }

    /// 正規化軌跡座標（0~1，y 向下）→ NDC（含相機裁切縮放，同 Android）
    func toNDC(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((p.x * 2 - 1) * quadScaleX, (1 - p.y * 2) * quadScaleY)
    }
}

/// 特效協定（對應 Android GLEffect）
protocol EffectRenderer: AnyObject {
    /// 每幀繪製。trackData：各 track 的點列（舊→新）+ 存活度。
    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder,
              ctx: RenderContext)
}

// ── 幾何輔助（對應 Android GLHelper） ──────────────────────────────────

enum GeomHelper {
    /// 線段垂直單位法線
    static func segNormal(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>) -> SIMD2<Float> {
        let d = p1 - p0
        let len = max(simd_length(d), 1e-5)
        return SIMD2(-d.y / len, d.x / len)
    }

    /// 內部點平滑法線（前後段切線平均）
    static func avgNormal(_ prev: SIMD2<Float>, _ p: SIMD2<Float>,
                          _ next: SIMD2<Float>) -> SIMD2<Float> {
        let d0 = p - prev, d1 = next - p
        let t = simd_normalize(d0 / max(simd_length(d0), 1e-5)
                             + d1 / max(simd_length(d1), 1e-5))
        return SIMD2(-t.y, t.x)
    }
}
