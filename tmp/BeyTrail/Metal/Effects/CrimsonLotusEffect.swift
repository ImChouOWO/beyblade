import Foundation
import Metal
import simd

/// 紅蓮破滅 — 對應 Android CrimsonLotusGLEffect（最終版）：
///   雙股蛇形活火舌（fire 雜訊 shader、尾部燒蝕）+ 不規則多邊形火球（劇烈擴張）
///   + 餘燼火星（上飄閃爍）+ 熱空氣折射殘影。顏色基底 = 陀螺色。
final class CrimsonLotusEffect: EffectRenderer {

    private struct Fireball {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var velPx = SIMD2<Float>(0, 0)
        var grow: Float = 0.12, scale: Float = 1
        var alpha: Float = 0, decay: Float = 0.09
        var vertexCount = 5
        var ox = [Float](repeating: 0, count: 6)
        var oy = [Float](repeating: 0, count: 6)
        var color = SIMD3<Float>(1, 0.4, 0.1)
    }
    private var fireballs = [Fireball](repeating: Fireball(), count: 16)

    private struct Ember {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var velPx = SIMD2<Float>(0, 0)
        var sizePx: Float = 3
        var alpha: Float = 0, decay: Float = 0.06
        var color = SIMD3<Float>(1, 0.5, 0.1)
    }
    private var embers = [Ember](repeating: Ember(), count: 24)

    private struct Haze {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var sizePx: Float = 30
        var alpha: Float = 0
    }
    private var hazes = [Haze](repeating: Haze(), count: 20)

    private var lastPos: [Int: SIMD2<Float>] = [:]

    private let tongueHalfWidth: Float = 0.034
    private let serpentAmp: Float = 0.024
    private let twistFreq: Float = 2.4
    private let wriggleSpeed: Float = 8.5

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        // 熱浪墊底
        updateHaze(dt: ctx.dtScale)
        drawHaze(encoder: encoder, ctx: ctx)

