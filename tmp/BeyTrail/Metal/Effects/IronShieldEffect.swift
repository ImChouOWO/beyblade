import Foundation
import Metal
import simd

/// 不滅鋼盾 — 對應 Android IronShieldGLEffect（最終版）：
///   硬邊力場軌跡 + 研磨噴射火花 + 尾流震波環 + 旋轉六角裝甲（板+反轉內框+厚外壁+鉚釘）
///   + 盾面衝擊弧 + 受擊閃光撐大。
final class IronShieldEffect: EffectRenderer {

    private struct Spark {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var velPx = SIMD2<Float>(0, 0)     // px/frame
        var alpha: Float = 0, decay: Float = 0.1, halfWPx: Float = 2
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var sparks = [Spark](repeating: Spark(), count: 80)

    private struct Ring {
        var active = false
        var pos = SIMD2<Float>(0, 0)
        var radiusPx: Float = 0, maxRadiusPx: Float = 0, alpha: Float = 0
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var rings = [Ring](repeating: Ring(), count: 5)

    private struct Arc {
        var active = false
        var trackId = 0
        var pos = SIMD2<Float>(0, 0)
        var angle: Float = 0
        var radiusPx: Float = 0, maxRadiusPx: Float = 0, alpha: Float = 0
        var color = SIMD3<Float>(1, 1, 1)
    }
    private var arcs = [Arc](repeating: Arc(), count: 3)

    private var lastPos: [Int: SIMD2<Float>] = [:]
    private var flash: [Int: Float] = [:]
    private var hexSpin: Float = 0

    private let hexInnerR: Float = 0.034
    private let hexOuterR: Float = 0.052

    func draw(trackData: [Int: [(TrailPoint, Float)]],
              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        hexSpin += 0.06 * ctx.dtScale
        if hexSpin > 40 * .pi { hexSpin -= 40 * .pi }

        for (_, pts) in trackData where pts.count >= 2 {
            drawRibbon(pts, encoder: encoder, ctx: ctx)
        }
        updateRings(dt: ctx.dtScale)
        drawRings(encoder: encoder, ctx: ctx)
        spawn(trackData, ctx: ctx)
        updateArcs(trackData, ctx: ctx)
        drawArcs(encoder: encoder, ctx: ctx)
        updateSparks(ctx: ctx)
        drawSparks(encoder: encoder, ctx: ctx)
        drawHexArmor(trackData, encoder: encoder, ctx: ctx)   // 裝甲最上層

        // 受擊閃光衰減
        for (k, v) in flash {
            let nv = v * (1 - 0.18 * ctx.dtScale)
            if nv < 0.05 { flash.removeValue(forKey: k) } else { flash[k] = nv }
        }
    }

    // ── 力場軌跡 ─────────────────────────────────────────────────────────

    private func drawRibbon(_ pts: [(TrailPoint, Float)],
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
            let hw: Float = 0.024 * life
            let lo = p[i] - normal * hw, hi = p[i] + normal * hw
            verts.append(TrailVertex(x: lo.x, y: lo.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: -1, trailDist: 0))
            verts.append(TrailVertex(x: hi.x, y: hi.y, r: c.x, g: c.y, b: c.z,
                                     a: life, centerDist: 1, trailDist: 0))
        }
        encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.shield,
                               uniforms: ctx.uniforms, device: ctx.device)
    }

    // ── 噴濺 / 環 / 弧 spawn ─────────────────────────────────────────────

    private func spawn(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }

