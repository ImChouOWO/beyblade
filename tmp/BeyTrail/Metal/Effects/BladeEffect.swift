import Foundation
import Metal
import simd

/// 爆刃亂舞 — 對應 Android BladeGLEffect（最終版）：
///   雙股螺旋交叉刀刃（飽和色+相近色堆疊、前端白刃）+ 金屬火花（銀白/淡金）
///   + 十字反光閃點 + 破空裂痕 + 飛行劍氣月牙。
final class BladeEffect: EffectRenderer {

    private struct Spark {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var velPx = SIMD2<Float>(0, 0)
        var alpha: Float = 0
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var sparks = [Spark](repeating: Spark(), count: 28)

    private struct Crack {
        var active = false
        var p1 = SIMD2<Float>(0, 0), p2 = SIMD2<Float>(0, 0)
        var alpha: Float = 0
    }
    private var cracks = [Crack](repeating: Crack(), count: 4)

    private struct Glint {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var angle: Float = 0, sizePx: Float = 0, progress: Float = 0
    }
    private var glints = [Glint](repeating: Glint(), count: 10)

    private struct Wave {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var angle: Float = 0
        var velPx = SIMD2<Float>(0, 0)
        var radiusPx: Float = 0, alpha: Float = 0
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var waves = [Wave](repeating: Wave(), count: 4)

    private var lastPos: [Int: SIMD2<Float>] = [:]

    private let helixTurns: Float = 2.2
    private let helixAmp: Float = 0.016
    private let strandHalfWidth: Float = 0.012

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        spawn(trackData, ctx: ctx)
        for (_, pts) in trackData where pts.count >= 3 {
            drawHelixBlade(pts, encoder: encoder, ctx: ctx)
        }
        updateCracks(dt: ctx.dtScale)
        drawCracks(encoder: encoder, ctx: ctx)
        updateSparks(ctx: ctx)
        drawSparks(encoder: encoder, ctx: ctx)
        updateWaves(ctx: ctx)
        drawWaves(encoder: encoder, ctx: ctx)
        updateGlints(dt: ctx.dtScale)
        drawGlints(encoder: encoder, ctx: ctx)
    }

    // ── 雙股螺旋刀刃 ─────────────────────────────────────────────────────

    private func drawHelixBlade(_ pts: [(TrailPoint, Float)],
                                encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let n = pts.count
        var raw = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n { raw[i] = ctx.toNDC(pts[i].0.center) }

        // ×3 重採樣讓螺旋平滑
        let m = min(n * 3, 64)
        var rp = [SIMD2<Float>](repeating: .zero, count: m)
        var ra = [Float](repeating: 0, count: m)
        for j in 0..<m {
            let f = Float(j) / Float(m - 1) * Float(n - 1)
            let i0 = min(Int(f), n - 2)
            let fr = f - Float(i0)
            rp[j] = raw[i0] + (raw[i0+1] - raw[i0]) * fr
            ra[j] = pts[i0].1 + (pts[i0+1].1 - pts[i0].1) * fr
        }

        let base = ColorUtil.saturate(pts.last!.0.color)
        let twin = ColorUtil.hueShift(base, degrees: 38)

        for strand in 0..<2 {
            let color = strand == 0 ? base : twin
            let phase = Float(strand) * .pi
            var verts: [TrailVertex] = []
            for j in 0..<m {
                let normal: SIMD2<Float> =
                    j == 0 ? GeomHelper.segNormal(rp[0], rp[1]) :
                    j == m - 1 ? GeomHelper.segNormal(rp[m-2], rp[m-1]) :
                    GeomHelper.avgNormal(rp[j-1], rp[j], rp[j+1])
                let u = Float(j) / Float(m - 1)
                let env = sin(.pi * u)
                let off = sin(u * helixTurns * 2 * .pi + phase) * helixAmp * env
                let cpos = rp[j] + normal * off
                let hw = strandHalfWidth * env

                let aT: Float = u < 0.3 ? u / 0.3 * 0.5
                    : u < 0.8 ? 0.5 + (u - 0.3) / 0.5 * 0.45
                    : 0.95 + (u - 0.8) / 0.2 * 0.05
                let a = aT * sqrt(ra[j])
                let wMix = max(0, min(1, (u - 0.75) / 0.25))
                let col = color + (SIMD3<Float>(1, 1, 1) - color) * wMix

                let lo = cpos - normal * hw, hi = cpos + normal * hw
                verts.append(TrailVertex(x: lo.x, y: lo.y, r: col.x, g: col.y, b: col.z,
                                         a: a, centerDist: -1, trailDist: 0))
                verts.append(TrailVertex(x: hi.x, y: hi.y, r: col.x, g: col.y, b: col.z,
                                         a: a, centerDist: 1, trailDist: 0))
            }
            encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.blade,
                                   uniforms: ctx.uniforms, device: ctx.device)
        }
    }

