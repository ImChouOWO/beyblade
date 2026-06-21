import Foundation
import Metal
import simd

/// 狂暴冰裂 — 對應 Android IceShatterGLEffect（最終版）：
///   實心冰縫軌跡（鋸齒顫動邊緣）+ 不規則多邊形碎冰從尾跡噴發（強重力+自旋）。
final class IceShatterEffect: EffectRenderer {

    private struct Shard {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var velPx = SIMD2<Float>(0, 0)
        var angle: Float = 0, spin: Float = 0
        var vertexCount = 3
        var ox = [Float](repeating: 0, count: 5)
        var oy = [Float](repeating: 0, count: 5)
        var alpha: Float = 0, decay: Float = 0.14
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var shards = [Shard](repeating: Shard(), count: 64)
    private var lastPos: [Int: SIMD2<Float>] = [:]

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        for (_, pts) in trackData where pts.count >= 2 {
            drawJaggedRibbon(pts, encoder: encoder, ctx: ctx)
        }
        spawn(trackData, ctx: ctx)
        updateShards(ctx: ctx)
        drawShards(encoder: encoder, ctx: ctx)
    }

    // ── 冰縫軌跡（鋸齒顫動邊緣） ─────────────────────────────────────────

    private func drawJaggedRibbon(_ pts: [(TrailPoint, Float)],
                                  encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let n = pts.count
        var p = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n { p[i] = ctx.toNDC(pts[i].0.center) }
        let c = pts.last!.0.color

        var verts: [TrailVertex] = []
        for i in 0..<n {
            let normal: SIMD2<Float> =
                i == 0 ? GeomHelper.segNormal(p[0], p[1]) :
                i == n - 1 ? GeomHelper.segNormal(p[n-2], p[n-1]) :
                GeomHelper.avgNormal(p[i-1], p[i], p[i+1])
            let life = pts[i].1
            let hw: Float = 0.028 * (0.55 + 0.45 * life)
            // 鋸齒顫動：兩側寬度每幀獨立隨機抖（越靠尾巴越強）
            let jag = (1 - life) * 0.9
            let hwL = hw * (1 + Float.random(in: -0.5...0.5) * jag)
            let hwR = hw * (1 + Float.random(in: -0.5...0.5) * jag)
            let lo = p[i] - normal * hwL, hi = p[i] + normal * hwR
            verts.append(TrailVertex(x: lo.x, y: lo.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: -1, trailDist: 0))
            verts.append(TrailVertex(x: hi.x, y: hi.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: 1, trailDist: 0))
        }
        encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.ice,
                               uniforms: ctx.uniforms, device: ctx.device)
    }

    // ── 碎冰 ─────────────────────────────────────────────────────────────

    private func spawn(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let minDim = ctx.minDim

        for (trackId, pts) in trackData where pts.count >= 2 {
            let head = ctx.toNDC(pts[pts.count-1].0.center)
            let prev = ctx.toNDC(pts[pts.count-2].0.center)
            let moveLen = simd_distance(head, prev)

            let dist: Float = lastPos[trackId].map { simd_distance(head, $0) }
                ?? .greatestFiniteMagnitude
            guard dist > 0.006 else { continue }
            lastPos[trackId] = head
            let moveNorm = moveLen / ctx.dtScale

            if moveNorm > 0.007 {
                let chance: Float = moveNorm > 0.016 ? 1.0 : 0.75
                if Float.random(in: 0...1) < chance {
                    spawnShardsFromTrail(pts, moveNorm: moveNorm, minDim: minDim,
                                         color: pts.last!.0.color, ctx: ctx,
                                         vw: vw, vh: vh)
                }
            }
        }
    }

    /// 從尾跡隨機點朝垂直方向炸出 6 顆不規則碎冰（強重力 + 上彈 + 自旋）
    private func spawnShardsFromTrail(_ pts: [(TrailPoint, Float)], moveNorm: Float,
                                      minDim: Float, color: SIMD3<Float>,
                                      ctx: RenderContext, vw: Float, vh: Float) {
        let n = pts.count
        let idx = min(Int(Float.random(in: 0..<1) * Float(n - 1)), n - 2)
        let e0 = ctx.toNDC(pts[idx].0.center)
        let e1 = ctx.toNDC(pts[idx + 1].0.center)
        let segAngle = atan2((e1.y - e0.y) * vh, (e1.x - e0.x) * vw)
        let speedPx = moveNorm * minDim * 0.5

        var spawned = 0
        for i in shards.indices where !shards[i].active {
            let side: Float = Bool.random() ? 1 : -1
            let pAngle = segAngle + side * .pi / 2 + Float.random(in: -0.4...0.4)
            let expSpeed = Float.random(in: 0...6) + speedPx * 0.4
            shards[i].active = true
            shards[i].pos = e0
            shards[i].velPx = SIMD2(cos(pAngle), sin(pAngle)) * expSpeed
                + SIMD2(0, 1.2)   // 微微上彈（NDC y 向上）
            shards[i].angle = Float.random(in: 0...(2 * .pi))
            shards[i].spin = Float.random(in: -0.6...0.6)
            shards[i].alpha = 1
            shards[i].decay = Float.random(in: 0.12...0.17)

            // 兩極化尺寸：60% 大塊
            let isBig = Float.random(in: 0...1) > 0.4
            let basePx = isBig ? minDim * Float.random(in: 0.013...0.021)
                               : minDim * Float.random(in: 0.005...0.008)
            shards[i].vertexCount = Int.random(in: 3...5)
            for k in 0..<shards[i].vertexCount {
                let a = 2 * .pi * Float(k) / Float(shards[i].vertexCount)
                let r = basePx * Float.random(in: 0.3...1.2)
                shards[i].ox[k] = cos(a) * r
                shards[i].oy[k] = sin(a) * r
            }
            shards[i].color = Float.random(in: 0...1) > 0.3
                ? SIMD3(0.73, 0.90, 1.0) * 0.7 + color * 0.3
                : SIMD3(1, 1, 1)
            spawned += 1
            if spawned >= 6 { return }
        }
    }

    private func updateShards(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        for i in shards.indices where shards[i].active {
            shards[i].pos += SIMD2(shards[i].velPx.x * dt / (vw/2),
                                   shards[i].velPx.y * dt / (vh/2))
            shards[i].velPx.y -= 0.65 * dt      // 強重力
            shards[i].angle += shards[i].spin * dt
            shards[i].alpha -= shards[i].decay * dt
            if shards[i].alpha <= 0 { shards[i].active = false }
        }
    }

    private func drawShards(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        var verts: [TrailVertex] = []
        for s in shards where s.active {
            let ca = cos(s.angle), sa = sin(s.angle)
            let a = max(0, min(1, s.alpha))
            func vert(_ k: Int) -> SIMD2<Float> {
                let rx = s.ox[k] * ca - s.oy[k] * sa
                let ry = s.ox[k] * sa + s.oy[k] * ca
                return SIMD2(s.pos.x + rx / (vw/2), s.pos.y + ry / (vh/2))
            }
            let v0 = vert(0)
            for k in 1..<(s.vertexCount - 1) {
                let v1 = vert(k), v2 = vert(k + 1)
                for p in [v0, v1, v2] {
                    verts.append(TrailVertex(x: p.x, y: p.y,
                                             r: s.color.x, g: s.color.y, b: s.color.z,
                                             a: a, centerDist: 0.25, trailDist: 0))
                }
            }
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.iceShard,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }
}
