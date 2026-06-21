import Foundation
import Metal
import simd

/// 滔天浪潮 — 對應 Android WaveGLEffect（最終版）：
///   流體雜訊水體（陀螺色）+ 側噴水珠/上浮泡泡 + 快速移動時的漣漪環。
final class WaveEffect: EffectRenderer {

    private struct Particle {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var vel = SIMD2<Float>(0, 0)       // NDC/frame
        var alpha: Float = 0
        var sizePx: Float = 0
        var isBlue = false
    }
    private var particles = [Particle](repeating: Particle(), count: 50)

    private struct Ripple {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var radiusPx: Float = 0
        var alpha: Float = 0
    }
    private var ripples = [Ripple](repeating: Ripple(), count: 6)

    private var lastPos: [Int: SIMD2<Float>] = [:]

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        for (_, pts) in trackData where pts.count >= 2 {
            drawFluidRibbon(pts, encoder: encoder, ctx: ctx)
        }
        spawn(trackData, ctx: ctx)
        updateParticles(dt: ctx.dtScale)
        drawParticles(encoder: encoder, ctx: ctx)
        updateRipples(dt: ctx.dtScale)
        drawRipples(encoder: encoder, ctx: ctx)
    }

    // ── 流體水體（waveFluid shader 需要 trailDist 弧長） ───────────────────

    private func drawFluidRibbon(_ pts: [(TrailPoint, Float)],
                                 encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let n = pts.count
        var p = [SIMD2<Float>](repeating: .zero, count: n)
        var cum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            p[i] = ctx.toNDC(pts[i].0.center)
            if i > 0 { cum[i] = cum[i-1] + simd_distance(p[i], p[i-1]) }
        }
        let total = cum[n-1]
        let c = pts.last!.0.color

        var verts: [TrailVertex] = []
        verts.reserveCapacity(n * 2)
        for i in 0..<n {
            let normal: SIMD2<Float> =
                i == 0 ? GeomHelper.segNormal(p[0], p[1]) :
                i == n - 1 ? GeomHelper.segNormal(p[n-2], p[n-1]) :
                GeomHelper.avgNormal(p[i-1], p[i], p[i+1])
            let life = pts[i].1
            let hw: Float = 0.031 * (0.35 + 0.65 * life)
            let trail = total - cum[i]
            let lo = p[i] - normal * hw, hi = p[i] + normal * hw
            verts.append(TrailVertex(x: lo.x, y: lo.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: -1, trailDist: trail))
            verts.append(TrailVertex(x: hi.x, y: hi.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: 1, trailDist: trail))
        }
        encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.waveFluid,
                               uniforms: ctx.uniforms, device: ctx.device)
    }

    // ── 噴濺/泡泡/漣漪（粒子邏輯 1:1 移植，速度單位 NDC/frame@30fps） ──────

    private func spawn(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        for (trackId, pts) in trackData where pts.count >= 2 {
            let head = ctx.toNDC(pts[pts.count-1].0.center)
            let prev = ctx.toNDC(pts[pts.count-2].0.center)
            let d = head - prev
            let moveLen = max(simd_length(d), 1e-5)
            let perp = SIMD2(-d.y, d.x) / moveLen

            let dist: Float
            if let last = lastPos[trackId] { dist = simd_distance(head, last) }
            else { dist = .greatestFiniteMagnitude }

            if dist > 0.008 && Float.random(in: 0...1) > 0.3 {
                lastPos[trackId] = head
                let moveNorm = moveLen / ctx.dtScale
                if moveNorm > 0.015 && Bool.random() { spawnRipple(at: head, ctx: ctx) }

                var spawned = 0
                for i in particles.indices where !particles[i].active {
                    let side: Float = spawned % 2 == 0 ? 1 : -1
                    let strength = min(max(moveNorm * 1.5, 0.02), 0.045)
                    particles[i].active = true
                    particles[i].pos = head
                    particles[i].vel = perp * side * strength
                        + SIMD2(Float.random(in: -0.009...0.009),
                                Float.random(in: -0.009...0.009) - 0.012)
                    particles[i].sizePx = Float.random(in: 6...14)
                    particles[i].alpha = 1
                    particles[i].isBlue = Float.random(in: 0...1) > 0.3
                    spawned += 1
                    if spawned >= 3 { break }
                }
                // 軌跡身上的微泡泡
                if pts.count > 4 && Float.random(in: 0...1) > 0.6 {
                    let b = ctx.toNDC(pts[pts.count / 3].0.center)
                    for i in particles.indices where !particles[i].active {
                        particles[i].active = true
                        particles[i].pos = b + SIMD2(Float.random(in: -0.01...0.01),
                                                     Float.random(in: -0.01...0.01))
                        particles[i].vel = SIMD2(Float.random(in: -0.003...0.003),
                                                 -Float.random(in: 0.005...0.017))
                        particles[i].sizePx = Float.random(in: 2...6)
                        particles[i].alpha = 0.6
                        particles[i].isBlue = true
                        break
                    }
                }
            }
        }
    }

    private func updateParticles(dt: Float) {
        for i in particles.indices where particles[i].active {
            particles[i].pos += particles[i].vel * dt
            particles[i].vel.y += 0.001 * dt
            particles[i].alpha -= 0.06 * dt
            if particles[i].alpha <= 0 { particles[i].active = false }
        }
    }

    private func drawParticles(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        var verts: [PointVertex] = []
        for p in particles where p.active {
            let rgb: SIMD3<Float> = p.isBlue ? SIMD3(0.749, 0.906, 1.0) : SIMD3(1, 1, 1)
            verts.append(PointVertex(x: p.pos.x, y: p.pos.y,
                                     r: rgb.x, g: rgb.y, b: rgb.z,
                                     a: max(0, min(1, p.alpha)), size: p.sizePx))
        }
        encoder.drawPoints(verts, pipeline: ctx.pipelines.pointSolid, device: ctx.device)
    }

    private func spawnRipple(at pos: SIMD2<Float>, ctx: RenderContext) {
        for i in ripples.indices where !ripples[i].active {
            ripples[i] = Ripple(active: true, pos: pos, radiusPx: 0, alpha: 0.85)
            return
        }
    }

    private func updateRipples(dt: Float) {
        for i in ripples.indices where ripples[i].active {
            ripples[i].radiusPx += 5 * dt
            ripples[i].alpha -= 0.04 * dt
            if ripples[i].alpha <= 0 { ripples[i].active = false }
        }
    }

    private func drawRipples(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let segments = 24
        let ringWidthPx: Float = 5

        for r in ripples where r.active {
            let iPx = max(0, r.radiusPx - ringWidthPx)
            let oPx = r.radiusPx + ringWidthPx
            var verts: [TrailVertex] = []
            for i in 0...segments {
                let ang = Float(i) / Float(segments) * 2 * .pi
                let ca = cos(ang), sa = sin(ang)
                let inner = SIMD2(r.pos.x + iPx / (vw/2) * ca, r.pos.y + iPx / (vh/2) * sa)
                let outer = SIMD2(r.pos.x + oPx / (vw/2) * ca, r.pos.y + oPx / (vh/2) * sa)
                let a = max(0, min(1, r.alpha))
                verts.append(TrailVertex(x: inner.x, y: inner.y, r: 0.71, g: 0.90, b: 1,
                                         a: a, centerDist: -1, trailDist: 0))
                verts.append(TrailVertex(x: outer.x, y: outer.y, r: 0.71, g: 0.90, b: 1,
                                         a: a, centerDist: 1, trailDist: 0))
            }
            encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.softBand,
                                   uniforms: ctx.uniforms, device: ctx.device)
        }
    }
}