    // ── Spawning ─────────────────────────────────────────────────────────

    private func spawn(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let minDim = ctx.minDim

        for (trackId, pts) in trackData where pts.count >= 2 {
            let head = ctx.toNDC(pts[pts.count-1].0.center)
            let prev = ctx.toNDC(pts[pts.count-2].0.center)
            let d = head - prev
            let moveLen = simd_length(d)
            let color = pts.last!.0.color

            let dist: Float = lastPos[trackId].map { simd_distance(head, $0) }
                ?? .greatestFiniteMagnitude
            guard dist > 0.005 else { continue }
            lastPos[trackId] = head
            let moveNorm = moveLen / ctx.dtScale

            // 刀身碎屑 + 閃光
            if moveNorm > 0.009 && pts.count >= 3 {
                let idx = 1 + Int(Float.random(in: 0..<1) * Float(pts.count - 2))
                let bpos = ctx.toNDC(pts[min(idx, pts.count - 2)].0.center)
                let bn = ctx.toNDC(pts[min(idx + 1, pts.count - 1)].0.center)
                let segDir = SIMD2((bn.x - bpos.x) * vw, (bn.y - bpos.y) * vh)
                let segLen = max(simd_length(segDir), 1e-3)
                let perp = SIMD2(-segDir.y, segDir.x) / segLen
                var count = Bool.random() ? 2 : 1
                while count > 0 {
                    let side: Float = Bool.random() ? 1 : -1
                    let burst = Float.random(in: 3...8)
                    spawnSpark(at: bpos,
                               velPx: perp * side * burst
                                 - segDir / segLen * Float.random(in: 0...2.5)
                                 + SIMD2(Float.random(in: -1.5...1.5),
                                         Float.random(in: -1.5...1.5)),
                               color: color)
                    count -= 1
                }
                if Float.random(in: 0...1) > 0.45 {
                    spawnGlint(at: bpos, minDim: minDim)
                }
            }
            // 高速：火花 + 裂痕 + 劍氣
            if moveNorm > 0.013 {
                let velPx = SIMD2(d.x * vw * 0.5, d.y * vh * 0.5) / ctx.dtScale
                if Float.random(in: 0...1) > 0.3 {
                    spawnSpark(at: head,
                               velPx: velPx * 0.4 + SIMD2(Float.random(in: -5...5),
                                                          Float.random(in: -5...5)),
                               color: color)
                }
                if Float.random(in: 0...1) > 0.4 {
                    spawnCrack(from: prev, to: head, minDim: minDim,
                               vw: vw, vh: vh)
                }
                if Float.random(in: 0...1) > 0.55 {
                    let moveAngle = atan2(d.y * vh, d.x * vw)
                    spawnWave(at: head, angle: moveAngle, moveNorm: moveNorm,
                              minDim: minDim, color: color)
                }
            }
        }
    }

    private func spawnSpark(at pos: SIMD2<Float>, velPx: SIMD2<Float>, color: SIMD3<Float>) {
        for i in sparks.indices where !sparks[i].active {
            sparks[i].active = true
            sparks[i].pos = pos
            sparks[i].velPx = velPx
            sparks[i].alpha = 1
            sparks[i].color = Float.random(in: 0...1) > 0.4
                ? SIMD3(0.88, 0.95, 1.0)        // 銀白
                : SIMD3(1.0, 0.94, 0.54)        // 淡金
            return
        }
    }

    private func spawnCrack(from p1: SIMD2<Float>, to p2: SIMD2<Float>,
                            minDim: Float, vw: Float, vh: Float) {
        for i in cracks.indices where !cracks[i].active {
            let dPx = SIMD2((p2.x - p1.x) * vw, (p2.y - p1.y) * vh)
            let len = max(simd_length(dPx), 1e-3)
            let offPx = Float.random(in: -0.5...0.5) * minDim * 0.030
            let off = SIMD2(-dPx.y / len * offPx / (vw/2), dPx.x / len * offPx / (vh/2))
            let ext = (p2 - p1) * 0.8
            cracks[i] = Crack(active: true,
                              p1: p1 + off - ext, p2: p2 + off + ext, alpha: 0.9)
            return
        }
    }