        for (trackId, pts) in trackData where pts.count >= 2 {
            let head = ctx.toNDC(pts[pts.count-1].0.center)
            let prev = ctx.toNDC(pts[pts.count-2].0.center)
            let d = head - prev
            let moveLen = simd_length(d)
            let moveAngle = atan2(d.y * vh, d.x * vw)
            let color = pts.last!.0.color

            let dist: Float = lastPos[trackId].map { simd_distance(head, $0) }
                ?? .greatestFiniteMagnitude
            guard dist > 0.006 else { continue }
            lastPos[trackId] = head
            let moveNorm = moveLen / ctx.dtScale

            if moveNorm > 0.008 {
                let jetCount = 3 + min(6, Int(moveNorm * 250))
                spawnSparks(at: head, angle: moveAngle + .pi, coneHalf: 0.55,
                            count: jetCount, speed: 8...26, decay: 0.05...0.09, color: color)
            }
            if moveNorm > 0.010 && Float.random(in: 0...1) > 0.45 {
                spawnRing(at: head, moveNorm: moveNorm, color: color, ctx: ctx)
            }
            if moveNorm > 0.014 {
                flash[trackId] = 1
                spawnArc(trackId: trackId, at: head, angle: moveAngle,
                         moveNorm: moveNorm, color: color, ctx: ctx)
                spawnSparks(at: head, angle: moveAngle + 1.6, coneHalf: 0.7,
                            count: 3, speed: 12...28, decay: 0.09...0.14, color: color)
                spawnSparks(at: head, angle: moveAngle - 1.6, coneHalf: 0.7,
                            count: 3, speed: 12...28, decay: 0.09...0.14, color: color)
            }
            if moveNorm > 0.020 {
                spawnSparks(at: head, angle: 0, coneHalf: .pi,
                            count: 8, speed: 14...30, decay: 0.08...0.13, color: color)
            }
        }
    }

    private func spawnSparks(at pos: SIMD2<Float>, angle: Float, coneHalf: Float,
                             count: Int, speed: ClosedRange<Float>,
                             decay: ClosedRange<Float>, color: SIMD3<Float>) {
        var spawned = 0
        for i in sparks.indices where !sparks[i].active {
            let a = angle + Float.random(in: -coneHalf...coneHalf)
            let s = Float.random(in: speed)
            sparks[i].active = true
            sparks[i].pos = pos
            sparks[i].velPx = SIMD2(cos(a), sin(a)) * s
            sparks[i].alpha = 1
            sparks[i].decay = Float.random(in: decay)
            sparks[i].halfWPx = Float.random(in: 1.6...3.6)
            sparks[i].color = Float.random(in: 0...1) > 0.45
                ? color * 0.55 + SIMD3(repeating: 0.45) : SIMD3(1, 1, 1)
            spawned += 1
            if spawned >= count { return }
        }
    }

    private func spawnRing(at pos: SIMD2<Float>, moveNorm: Float,
                           color: SIMD3<Float>, ctx: RenderContext) {
        for i in rings.indices where !rings[i].active {
            let m = ctx.minDim
            rings[i] = Ring(active: true, pos: pos,
                            radiusPx: m * 0.010,
                            maxRadiusPx: min(m * (0.038 + moveNorm * 0.5), m * 0.062),
                            alpha: 0.60,
                            color: color * 0.5 + SIMD3(repeating: 0.5))
            return
        }
    }

    private func spawnArc(trackId: Int, at pos: SIMD2<Float>, angle: Float,
                          moveNorm: Float, color: SIMD3<Float>, ctx: RenderContext) {
        for i in arcs.indices where !arcs[i].active {
            let m = ctx.minDim
            arcs[i] = Arc(active: true, trackId: trackId, pos: pos, angle: angle,
                          radiusPx: m * 0.014,
                          maxRadiusPx: min(m * (0.030 + moveNorm * 0.6), m * 0.052),
                          alpha: 1,
                          color: color * 0.6 + SIMD3(repeating: 0.4))
            return
        }
    }

    // ── 更新與繪製 ───────────────────────────────────────────────────────

    private func updateRings(dt: Float) {
        for i in rings.indices where rings[i].active {
            rings[i].radiusPx += (rings[i].maxRadiusPx - rings[i].radiusPx) * 0.22 * dt
            rings[i].alpha -= 0.055 * dt
            if rings[i].alpha <= 0 || rings[i].maxRadiusPx - rings[i].radiusPx < 1 {
                rings[i].active = false
            }
        }
    }

    private func drawRings(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        for r in rings where r.active {
            drawBand(center: r.pos, radiusPx: r.radiusPx, halfWidthPx: ctx.minDim * 0.0032,
                     from: 0, to: 2 * .pi, segments: 16,
                     color: r.color, alpha: max(0, min(1, r.alpha)),
                     encoder: encoder, ctx: ctx)
        }
    }

    private func updateArcs(_ trackData: [Int: [(TrailPoint, Float)]], ctx: RenderContext) {
        for i in arcs.indices where arcs[i].active {
            if let pts = trackData[arcs[i].trackId], let head = pts.last {
                arcs[i].pos = ctx.toNDC(head.0.center)
            }
            arcs[i].radiusPx += (arcs[i].maxRadiusPx - arcs[i].radiusPx) * 0.4 * ctx.dtScale
            arcs[i].alpha -= 0.18 * ctx.dtScale
            if arcs[i].alpha <= 0 || arcs[i].maxRadiusPx - arcs[i].radiusPx < 0.5 {
                arcs[i].active = false
            }
        }
    }

    private func drawArcs(encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let halfSpan = Float.pi / 3.5
        for a in arcs where a.active {
            drawBand(center: a.pos, radiusPx: a.radiusPx, halfWidthPx: ctx.minDim * 0.0042,
                     from: a.angle - halfSpan, to: a.angle + halfSpan, segments: 10,
                     color: a.color, alpha: max(0, min(1, a.alpha)),
                     encoder: encoder, ctx: ctx)
        }
    }

    private func updateSparks(ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let dt = ctx.dtScale
        let fr = 1 - 0.08 * dt
        for i in sparks.indices where sparks[i].active {
            sparks[i].pos += SIMD2(sparks[i].velPx.x * dt / (vw/2),
                                   sparks[i].velPx.y * dt / (vh/2))
            sparks[i].velPx *= fr
            sparks[i].alpha -= sparks[i].decay * dt
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
            let lenPx = speed * 2.8 + 3
            let end = s.pos + SIMD2(dir.x * lenPx / (vw/2), dir.y * lenPx / (vh/2))
            let nrm = SIMD2(-dir.y * s.halfWPx / (vw/2), dir.x * s.halfWPx / (vh/2))
            let a = max(0, min(1, s.alpha))
            let c = s.color
            func v(_ p: SIMD2<Float>, _ d: Float, _ va: Float) -> TrailVertex {
                TrailVertex(x: p.x, y: p.y, r: c.x, g: c.y, b: c.z, a: va,
                            centerDist: d, trailDist: 0)
            }
            verts += [v(s.pos - nrm, -1, a), v(s.pos + nrm, 1, a), v(end - nrm, -1, a * 0.3),
                      v(s.pos + nrm, 1, a), v(end + nrm, 1, a * 0.3), v(end - nrm, -1, a * 0.3)]
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.shield,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    // ── 六角裝甲 ─────────────────────────────────────────────────────────

    private func drawHexArmor(_ trackData: [Int: [(TrailPoint, Float)]],
                              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let m = ctx.minDim
        guard m > 0 else { return }
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)

        for (trackId, pts) in trackData {
            guard let (tp, headAlpha) = pts.last, headAlpha >= 0.05 else { continue }
            let center = ctx.toNDC(tp.center)
            let f = flash[trackId] ?? 0
            let boost = 1 + f * 0.22
            let outerRot = hexSpin * 0.7
            let innerRot = -hexSpin * 1.6
            let base = tp.color
            let lifted = base * 0.5 + SIMD3<Float>(repeating: 0.5)

            // 半透明裝甲板（fan，平面 d=0.45）
            drawHexPlate(center: center, radiusPx: m * hexOuterR * boost, rot: outerRot,
                         color: base, alpha: headAlpha * (0.50 + f * 0.45),
                         encoder: encoder, ctx: ctx)
            // 內框（反向旋轉）
            drawBand(center: center, radiusPx: m * hexInnerR * boost,
                     halfWidthPx: m * 0.0026, from: innerRot, to: innerRot + 2 * .pi,
                     segments: 6, color: lifted, alpha: headAlpha * 0.60,
                     encoder: encoder, ctx: ctx)
            // 厚外壁
            drawBand(center: center, radiusPx: m * hexOuterR * boost,
                     halfWidthPx: m * 0.0050, from: outerRot, to: outerRot + 2 * .pi,
                     segments: 6, color: lifted, alpha: headAlpha * min(1, 0.90 + f * 0.10),
                     encoder: encoder, ctx: ctx)
            // 角落鉚釘（6 顆徑向短柱）
            var studVerts: [TrailVertex] = []
            let halfLen = m * 0.0085, halfW = m * 0.0034
            for k in 0..<6 {
                let ang = outerRot + 2 * .pi * Float(k) / 6
                let dir = SIMD2(cos(ang), sin(ang))
                let corner = center + SIMD2(dir.x * m * hexOuterR * boost / (vw/2),
                                            dir.y * m * hexOuterR * boost / (vh/2))
                let l = SIMD2(dir.x * halfLen / (vw/2), dir.y * halfLen / (vh/2))
                let nrm = SIMD2(-dir.y * halfW / (vw/2), dir.x * halfW / (vh/2))
                let a = headAlpha * 0.95
                func v(_ p: SIMD2<Float>, _ d: Float) -> TrailVertex {
                    TrailVertex(x: p.x, y: p.y, r: lifted.x, g: lifted.y, b: lifted.z,
                                a: a, centerDist: d, trailDist: 0)
                }
                studVerts += [v(corner - l - nrm, -1), v(corner - l + nrm, 1), v(corner + l - nrm, -1),
                              v(corner - l + nrm, 1), v(corner + l + nrm, 1), v(corner + l - nrm, -1)]
            }
            encoder.drawTrailTriangles(studVerts, pipeline: ctx.pipelines.shield,
                                       uniforms: ctx.uniforms, device: ctx.device)
        }
    }

    private func drawHexPlate(center: SIMD2<Float>, radiusPx: Float, rot: Float,
                              color: SIMD3<Float>, alpha: Float,
                              encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        let rx = radiusPx / (vw/2), ry = radiusPx / (vh/2)
        // fan → triangles（中心 + 六邊）
        var verts: [TrailVertex] = []
        func v(_ p: SIMD2<Float>) -> TrailVertex {
            TrailVertex(x: p.x, y: p.y, r: color.x, g: color.y, b: color.z,
                        a: alpha, centerDist: 0.45, trailDist: 0)
        }
        var rim: [SIMD2<Float>] = []
        for i in 0...6 {
            let ang = rot + 2 * .pi * Float(i) / 6
            rim.append(center + SIMD2(rx * cos(ang), ry * sin(ang)))
        }
        for i in 0..<6 {
            verts += [v(center), v(rim[i]), v(rim[i + 1])]
        }
        encoder.drawTrailTriangles(verts, pipeline: ctx.pipelines.shield,
                                   uniforms: ctx.uniforms, device: ctx.device)
    }

    /// 徑向環帶（六角 = segments 6；圓環/弧 = 任意段數）
    private func drawBand(center: SIMD2<Float>, radiusPx: Float, halfWidthPx: Float,
                          from: Float, to: Float, segments: Int,
                          color: SIMD3<Float>, alpha: Float,
                          encoder: MTLRenderCommandEncoder, ctx: RenderContext) {
        let vw = Float(ctx.viewWidth), vh = Float(ctx.viewHeight)
        guard vw > 0, vh > 0 else { return }
        let iPx = max(0, radiusPx - halfWidthPx)
        let oPx = radiusPx + halfWidthPx
        var verts: [TrailVertex] = []
        for i in 0...segments {
            let ang = from + (to - from) * Float(i) / Float(segments)
            let ca = cos(ang), sa = sin(ang)
            let inner = center + SIMD2(iPx / (vw/2) * ca, iPx / (vh/2) * sa)
            let outer = center + SIMD2(oPx / (vw/2) * ca, oPx / (vh/2) * sa)
            verts.append(TrailVertex(x: inner.x, y: inner.y, r: color.x, g: color.y,
                                     b: color.z, a: alpha, centerDist: -1, trailDist: 0))
            verts.append(TrailVertex(x: outer.x, y: outer.y, r: color.x, g: color.y,
                                     b: color.z, a: alpha, centerDist: 1, trailDist: 0))
        }
        encoder.drawTrailStrip(verts, pipeline: ctx.pipelines.shield,
                               uniforms: ctx.uniforms, device: ctx.device)
    }
}
