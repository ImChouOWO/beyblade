import Foundation
import Metal
import simd

/// 通用雙層 ribbon（閃電/火炎/星塵）— 對應 Android GenericGLEffect：
/// 寬光暈層 + 窄亮芯層；colorOverride 優先，否則抓陀螺偵測色。
final class GenericEffect: EffectRenderer {

    /// 由渲染器在 draw 前設定（取寬度係數與 colorOverride）
    var currentType: EffectType = .lightning

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder,
              ctx: RenderContext) {
        for (_, pts) in trackData {
            guard pts.count >= 2 else { continue }
            let color = currentType.colorOverride ?? pts.last!.0.color
            drawRibbon(pts, halfWidth: 0.070 * currentType.glowWidthMult,
                       alphaScale: 0.45, coreBoost: 0.0,
                       color: color, encoder: encoder, ctx: ctx)
            drawRibbon(pts, halfWidth: 0.022 * currentType.coreWidthMult,
                       alphaScale: 0.92, coreBoost: 0.55,
                       color: color, encoder: encoder, ctx: ctx)
        }
    }

    private func drawRibbon(_ pts: [(TrailPoint, Float)],
                            halfWidth: Float, alphaScale: Float, coreBoost: Float,
                            color: SIMD3<Float>,
                            encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let n = pts.count
        var verts: [TrailVertex] = []
        verts.reserveCapacity(n * 2)

        // 預先轉 NDC
        var p = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n { p[i] = ctx.toNDC(pts[i].0.center) }

        for i in 0..<n {
            let normal: SIMD2<Float>
            if i == 0 { normal = GeomHelper.segNormal(p[0], p[1]) }
            else if i == n - 1 { normal = GeomHelper.segNormal(p[n-2], p[n-1]) }
            else { normal = GeomHelper.avgNormal(p[i-1], p[i], p[i+1]) }

            let alpha = pts[i].1
            let hw = halfWidth * alpha * (1 - alpha * 0.7)
            func ch(_ base: Float) -> Float { min(1, base + (1 - base) * coreBoost * alpha) }
            let r = ch(color.x), g = ch(color.y), b = ch(color.z)
            let a = alpha * alphaScale

            let lo = p[i] - normal * hw
            let hi = p[i] + normal * hw
            verts.append(TrailVertex(x: lo.x, y: lo.y, r: r, g: g, b: b, a: a,
                                     centerDist: -1, trailDist: 0))
            verts.append(TrailVertex(x: hi.x, y: hi.y, r: r, g: g, b: b, a: a,
                                     centerDist: 1, trailDist: 0))
        }
        encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.generic,
                               uniforms: ctx.uniforms, device: ctx.device)
    }
}