    private func spawnGlint(at pos: SIMD2<Float>, minDim: Float) {
        for i in glints.indices where !glints[i].active {
            glints[i] = Glint(active: true,
                              pos: pos + SIMD2(Float.random(in: -0.008...0.008),
                                               Float.random(in: -0.008...0.008)),
                              angle: Float.random(in: 0...(.pi)),
                              sizePx: minDim * Float.random(in: 0.008...0.016),
                              progress: 0)
            return
        }
    }

    private func spawnWave(at pos: SIMD2<Float>, angle: Float, moveNorm: Float,
                           minDim: Float, color: SIMD3<Float>) {
        for i in waves.indices where !waves[i].active {
            let speedPx = Float.random(in: 10...16) + moveNorm * minDim * 0.15
            let a = angle + Float.random(in: -0.2...0.2)
            let sat = ColorUtil.saturate(color)
            waves[i] = Wave(active: true, pos: pos, angle: a,
                            velPx: SIMD2(cos(a), sin(a)) * speedPx,
                            radiusPx: minDim * Float.random(in: 0.035...0.055),
                            alpha: 0.95,
                            color: sat * 0.75 + SIMD3(repeating: 0.25))
            return
        }
    }

    // ── 更新 / 繪製 ──────────────────────────────────────────────────────

    private func updateSparks(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        let fr = 1 - 0.08 * dt
        for i in sparks.indices where sparks[i].active {
            sparks[i].pos += SIMD2(sparks[i].velPx.x * dt / (vw/2),
                                   sparks[i].velPx.y * dt / (vh/2))
            sparks[i].velPx *= fr
            sparks[i].alpha -= 0.12 * dt
            if sparks[i].alpha <= 0 { sparks[i].active = false }
        }
    }