        for (_, pts) in trackData where pts.count >= 3 {
            drawFireTongues(pts, encoder: encoder, ctx: ctx)
        }
        spawn(trackData, ctx: ctx)
        updateFireballs(ctx: ctx)
        drawFireballs(encoder: encoder, ctx: ctx)
        updateEmbers(ctx: ctx)
        drawEmbers(encoder: encoder, ctx: ctx)
    }

    // ── 雙股蛇形火舌 ─────────────────────────────────────────────────────

    private func drawFireTongues(_ pts: [(TrailPoint, Float)],
                                 encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let n = pts.count
        var raw = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n { raw[i] = ctx.toNDC(pts[i].0.center) }

        let m = min(n * 3, 64)
        var rp = [SIMD2<Float>](repeating: .zero, count: m)
        var ra = [Float](repeating: 0, count: m)
        var cum = [Float](repeating: 0, count: m)
        for j in 0..<m {
            let f = Float(j) / Float(m - 1) * Float(n - 1)
            let i0 = min(Int(f), n - 2)
            let fr = f - Float(i0)
            rp[j] = raw[i0] + (raw[i0+1] - raw[i0]) * fr
            ra[j] = pts[i0].1 + (pts[i0+1].1 - pts[i0].1) * fr
            if j > 0 { cum[j] = cum[j-1] + simd_distance(rp[j], rp[j-1]) }
        }
        let total = cum[m-1]
        let c = pts.last!.0.color

        for strand in 0..<2 {
            let phase = Float(strand) * .pi
            let wMult: Float = strand == 0 ? 1 : 0.62
            let aMult: Float = strand == 0 ? 1 : 0.7
            var verts: [TrailVertex] = []
            for j in 0..<m {
                let normal: SIMD2<Float> =
                    j == 0 ? GeomHelper.segNormal(rp[0], rp[1]) :
                    j == m - 1 ? GeomHelper.segNormal(rp[m-2], rp[m-1]) :
                    GeomHelper.avgNormal(rp[j-1], rp[j], rp[j+1])
                let u = Float(j) / Float(m - 1)
                let life = ra[j]
                // 蛇形扭動：頭端緊貼陀螺，尾端自由甩動，隨時間翻滾
                let wave = sin(u * twistFreq * 2 * .pi + phase - ctx.time * wriggleSpeed)
                let off = wave * serpentAmp * (1 - u)
                let hw = tongueHalfWidth * wMult * (0.30 + 0.70 * life)
                let cpos = rp[j] + normal * off
                let a = life * aMult
                let trail = total - cum[j]
                let lo = cpos - normal * hw, hi = cpos + normal * hw
                verts.append(TrailVertex(x: lo.x, y: lo.y, r: c.x, g: c.y, b: c.z,
                                         a: a, centerDist: -1, trailDist: trail))
                verts.append(TrailVertex(x: hi.x, y: hi.y, r: c.x, g: c.y, b: c.z,
                                         a: a, centerDist: 1, trailDist: trail))
            }
            encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.fire,
                                   uniforms: ctx.uniforms, device: ctx.device)
        }
    }

    // ── Spawning ─────────────────────────────────────────────────────────

    private func spawn(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        let minDim = ctx.minDim
        guard minDim > 0 else { return }

        for (trackId, pts) in trackData where pts.count >= 2 {
            let head = ctx.toNDC(pts[pts.count-1].0.center)
            let prev = ctx.toNDC(pts[pts.count-2].0.center)
            let moveLen = simd_distance(head, prev)
            let color = pts.last!.0.color

            // 尾部餘燼：不受 dist 節流，燒不停
            if pts.count >= 4 && Float.random(in: 0...1) < 0.55 * ctx.dtScale {
                let idx = min(Int(Float.random(in: 0..<1) * Float(pts.count) * 0.6),
                              pts.count - 1)
                spawnEmber(at: ctx.toNDC(pts[idx].0.center), color: color)
            }

            let dist: Float = lastPos[trackId].map { simd_distance(head, $0) }
                ?? .greatestFiniteMagnitude
            guard dist > 0.006 else { continue }
            lastPos[trackId] = head
            let moveNorm = moveLen / ctx.dtScale

            if moveNorm > 0.010 && Float.random(in: 0...1) > 0.4 {
                spawnFireball(at: head, minDim: minDim, big: false, color: color)
            }
            if moveNorm > 0.016 {
                for _ in 0..<3 {
                    spawnFireball(at: head, minDim: minDim, big: true, color: color)
                }
            }
        }
    }

    private func spawnFireball(at pos: SIMD2<Float>, minDim: Float, big: Bool,
                               color: SIMD3<Float>) {
        for i in fireballs.indices where !fireballs[i].active {
            let angle = Float.random(in: 0...(2 * .pi))
            let speed = big ? Float.random(in: 8...16) : Float.random(in: 4...9)
            fireballs[i].active = true
            fireballs[i].pos = pos + SIMD2(Float.random(in: -0.0075...0.0075),
                                           Float.random(in: -0.0075...0.0075))
            fireballs[i].velPx = SIMD2(cos(angle), sin(angle)) * speed
            fireballs[i].scale = 1
            fireballs[i].grow = big ? 0.17 : 0.12
            fireballs[i].alpha = 1
            fireballs[i].decay = Float.random(in: 0.08...0.12)
            let basePx = big ? minDim * Float.random(in: 0.012...0.020)
                             : minDim * Float.random(in: 0.006...0.010)
            fireballs[i].vertexCount = Int.random(in: 4...6)
            for k in 0..<fireballs[i].vertexCount {
                let a = 2 * .pi * Float(k) / Float(fireballs[i].vertexCount)
                let r = basePx * Float.random(in: 0.5...1.3)
                fireballs[i].ox[k] = cos(a) * r
                fireballs[i].oy[k] = sin(a) * r
            }
            switch Int.random(in: 0..<3) {
            case 0:  fireballs[i].color = color * 0.60
            case 1:  fireballs[i].color = color
            default: fireballs[i].color = color * 0.5 + SIMD3(repeating: 0.5)
            }
            return
        }
    }

    private func spawnEmber(at pos: SIMD2<Float>, color: SIMD3<Float>) {
        for i in embers.indices where !embers[i].active {
            embers[i].active = true
            embers[i].pos = pos + SIMD2(Float.random(in: -0.01...0.01),
                                        Float.random(in: -0.01...0.01))
            embers[i].velPx = SIMD2(Float.random(in: -1.5...1.5),
                                    Float.random(in: 1.5...4))   // 上飄
            embers[i].sizePx = Float.random(in: 2...4.5)
            embers[i].alpha = 0.95
            embers[i].decay = Float.random(in: 0.045...0.085)
            switch Int.random(in: 0..<5) {
            case 0, 1: embers[i].color = color
            case 2, 3: embers[i].color = color * 0.4 + SIMD3(repeating: 0.6)
            default:   embers[i].color = color * 0.7
            }
            return
        }
    }

    private func spawnHaze(at pos: SIMD2<Float>, minDim: Float) {
        for i in hazes.indices where !hazes[i].active {
            hazes[i] = Haze(active: true, pos: pos,
                            sizePx: minDim * Float.random(in: 0.035...0.060),
                            alpha: 0.10)
            return
        }
    }

    // ── 更新 / 繪製 ──────────────────────────────────────────────────────

    private func updateFireballs(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        for i in fireballs.indices where fireballs[i].active {
            fireballs[i].pos += SIMD2(fireballs[i].velPx.x * dt / (vw/2),
                                      fireballs[i].velPx.y * dt / (vh/2))
            fireballs[i].velPx *= 1 - 0.06 * dt
            fireballs[i].scale *= 1 + fireballs[i].grow * dt
            fireballs[i].alpha -= fireballs[i].decay * dt
            if fireballs[i].alpha <= 0 {
                fireballs[i].active = false
                spawnHaze(at: fireballs[i].pos, minDim: ctx.minDim)
            }
        }
    }

    private func drawFireballs(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        var verts: [TrailVertex] = []
        for fb in fireballs where fb.active {
            let a = max(0, min(1, fb.alpha))
            let flicker = 1 + Float.random(in: -0.06...0.06)
            let s = fb.scale * flicker
            func rim(_ k: Int) -> SIMD2<Float> {
                SIMD2(fb.pos.x + fb.ox[k] * s / (vw/2),
                      fb.pos.y + fb.oy[k] * s / (vh/2))
            }
            for k in 0..<fb.vertexCount {
                let k2 = (k + 1) % fb.vertexCount
                verts.append(TrailVertex(x: fb.pos.x, y: fb.pos.y,
                                         r: fb.color.x, g: fb.color.y, b: fb.color.z,
                                         a: a, centerDist: 0, trailDist: 0))
                let v1 = rim(k), v2 = rim(k2)
                verts.append(TrailVertex(x: v1.x, y: v1.y,
                                         r: fb.color.x, g: fb.color.y, b: fb.color.z,
                                         a: a, centerDist: 1, trailDist: 0))
                verts.append(TrailVertex(x: v2.x, y: v2.y,
                                         r: fb.color.x, g: fb.color.y, b: fb.color.z,
                                         a: a, centerDist: 1, trailDist: 0))
            }
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.fireball,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    private func updateEmbers(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        for i in embers.indices where embers[i].active {
            embers[i].pos += SIMD2(embers[i].velPx.x * dt / (vw/2),
                                   embers[i].velPx.y * dt / (vh/2))
            embers[i].velPx.x *= 1 - 0.03 * dt
            embers[i].alpha -= embers[i].decay * dt
            if embers[i].alpha <= 0 { embers[i].active = false }
        }
    }

    private func drawEmbers(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        var verts: [PointVertex] = []
        for em in embers where em.active {
            let a = max(0, min(1, em.alpha * Float.random(in: 0.6...1)))   // 火星閃爍
            verts.append(PointVertex(x: em.pos.x, y: em.pos.y,
                                     r: em.color.x, g: em.color.y, b: em.color.z,
                                     a: a, size: em.sizePx))
        }
        encoder.drawPoints(verts, pipeline: ctx.pipelines.pointGauss, device: ctx.device)
    }

    private func updateHaze(dt: Float) {
        for i in hazes.indices where hazes[i].active {
            hazes[i].sizePx *= 1 + 0.010 * dt
            hazes[i].alpha -= 0.0022 * dt
            if hazes[i].alpha <= 0 { hazes[i].active = false }
        }
    }

    private func drawHaze(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        var verts: [PointVertex] = []
        for hz in hazes where hz.active {
            verts.append(PointVertex(x: hz.pos.x, y: hz.pos.y,
                                     r: 1, g: 0.96, b: 0.90,
                                     a: max(0, min(1, hz.alpha)), size: hz.sizePx))
        }
        encoder.drawPoints(verts, pipeline: ctx.pipelines.pointGauss, device: ctx.device)
    }
}