    private func drawSparks(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        var verts: [TrailVertex] = []
        for s in sparks where s.active {
            let speed = max(simd_length(s.velPx), 1e-3)
            let dir = s.velPx / speed
            let lenPx = speed * 1.5 + 4
            let end = s.pos + SIMD2(dir.x * lenPx / (vw/2), dir.y * lenPx / (vh/2))
            let nrm = SIMD2(-dir.y * 1.6 / (vw/2), dir.x * 1.6 / (vh/2))
            let a = max(0, min(1, s.alpha))
            func v(_ p: SIMD2<Float>, _ d: Float, _ va: Float) -> TrailVertex {
                TrailVertex(x: p.x, y: p.y, r: s.color.x, g: s.color.y, b: s.color.z,
                            a: va, centerDist: d, trailDist: 0)
            }
            verts += [v(s.pos - nrm, -1, a), v(s.pos + nrm, 1, a), v(end - nrm, -1, a * 0.25),
                      v(s.pos + nrm, 1, a), v(end + nrm, 1, a * 0.25), v(end - nrm, -1, a * 0.25)]
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.blade,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    private func updateCracks(dt: Float) {
        for i in cracks.indices where cracks[i].active {
            cracks[i].alpha -= 0.25 * dt
            if cracks[i].alpha <= 0 { cracks[i].active = false }
        }
    }

    private func drawCracks(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        var verts: [TrailVertex] = []
        for cr in cracks where cr.active {
            let dPx = SIMD2((cr.p2.x - cr.p1.x) * vw, (cr.p2.y - cr.p1.y) * vh)
            let len = max(simd_length(dPx), 1e-3)
            let nrm = SIMD2(-dPx.y / len * 1.2 / (vw/2), dPx.x / len * 1.2 / (vh/2))
            let a = max(0, min(1, cr.alpha)) * 0.6
            func v(_ p: SIMD2<Float>, _ d: Float) -> TrailVertex {
                TrailVertex(x: p.x, y: p.y, r: 0.73, g: 0.90, b: 0.99, a: a,
                            centerDist: d, trailDist: 0)
            }
            verts += [v(cr.p1 - nrm, -1), v(cr.p1 + nrm, 1), v(cr.p2 - nrm, -1),
                      v(cr.p1 + nrm, 1), v(cr.p2 + nrm, 1), v(cr.p2 - nrm, -1)]
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.blade,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    private func updateGlints(dt: Float) {
        for i in glints.indices where glints[i].active {
            glints[i].progress += 0.16 * dt
            if glints[i].progress >= 1 { glints[i].active = false }
        }
    }

    private func drawGlints(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        var verts: [TrailVertex] = []
        for g in glints where g.active {
            let a = sin(.pi * g.progress)
            let armW = g.sizePx * 0.16
            for arm in 0..<2 {
                let ang = g.angle + Float(arm) * .pi / 2
                let dir = SIMD2(cos(ang), sin(ang))
                let l = SIMD2(dir.x * g.sizePx / (vw/2), dir.y * g.sizePx / (vh/2))
                let nrm = SIMD2(-dir.y * armW / (vw/2), dir.x * armW / (vh/2))
                func v(_ p: SIMD2<Float>, _ d: Float) -> TrailVertex {
                    TrailVertex(x: p.x, y: p.y, r: 0.95, g: 0.98, b: 1, a: a,
                                centerDist: d, trailDist: 0)
                }
                verts += [v(g.pos - l, 0), v(g.pos + nrm, 1), v(g.pos - nrm, -1),
                          v(g.pos + nrm, 1), v(g.pos + l, 0), v(g.pos - nrm, -1)]
            }
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.blade,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    private func updateWaves(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        for i in waves.indices where waves[i].active {
            waves[i].pos += SIMD2(waves[i].velPx.x * dt / (vw/2),
                                  waves[i].velPx.y * dt / (vh/2))
            waves[i].radiusPx *= 1 + 0.03 * dt
            waves[i].alpha -= 0.10 * dt
            if waves[i].alpha <= 0 { waves[i].active = false }
        }
    }

    private func drawWaves(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let halfSpan = Float.pi / 3.2
        let maxW = ctx.minDim * 0.0080
        let segments = 12

        for w in waves where w.active {
            var verts: [TrailVertex] = []
            for i in 0...segments {
                let t = Float(i) / Float(segments)
                let ang = w.angle - halfSpan + t * 2 * halfSpan
                let wPx = maxW * sin(.pi * t)
                let iPx = max(0, w.radiusPx - wPx)
                let oPx = w.radiusPx + wPx
                let ca = cos(ang), sa = sin(ang)
                let a = max(0, min(1, w.alpha))
                verts.append(TrailVertex(
                    x: w.pos.x + ca * iPx / (vw/2), y: w.pos.y + sa * iPx / (vh/2),
                    r: w.color.x, g: w.color.y, b: w.color.z, a: a,
                    centerDist: -1, trailDist: 0))
                verts.append(TrailVertex(
                    x: w.pos.x + ca * oPx / (vw/2), y: w.pos.y + sa * oPx / (vh/2),
                    r: w.color.x, g: w.color.y, b: w.color.z, a: a,
                    centerDist: 1, trailDist: 0))
            }
            encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.blade,
                                   uniforms: ctx.uniforms, device: ctx.device)
        }
    }
}

// ── 顏色工具（飽和化 / 色相偏移，對應 Android 的 HSV 操作） ────────────────
enum ColorUtil {
    static func saturate(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var (h, s, v) = rgbToHsv(c)
        s = max(s, 0.85); v = 1
        return hsvToRgb(h, s, v)
    }

    static func hueShift(_ c: SIMD3<Float>, degrees: Float) -> SIMD3<Float> {
        var (h, s, v) = rgbToHsv(c)
        h = (h + degrees).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return hsvToRgb(h, s, v)
    }

    static func rgbToHsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maxc = max(c.x, max(c.y, c.z))
        let minc = min(c.x, min(c.y, c.z))
        let d = maxc - minc
        var h: Float = 0
        if d > 0 {
            if maxc == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if maxc == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, maxc == 0 ? 0 : d / maxc, maxc)
    }

    static func hsvToRgb(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: SIMD3<Float>
        switch h {
        case ..<60:  rgb = SIMD3(c, x, 0)
        case ..<120: rgb = SIMD3(x, c, 0)
        case ..<180: rgb = SIMD3(0, c, x)
        case ..<240: rgb = SIMD3(0, x, c)
        case ..<300: rgb = SIMD3(x, 0, c)
        default:     rgb = SIMD3(c, 0, x)
        }
        return rgb + SIMD3(repeating: m)
    }
}
