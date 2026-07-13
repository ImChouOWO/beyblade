import UIKit
import simd

//
//  PicTrailSceneBuilder.swift
//
//  iOS 端特效幾何產生器（已對齊 Android GLEffect 視覺）。
//
//  設計重點
//  ───────────────────────────────────────────────────────────────────────
//  • 對外進入點 `build(effect:trackData:debugBoundingBoxes:viewportSize:now:)`
//    與既有版本完全相同，PicTrailMetalRenderCore / 錄影 / 離線三條路徑都不需改動。
//  • Android 每個特效是獨立 GL program + 有狀態粒子池；本檔在 builder 內維護一個
//    跨幀粒子池（builder 實例存活於 render core 整個生命週期），還原火星 / 碎片 /
//    金幣 / 葉片等真實速度、重力、衰減物理。
//  • Android 拖尾顏色一律取陀螺偵測色（pts.last().color）再依特效提飽和 / 提亮；
//    本檔比照辦理（含 Money）。
//  • DeathRay 等需要 additive 過載的特效，在現有 alpha-over 管線上以「白芯高 alpha
//    堆疊 + 提亮」模擬過載，避免侵入 render core 的 pipeline 狀態。
//
//  座標慣例轉換
//  ───────────────────────────────────────────────────────────────────────
//  • Android：NDC（-1..1）、y 向上、head = pts.last。
//  • iOS：像素座標、y 向下、head = samples.last（alpha 高）。
//  本檔一律在 iOS 像素空間運算；凡 Android 以 NDC 表示的尺寸（如 0.03f 半寬）皆乘以
//  參考短邊換算成像素，使粗細與 Android 視覺一致。
//

final class PicTrailSceneBuilder {

    // MARK: - 取樣點

    fileprivate struct Sample {
        var position: SIMD2<Float>   // 像素座標，y 向下
        var alpha: Float             // life：head≈1，tail≈0
        var color: UIColor
        var timestamp: TimeInterval
    }

    // MARK: - 跨幀粒子池

    /// 通用粒子：涵蓋火星 / 碎片 / 金幣 / 葉片 / 火球 / 霧氣 / 火環 / 墨滴等。
    /// 速度單位由 ndcVelocity 決定：true=NDC/幀（Wave），false=像素/幀（其餘）。
    fileprivate final class Particle {
        var active = false
        var x: Float = 0, y: Float = 0        // NDC（-1..1, y 向上），與 Android 一致
        var vx: Float = 0, vy: Float = 0
        var ndcVelocity = false                // 速度單位旗標
        var size: Float = 0                    // 像素（sprite 直徑或長邊 / 多邊形 basePx）
        var aspect: Float = 1                  // 長寬比（葉片 lenPx×widPx）
        var angle: Float = 0
        var spin: Float = 0                    // angle 每幀增量（angVel）
        var flip: Float = 0                    // 立體翻面相位（金幣）
        var flipVel: Float = 0
        var alpha: Float = 0
        var decay: Float = 0.06
        var grow: Float = 0                    // 每幀尺寸倍率增量
        var gravity: Float = 0                 // 像素/幀²（往畫面下 = NDC y 變小）
        var drag: Float = 0                    // 每幀速度衰減比例
        var r: Float = 1, g: Float = 1, b: Float = 1
        var style: PicSpriteStyle = .softCircle
        var life: Float = 0                    // 已存活幀數
        var maxLife: Float = 0                 // >0 時以 life/maxLife 控制（InkWash drop）
        var seed: Float = 0
        // 多邊形（Ice shard / Crimson fireball）：頂點偏移（像素，未旋轉），vcount 0=非多邊形
        var vcount = 0
        var ox = [Float](repeating: 0, count: 6)
        var oy = [Float](repeating: 0, count: 6)
        // streak（Money/Blade spark）：以速度方向拉長
        var streak = false
        var streakHalfPx: Float = 2
        // orbital（DeathRay 漩渦）：繞核心極座標收斂
        var orbital = false
        var cx: Float = 0, cy: Float = 0      // 核心 NDC
        var orbRadiusPx: Float = 0            // 距核心半徑（像素）
        var orbSpawnRadiusPx: Float = 1
        var orbAngVel: Float = 0
        var orbInVelPx: Float = 0
    }

    fileprivate final class Ripple {
        var active = false
        var x: Float = 0, y: Float = 0
        var radius: Float = 0
        var maxRadius: Float = 0
        var alpha: Float = 0
        var grow: Float = 5          // 像素/幀
        var r: Float = 1, g: Float = 1, b: Float = 1
        var style: PicSpriteStyle = .ring
    }

    private var particles: [Particle]
    private var ripples: [Ripple]

    /// 每條 track 上一幀的頭部位置（節流 spawn 用），key = trackID。
    private var lastHeadPosition: [Int: SIMD2<Float>] = [:]

    /// 上一幀時間戳，用來推導 dtScale（60fps 時 ≈ 0.5）。
    private var lastFrameTime: TimeInterval = 0

    /// 連續性累加器（用於以「每秒 N 顆」方式穩定 spawn）。
    private var spawnAccumulators: [String: Float] = [:]

    /// 目前視窗半寬高（粒子 NDC↔像素換算用），每幀於 build 開頭更新。
    private var vwHalf: Float = 1
    private var vhHalf: Float = 1

    init(particleCapacity: Int = 1024, rippleCapacity: Int = 48) {
        particles = (0..<particleCapacity).map { _ in Particle() }
        ripples = (0..<rippleCapacity).map { _ in Ripple() }
    }

    // MARK: - 進入點（簽名與舊版完全相同）

    func build(
        effect: EffectType,
        trackData: [Int: [(TrailPoint, Float)]],
        debugBoundingBoxes: [(CGRect, Int)],
        viewportSize: CGSize,
        now: TimeInterval
    ) -> PicFrameGeometry {
        var geometry = PicFrameGeometry()

        guard viewportSize.width > 1, viewportSize.height > 1 else {
            return geometry
        }

        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)
        let minDim = min(width, height)
        vwHalf = max(width * 0.5, 1)
        vhHalf = max(height * 0.5, 1)

        // dtScale：以 60fps 為基準時 ≈ 0.5；首幀或長間隔時夾在合理範圍。
        let rawDelta = lastFrameTime > 0 ? Float(now - lastFrameTime) : (1.0 / 60.0)
        let dtScale = clamp(rawDelta / (1.0 / 30.0), 0.2, 2.0)
        lastFrameTime = now

        let timeF = Float(now.truncatingRemainder(dividingBy: 4_096))

        // 預先把所有 track 轉成像素空間取樣點。
        var sampleByTrack: [Int: [Sample]] = [:]
        for (trackID, points) in trackData where points.count >= 2 {
            sampleByTrack[trackID] = makeSamples(points, width: width, height: height)
        }

        // ── 先更新並繪製既有跨幀粒子 / 漣漪（在拖尾下層或上層依特效而定） ──
        // 多數特效粒子畫在拖尾「之後」（火星、碎片飛在尾跡前方）。
        // 少數（haze / 年輪 / 漆塊）需墊底，於各 build* 內以順序控制。

        // ── 逐 track 產生本幀幾何並 spawn 新粒子 ──
        for trackID in sampleByTrack.keys.sorted() {
            guard let samples = sampleByTrack[trackID], samples.count >= 2 else { continue }

            switch effect {
            case .lightning:
                buildLightning(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                               minDim: minDim, geometry: &geometry)
            case .fire:
                buildFire(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                          minDim: minDim, geometry: &geometry)
            case .stardust:
                buildStardust(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                              minDim: minDim, geometry: &geometry)
            case .wave:
                buildWave(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                          minDim: minDim, width: width, height: height, geometry: &geometry)
            case .thunder:   // → Money 金錢衝擊
                buildMoney(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                           minDim: minDim, width: width, height: height, geometry: &geometry)
            case .vortex:    // → Blade 爆刃亂舞
                buildBlade(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                           minDim: minDim, width: width, height: height, geometry: &geometry)
            case .dark:      // → IceShatter 狂暴冰裂
                buildIce(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                         minDim: minDim, width: width, height: height, geometry: &geometry)
            case .crimson:   // → CrimsonLotus 紅蓮破滅
                buildCrimson(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                             minDim: minDim, width: width, height: height, geometry: &geometry)
            case .deathRay:  // → DeathRay 破壞死光
                buildDeathRay(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                              minDim: minDim, width: width, height: height, geometry: &geometry)
            case .emerald:   // → Emerald 翡翠破壞
                buildEmerald(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                             minDim: minDim, width: width, height: height, geometry: &geometry)
            case .inkWash:   // → InkWash 水墨橫空
                buildInkWash(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                             minDim: minDim, geometry: &geometry)
            case .spray:     // → SprayPaint 噴漆塗鴉
                buildSprayPaint(samples, trackID: trackID, now: timeF, dtScale: dtScale,
                                minDim: minDim, width: width, height: height, geometry: &geometry)
            }
        }

        // ── 統一推進並輸出跨幀粒子 / 漣漪 ──
        updateParticles(dtScale: dtScale, width: width, height: height)
        updateRipples(dtScale: dtScale)
        appendParticleSprites(into: &geometry)
        appendRippleSprites(into: &geometry, width: width, height: height)

        appendDebugBoxes(debugBoundingBoxes, width: width, height: height, geometry: &geometry)

        return geometry
    }

    // MARK: - 取樣（像素空間）

    private func makeSamples(
        _ points: [(TrailPoint, Float)],
        width: Float,
        height: Float
    ) -> [Sample] {
        points.map { point, alpha in
            Sample(
                position: SIMD2(Float(point.center.x) * width,
                                Float(point.center.y) * height),
                alpha: clamp(alpha, 0, 1),
                color: point.color,
                timestamp: point.timestamp
            )
        }
    }

    /// 取陀螺主色（head）。Android 一律以 pts.last().color 當基底。
    private func headColor(_ samples: [Sample]) -> SIMD4<Float> {
        rgba(samples.last?.color ?? .white)
    }
}


// MARK: - 共用幾何基礎設施
extension PicTrailSceneBuilder {

    /// NDC 半寬 → 像素半寬。px = ndc * (minDim / 2)。
    func ndcToPixels(_ ndc: Float, minDim: Float) -> Float { ndc * minDim * 0.5 }

    // 粒子座標以 NDC 存放（沿用 Android 物理），輸出時轉像素。
    func ndcXToPixel(_ nx: Float) -> Float { (nx + 1) * vwHalf }
    func ndcYToPixel(_ ny: Float) -> Float { (1 - ny) * vhHalf }
    func pixelToNDCx(_ px: Float) -> Float { px / vwHalf - 1 }
    func pixelToNDCy(_ py: Float) -> Float { 1 - py / vhHalf }

    /// 對取樣點做 ×factor 線性重採樣（蛇形 / 藤蔓 / 刀身平滑曲線）。
    fileprivate func resample(_ samples: [Sample], factor: Int, cap: Int) -> (pos: [SIMD2<Float>], alpha: [Float]) {
        let n = samples.count
        guard n >= 2 else { return (samples.map { $0.position }, samples.map { $0.alpha }) }
        let m = min(n * factor, cap)
        guard m >= 2 else { return (samples.map { $0.position }, samples.map { $0.alpha }) }
        var pos: [SIMD2<Float>] = []; pos.reserveCapacity(m)
        var alp: [Float] = []; alp.reserveCapacity(m)
        for j in 0..<m {
            let f = Float(j) / Float(m - 1) * Float(n - 1)
            let i0 = min(Int(f), n - 2)
            let fr = f - Float(i0)
            pos.append(samples[i0].position + (samples[i0 + 1].position - samples[i0].position) * fr)
            alp.append(samples[i0].alpha + (samples[i0 + 1].alpha - samples[i0].alpha) * fr)
        }
        return (pos, alp)
    }

    /// 平均法線（等同 Android avgNormal / segNormal，像素空間）。
    func averagedNormal(_ positions: [SIMD2<Float>], index: Int) -> SIMD2<Float> {
        let tangent: SIMD2<Float>
        if index == 0 { tangent = positions[1] - positions[0] }
        else if index == positions.count - 1 { tangent = positions[index] - positions[index - 1] }
        else { tangent = positions[index + 1] - positions[index - 1] }
        let length = max(simd_length(tangent), 0.0001)
        let u = tangent / length
        return SIMD2(-u.y, u.x)
    }

    // MARK: Ribbon 層

    /// 通用 ribbon 層。uv.x = 中心距離∈[-1,1]，uv.y = 沿尾跡參數∈[0,1]。
    func appendRibbon(
        positions: [SIMD2<Float>],
        alphas: [Float],
        halfWidthPx: Float,
        color: SIMD4<Float>,
        style: PicRibbonStyle,
        alphaScale: Float,
        widthTailBias: Float = 0.34,
        widthHeadBias: Float = 0.66,
        centerlineOffset: ((Int, Float, SIMD2<Float>) -> SIMD2<Float>)? = nil,
        trailReversed: Bool = false,
        seedBase: Float = 0,
        into geometry: inout PicFrameGeometry
    ) {
        let count = positions.count
        guard count >= 2 else { return }
        var cumulative = [Float](repeating: 0, count: count)
        for i in 1..<count {
            cumulative[i] = cumulative[i - 1] + simd_length(positions[i] - positions[i - 1])
        }
        let totalLength = max(cumulative.last ?? 1, 1)
        let start = geometry.ribbonVertices.count
        for i in 0..<count {
            let normal = averagedNormal(positions, index: i)
            let alpha = alphas[i]
            var center = positions[i]
            if let off = centerlineOffset { center += off(i, alpha, normal) }
            let halfWidth = halfWidthPx * (widthTailBias + widthHeadBias * alpha)
            var c = color
            c.w *= alpha * alphaScale
            let trailT = trailReversed
                ? (totalLength - cumulative[i]) / totalLength
                : cumulative[i] / totalLength
            let seed = seedBase + Float(i) * 0.013
            geometry.ribbonVertices.append(
                PicRibbonVertex(position: center - normal * halfWidth, color: c,
                                uv: SIMD2(-1, trailT), style: style.rawValue, seed: seed))
            geometry.ribbonVertices.append(
                PicRibbonVertex(position: center + normal * halfWidth, color: c,
                                uv: SIMD2(1, trailT), style: style.rawValue, seed: seed))
        }
        geometry.ribbonRanges.append(
            PicDrawRange(start: start, count: geometry.ribbonVertices.count - start))
    }

    // MARK: Sprite

    func appendSprite(
        center: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float>,
        style: PicSpriteStyle, rotation: Float, seed: Float, age: Float,
        into geometry: inout PicFrameGeometry
    ) {
        let corners: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
            SIMD2(-1, 1),  SIMD2(1, -1), SIMD2(1, 1)
        ]
        for corner in corners {
            geometry.spriteVertices.append(
                PicSpriteVertex(center: center, corner: corner, size: size, color: color,
                                rotation: rotation, style: style.rawValue, seed: seed, age: age))
        }
    }

    // MARK: 跨幀粒子池

    fileprivate func spawnParticle(_ configure: (Particle) -> Void) {
        for p in particles where !p.active {
            p.active = true
            p.vx = 0; p.vy = 0; p.ndcVelocity = false; p.size = 0; p.aspect = 1
            p.angle = 0; p.spin = 0; p.flip = 0; p.flipVel = 0
            p.alpha = 1; p.decay = 0.06
            p.grow = 0; p.gravity = 0; p.drag = 0
            p.r = 1; p.g = 1; p.b = 1; p.style = .softCircle
            p.life = 0; p.maxLife = 0; p.seed = 0
            p.vcount = 0; p.streak = false; p.streakHalfPx = 2
            p.orbital = false; p.cx = 0; p.cy = 0; p.orbRadiusPx = 0
            p.orbSpawnRadiusPx = 1; p.orbAngVel = 0; p.orbInVelPx = 0
            configure(p)
            return
        }
    }

    fileprivate func spawnRipple(_ configure: (Ripple) -> Void) {
        for r in ripples where !r.active {
            r.active = true
            r.radius = 0; r.maxRadius = 0; r.alpha = 1; r.grow = 5
            r.r = 1; r.g = 1; r.b = 1; r.style = .ring
            configure(r)
            return
        }
    }

    func updateParticles(dtScale dt: Float, width: Float, height: Float) {
        for p in particles where p.active {
            if p.orbital {
                // DeathRay 漩渦：繞核心旋轉 + 半徑收斂（對齊 .kt drawVortexPoints）
                p.angle += p.orbAngVel * dt
                p.orbRadiusPx -= p.orbInVelPx * dt
                if p.orbRadiusPx <= min(width, height) * 0.010 { p.active = false; continue }
                p.x = p.cx + cos(p.angle) * p.orbRadiusPx / vwHalf
                p.y = p.cy + sin(p.angle) * p.orbRadiusPx / vhHalf
                continue
            }
            // 速度單位分流：Wave 用 NDC/幀（直接加），其餘 px/幀（除半寬高）。
            if p.ndcVelocity {
                p.x += p.vx * dt
                p.y += p.vy * dt
            } else {
                p.x += p.vx * dt / vwHalf
                p.y += p.vy * dt / vhHalf
            }
            if p.drag != 0 { let fr = 1 - p.drag * dt; p.vx *= fr; p.vy *= fr }
            if p.gravity != 0 { p.vy -= p.gravity * dt }
            if p.grow != 0 { p.size *= 1 + p.grow * dt }
            if p.spin != 0 { p.angle += p.spin * dt }
            if p.flipVel != 0 { p.flip += p.flipVel * dt }
            if p.maxLife > 0 {
                p.life += dt
                if p.life >= p.maxLife { p.active = false }
            } else {
                p.alpha -= p.decay * dt
                if p.alpha <= 0 { p.active = false }
            }
        }
    }

    func updateRipples(dtScale dt: Float) {
        for r in ripples where r.active {
            if r.maxRadius > 0 {
                r.radius += (r.maxRadius - r.radius) * 0.22 * dt
                r.alpha -= 0.06 * dt
                if r.alpha <= 0 || r.maxRadius - r.radius < 1 { r.active = false }
            } else {
                r.radius += r.grow * dt
                r.alpha -= 0.04 * dt
                if r.alpha <= 0 { r.active = false }
            }
        }
    }

    func appendParticleSprites(into geometry: inout PicFrameGeometry) {
        for p in particles where p.active {
            var alpha: Float
            var drawSize = p.size
            if p.orbital {
                // .kt：t=(1-radius/spawnRadius)；越接近核心越亮、略縮小
                let t = clamp(1 - p.orbRadiusPx / max(p.orbSpawnRadiusPx, 1e-3), 0, 1)
                alpha = (0.3 + 0.7 * t) * 0.9
                drawSize = p.size * (1 - 0.4 * t)
            } else if p.maxLife > 0 {
                alpha = (1 - p.life / p.maxLife) * 0.9
            } else {
                alpha = clamp(p.alpha, 0, 1)
            }
            guard alpha > 0.004 else { continue }
            let cx = ndcXToPixel(p.x), cy = ndcYToPixel(p.y)
            let color = SIMD4(p.r, p.g, p.b, alpha)

            if p.vcount >= 3 {
                appendPolygon(cx: cx, cy: cy, p: p, color: color, into: &geometry)
            } else if p.streak {
                appendStreak(cx: cx, cy: cy, p: p, color: color, into: &geometry)
            } else {
                let w: Float
                let h: Float
                if p.style == .coin {
                    let flipS = 0.18 + 0.82 * abs(cos(p.flip))
                    w = drawSize * flipS; h = drawSize
                } else {
                    w = drawSize; h = drawSize * p.aspect
                }
                appendSprite(
                    center: SIMD2(cx, cy),
                    size: SIMD2(w, h),
                    color: color,
                    style: p.style, rotation: p.angle, seed: p.seed,
                    age: p.maxLife > 0 ? (p.life / p.maxLife) : (1 - p.alpha),
                    into: &geometry)
            }
        }
    }

    /// 多邊形粒子：以 ribbon 三角輸出？不行——ribbon 是三角帶。改用 sprite buffer 直接堆三角。
    /// 用 spriteVertices 放置三角扇（每個三角 3 頂點），style 設為 .softCircle 並讓 corner 落在頂點，
    /// 但 sprite shader 以 corner 當 local 座標算 mask，不適合任意多邊形。
    /// 因此多邊形改走 ribbon buffer 的「實心三角」路徑：用一個極小 helper 直接 append 三角到 sprite。
    fileprivate func appendPolygon(cx: Float, cy: Float, p: Particle,
                                   color: SIMD4<Float>, into geometry: inout PicFrameGeometry) {
        let ca = cos(p.angle), sa = sin(p.angle)
        func vert(_ j: Int) -> SIMD2<Float> {
            let rx = p.ox[j] * ca - p.oy[j] * sa
            let ry = p.ox[j] * sa + p.oy[j] * ca
            return SIMD2(cx + rx, cy + ry)
        }
        let v0 = vert(0)
        // 三角扇 (0, j, j+1)，以 solidTriangle sprite 樣式輸出（mask 恆為 1）。
        for j in 1..<(p.vcount - 1) {
            let va = vert(j), vb = vert(j + 1)
            appendSolidTri(v0, va, vb, color: color, into: &geometry)
        }
    }

    /// streak：沿速度方向拉成細長四邊形（兩個三角）。
    fileprivate func appendStreak(cx: Float, cy: Float, p: Particle,
                                  color: SIMD4<Float>, into geometry: inout PicFrameGeometry) {
        let speed = max(sqrt(p.vx * p.vx + p.vy * p.vy), 1e-3)
        // 速度在像素空間方向（NDC vy 向上 → 像素 y 向下要反號）
        let dirX = p.vx / speed
        let dirY = -p.vy / speed
        let lenPx = speed * 2.6 + 3
        let hw = p.streakHalfPx
        let ex = cx + dirX * lenPx, ey = cy + dirY * lenPx
        let nx = -dirY * hw, ny = dirX * hw
        let tailColor = SIMD4(color.x, color.y, color.z, color.w * 0.30)
        appendSolidTriC(SIMD2(cx - nx, cy - ny), color,
                        SIMD2(cx + nx, cy + ny), color,
                        SIMD2(ex - nx, ey - ny), tailColor, into: &geometry)
        appendSolidTriC(SIMD2(cx + nx, cy + ny), color,
                        SIMD2(ex + nx, ey + ny), tailColor,
                        SIMD2(ex - nx, ey - ny), tailColor, into: &geometry)
    }

    /// 實心三角（單色）→ sprite buffer，style=.solidTri（shader mask 恆 1）。
    fileprivate func appendSolidTri(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
                                    color: SIMD4<Float>, into geometry: inout PicFrameGeometry) {
        appendSolidTriC(a, color, b, color, c, color, into: &geometry)
    }

    /// 實心三角（逐頂點色，供 streak 漸層）。
    fileprivate func appendSolidTriC(_ a: SIMD2<Float>, _ ca: SIMD4<Float>,
                                     _ b: SIMD2<Float>, _ cb: SIMD4<Float>,
                                     _ c: SIMD2<Float>, _ cc: SIMD4<Float>,
                                     into geometry: inout PicFrameGeometry) {
        let s = PicSpriteStyle.solidTri.rawValue
        // corner 不參與形狀（shader solidTri mask=1），但仍需給值；size 設 1 避免 0。
        geometry.spriteVertices.append(PicSpriteVertex(center: a, corner: SIMD2(0, 0),
            size: SIMD2(1, 1), color: ca, rotation: 0, style: s, seed: 0, age: 0))
        geometry.spriteVertices.append(PicSpriteVertex(center: b, corner: SIMD2(0, 0),
            size: SIMD2(1, 1), color: cb, rotation: 0, style: s, seed: 0, age: 0))
        geometry.spriteVertices.append(PicSpriteVertex(center: c, corner: SIMD2(0, 0),
            size: SIMD2(1, 1), color: cc, rotation: 0, style: s, seed: 0, age: 0))
    }

    func appendRippleSprites(into geometry: inout PicFrameGeometry, width: Float, height: Float) {
        for r in ripples where r.active {
            let diameter = r.radius * 2 / 0.72   // ring mask 落在 0.72 半徑
            appendSprite(
                center: SIMD2(ndcXToPixel(r.x), ndcYToPixel(r.y)),
                size: SIMD2(diameter, diameter),
                color: SIMD4(r.r, r.g, r.b, clamp(r.alpha, 0, 1)),
                style: r.style, rotation: 0, seed: 0,
                age: clamp(r.radius / max(r.maxRadius, r.radius + 1), 0, 1),
                into: &geometry)
        }
    }
}

// MARK: - 數學 / 色彩工具
extension PicTrailSceneBuilder {

    func unit(_ angle: Float) -> SIMD2<Float> { SIMD2(cos(angle), sin(angle)) }

    func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    /// 確定性 hash（對應 Android per-(track,index) 亂數，讓拖尾本身的點分佈穩定）。
    func random01(_ a: Int, _ b: Int) -> Float {
        var value = UInt32(truncatingIfNeeded: a) &* 747_796_405
            &+ UInt32(truncatingIfNeeded: b) &* 2_891_336_453 &+ 2_772_803_943
        value = (value ^ (value >> 16)) &* 2_246_822_519
        value = (value ^ (value >> 13)) &* 3_266_489_917
        value ^= value >> 16
        return Float(value & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    /// 粒子物理用的真隨機（對應 Android Math.random()）。
    func rnd() -> Float { Float.random(in: 0..<1) }

    func rgba(_ color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 1
            color.getWhite(&w, alpha: &a); r = w; g = w; b = w
        }
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }

    func withAlpha(_ c: SIMD4<Float>, _ a: Float) -> SIMD4<Float> {
        var o = c; o.w = clamp(a, 0, 1); return o
    }

    func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        let amt = clamp(t, 0, 1); return a + (b - a) * amt
    }


    /// 提飽和 + 提亮（對應 Android saturate()：HSV S≥0.85, V=1）。
    func saturated(_ c: SIMD4<Float>) -> SIMD4<Float> {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            .getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        s = max(s, 0.85); v = 1
        let out = UIColor(hue: h, saturation: s, brightness: v, alpha: 1)
        var rr = rgba(out); rr.w = c.w; return rr
    }

    /// 色相位移（對應 Android hueShift，給雙股刀身第二股用）。
    func hueShifted(_ c: SIMD4<Float>, _ deg: Float) -> SIMD4<Float> {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            .getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        h = CGFloat((Float(h) * 360 + deg + 360).truncatingRemainder(dividingBy: 360) / 360)
        let out = UIColor(hue: h, saturation: max(s, 0.85), brightness: 1, alpha: 1)
        var rr = rgba(out); rr.w = c.w; return rr
    }

    /// 鮮豔化（對應 SprayPaint vivid()：lum 為軸拉飽和 ×1.7、再正規化）。
    func vivid(_ c: SIMD4<Float>, lightJitter: Float = 0) -> SIMD4<Float> {
        var r = c.x, g = c.y, b = c.z
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let sat: Float = 1.35
        r = lum + (r - lum) * sat
        g = lum + (g - lum) * sat
        b = lum + (b - lum) * sat
        let m = max(r, max(g, b))
        if m > 1e-4 { let s = min(1 / m, 1.5); r *= s; g *= s; b *= s }
        let lj = 1 + lightJitter
        return SIMD4(clamp(r * lj, 0, 1), clamp(g * lj, 0, 1), clamp(b * lj, 0, 1), c.w)
    }

    func lift(_ c: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        // 往白提亮 t（對應 Android cr*0.x + 0.y 之類）
        SIMD4(c.x + (1 - c.x) * t, c.y + (1 - c.y) * t, c.z + (1 - c.z) * t, c.w)
    }

    func darken(_ c: SIMD4<Float>, _ k: Float) -> SIMD4<Float> {
        SIMD4(c.x * k, c.y * k, c.z * k, c.w)
    }

    // MARK: Debug bounding boxes（沿用原行為）

    func appendDebugBoxes(
        _ boxes: [(CGRect, Int)], width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        let green = SIMD4<Float>(0.1, 1, 0.2, 1)
        for (rect, trackID) in boxes {
            let minX = Float(rect.minX) * width, minY = Float(rect.minY) * height
            let maxX = Float(rect.maxX) * width, maxY = Float(rect.maxY) * height
            let pts = [SIMD2(minX, minY), SIMD2(maxX, minY), SIMD2(maxX, maxY),
                       SIMD2(minX, maxY), SIMD2(minX, minY)]
            appendRibbon(positions: pts, alphas: [1, 1, 1, 1, 1],
                         halfWidthPx: 2, color: green, style: .generic, alphaScale: 0.95,
                         widthTailBias: 1, widthHeadBias: 0, seedBase: Float(trackID),
                         into: &geometry)
        }
    }
}

// MARK: - 特效：通用 spawn 節流輔助
extension PicTrailSceneBuilder {

    /// 取頭部與前一點，回傳 (head像素, prev像素, 位移量NDC, 速度moveNorm)。
    /// moveNorm 已正規化到 30fps 基準（= moveLen / dtScale）。
    fileprivate func headMotion(_ s: [Sample], dtScale: Float) -> (head: SIMD2<Float>, prev: SIMD2<Float>, moveNDC: Float, moveNorm: Float) {
        let head = s[s.count - 1].position
        let prev = s[s.count - 2].position
        let dNDCx = pixelToNDCx(head.x) - pixelToNDCx(prev.x)
        let dNDCy = pixelToNDCy(head.y) - pixelToNDCy(prev.y)
        let moveLen = sqrt(dNDCx * dNDCx + dNDCy * dNDCy)
        return (head, prev, moveLen, moveLen / max(dtScale, 0.0001))
    }

    /// 節流：距離上次 spawn 頭部超過 threshold(NDC) 才回傳 true 並更新。
    fileprivate func throttle(_ trackID: Int, head: SIMD2<Float>, threshold: Float) -> Bool {
        let hNDC = SIMD2(pixelToNDCx(head.x), pixelToNDCy(head.y))
        if let last = lastHeadPosition[trackID] {
            let d = simd_length(hNDC - last)
            if d <= threshold { return false }
        }
        lastHeadPosition[trackID] = hNDC
        return true
    }
}

// MARK: - 滔天浪潮 Wave
extension PicTrailSceneBuilder {

    fileprivate func buildWave(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        let base = headColor(samples)                 // 陀螺色驅動水體
        let positions = samples.map { $0.position }
        let alphas = samples.map { $0.alpha }

        // 流體本體：寬 glow + 主帶 + 白沫核（對齊 Android 三層）
        appendRibbon(positions: positions, alphas: alphas,
                     halfWidthPx: ndcToPixels(0.031, minDim: minDim) * 2,
                     color: base, style: .wave, alphaScale: 0.40,
                     trailReversed: true, seedBase: Float(trackID), into: &geometry)
        appendRibbon(positions: positions, alphas: alphas,
                     halfWidthPx: ndcToPixels(0.031, minDim: minDim),
                     color: base, style: .wave, alphaScale: 0.78,
                     trailReversed: true, seedBase: Float(trackID) * 0.7, into: &geometry)

        // ── 側噴 + 微泡 + 漣漪（NDC/幀 速度，完全對齊 WaveGLEffect.kt）──
        guard samples.count >= 2 else { return }
        // .kt：dx,dy 為 NDC 差；perpX=-dy/len, perpY=dx/len（NDC 空間，y 向上）
        let headNDC = SIMD2(pixelToNDCx(samples[samples.count - 1].position.x),
                            pixelToNDCy(samples[samples.count - 1].position.y))
        let prevNDC = SIMD2(pixelToNDCx(samples[samples.count - 2].position.x),
                            pixelToNDCy(samples[samples.count - 2].position.y))
        let dxN = headNDC.x - prevNDC.x, dyN = headNDC.y - prevNDC.y
        let moveLen = max(sqrt(dxN * dxN + dyN * dyN), 1e-5)
        let perpX = -dyN / moveLen, perpY = dxN / moveLen
        let moveNorm = moveLen / max(dtScale, 1e-4)

        if waveThrottle(trackID, headNDC: headNDC, threshold: 0.008) && rnd() > 0.3 {
            if moveNorm > 0.015 && rnd() > 0.5 {
                spawnRipple { r in
                    r.x = headNDC.x; r.y = headNDC.y
                    r.maxRadius = 0; r.radius = 0; r.grow = 5; r.alpha = 0.85
                    r.r = 0.749; r.g = 0.906; r.b = 1; r.style = .ring
                }
            }
            for k in 0..<3 {
                let sideSign: Float = (k % 2 == 0) ? 1 : -1
                let strength = clamp(moveNorm * 1.5, 0.02, 0.045)
                spawnParticle { p in
                    p.x = headNDC.x; p.y = headNDC.y
                    p.ndcVelocity = true
                    p.vx = perpX * sideSign * strength + (rnd() - 0.5) * 0.018
                    p.vy = perpY * sideSign * strength + (rnd() - 0.5) * 0.018 - 0.012
                    p.gravity = -0.001   // update: vy -= gravity → vy += 0.001（.kt）
                    p.size = rnd() * 8 + 6
                    p.decay = 0.06; p.style = .softCircle
                    let blue = rnd() > 0.3
                    p.r = blue ? 0.749 : 1; p.g = blue ? 0.906 : 1; p.b = 1
                }
            }
            if samples.count > 4 && rnd() > 0.6 {
                let b = samples[samples.count / 3].position
                spawnParticle { p in
                    p.x = pixelToNDCx(b.x) + (rnd() - 0.5) * 0.02
                    p.y = pixelToNDCy(b.y) + (rnd() - 0.5) * 0.02
                    p.ndcVelocity = true
                    p.vx = (rnd() - 0.5) * 0.006
                    p.vy = -(rnd() * 0.012 + 0.005)
                    p.size = rnd() * 4 + 2
                    p.decay = 0.06; p.style = .softCircle
                    p.r = 0.749; p.g = 0.906; p.b = 1; p.alpha = 0.6
                }
            }
        }
    }

    /// Wave 專用節流（以 NDC 頭部位置判定，對齊 .kt lastPos 邏輯）。
    private func waveThrottle(_ trackID: Int, headNDC: SIMD2<Float>, threshold: Float) -> Bool {
        if let last = lastHeadPosition[trackID] {
            let d = simd_length(headNDC - last)
            if d <= threshold { return false }
        }
        lastHeadPosition[trackID] = headNDC
        return true
    }
}

// MARK: - 紅蓮破滅 CrimsonLotus
extension PicTrailSceneBuilder {

    fileprivate func buildCrimson(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        let base = headColor(samples)
        guard samples.count >= 3 else {
            // 點太少時仍畫單層，避免空窗
            appendRibbon(positions: samples.map { $0.position }, alphas: samples.map { $0.alpha },
                         halfWidthPx: ndcToPixels(0.034, minDim: minDim), color: base,
                         style: .crimson, alphaScale: 0.7, trailReversed: true, into: &geometry)
            return
        }

        // ×3 重採樣的蛇形雙股火舌（對齊 .kt）
        let rs = resample(samples, factor: 3, cap: 64)
        let pos = rs.pos, alp = rs.alpha
        let m = pos.count
        let TWIST_FREQ: Float = 2.4, SERPENT_AMP = ndcToPixels(0.024, minDim: minDim)
        let WRIGGLE_SPEED: Float = 8.5
        let tongueHW = ndcToPixels(0.034, minDim: minDim)

        for strand in 0..<2 {
            let phase = Float(strand) * Float.pi
            let wMult: Float = strand == 0 ? 1 : 0.62
            let aMult: Float = strand == 0 ? 1 : 0.7
            let offset: (Int, Float, SIMD2<Float>) -> SIMD2<Float> = { [self] j, life, normal in
                let u = Float(j) / Float(m - 1)
                let wave = sin(u * TWIST_FREQ * 2 * Float.pi + phase - now * WRIGGLE_SPEED)
                return normal * (wave * SERPENT_AMP * (1 - u))
            }
            appendRibbon(positions: pos, alphas: alp,
                         halfWidthPx: tongueHW * wMult,
                         color: base, style: .crimson, alphaScale: aMult,
                         widthTailBias: 0.30, widthHeadBias: 0.70,
                         centerlineOffset: offset, trailReversed: true,
                         seedBase: Float(trackID) + phase, into: &geometry)
        }

        // ── 餘燼火星（對齊 .kt：rand<0.55*dt）──
        if samples.count >= 4 && rnd() < 0.55 * dtScale {
            let idx = min(Int(rnd() * Float(samples.count) * 0.6), samples.count - 1)
            let e = samples[idx].position
            spawnEmber(at: e, base: base)
        }

        // ── 火球（對齊 .kt：small rand>0.4、big 3×）──
        let mo = headMotion(samples, dtScale: dtScale)
        if throttle(trackID, head: mo.head, threshold: 0.006) {
            if mo.moveNorm > 0.010 && rnd() > 0.4 {
                spawnFireball(at: mo.head, minDim: minDim, big: false, base: base)
            }
            if mo.moveNorm > 0.016 {
                for _ in 0..<3 { spawnFireball(at: mo.head, minDim: minDim, big: true, base: base) }
            }
        }
    }

    private func spawnEmber(at headPx: SIMD2<Float>, base: SIMD4<Float>) {
        spawnParticle { [self] p in
            p.x = pixelToNDCx(headPx.x) + (rnd() - 0.5) * 0.02
            p.y = pixelToNDCy(headPx.y) + (rnd() - 0.5) * 0.02
            p.vx = (rnd() - 0.5) * 3
            p.vy = 1.5 + rnd() * 2.5            // 熱氣上飄（NDC y up）
            p.size = 2 + rnd() * 2.5
            p.decay = 0.045 + rnd() * 0.04
            p.style = .softCircle
            let pick = Int(rnd() * 5)
            let c: SIMD4<Float>
            switch pick {
            case 0, 1: c = base
            case 2, 3: c = lift(base, 0.6)
            default:   c = darken(base, 0.7)
            }
            p.r = c.x; p.g = c.y; p.b = c.z
        }
    }

    private func spawnFireball(at headPx: SIMD2<Float>, minDim: Float, big: Bool, base: SIMD4<Float>) {
        spawnParticle { [self] p in
            let angle = rnd() * 2 * Float.pi
            let speed: Float = big ? 8 + rnd() * 8 : 4 + rnd() * 5
            p.x = pixelToNDCx(headPx.x) + (rnd() - 0.5) * 0.015
            p.y = pixelToNDCy(headPx.y) + (rnd() - 0.5) * 0.015
            p.vx = cos(angle) * speed
            p.vy = sin(angle) * speed
            p.drag = 0.06
            p.grow = big ? 0.17 : 0.12
            p.decay = 0.08 + rnd() * 0.04
            p.size = big ? minDim * (0.012 + rnd() * 0.008) : minDim * (0.006 + rnd() * 0.004)
            p.style = .fireball
            let pick = Int(rnd() * 3)
            let c: SIMD4<Float>
            switch pick {
            case 0: c = darken(base, 0.60)
            case 1: c = base
            default: c = lift(base, 0.5)
            }
            p.r = c.x; p.g = c.y; p.b = c.z
        }
    }
}

// MARK: - 爆刃亂舞 Blade
extension PicTrailSceneBuilder {

    fileprivate func buildBlade(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 3 else { return }
        let base = saturated(headColor(samples))
        // 依影片：雙股同為陀螺色，第二股僅略提亮做出層次，不做色相位移。
        let twin = lift(base, 0.2)

        // 雙股 willow-leaf helix（×3 重採樣）
        let rs = resample(samples, factor: 3, cap: 64)
        let pos = rs.pos, alp = rs.alpha
        let m = pos.count
        let HELIX_TURNS: Float = 2.2
        let HELIX_AMP = ndcToPixels(0.016, minDim: minDim)
        let strandHW = ndcToPixels(0.012, minDim: minDim)

        for strand in 0..<2 {
            let c = strand == 0 ? base : twin
            let phase0 = Float(strand) * Float.pi
            // 葉形包絡：envelope=sin(πu)，半寬隨 envelope；helix 沿法線偏移
            // 自訂 alpha（梯度 + sqrt 引擎淡出）與半寬，需用低階逐點寫入。
            var positions: [SIMD2<Float>] = []
            var alphas: [Float] = []
            var halfWidths: [Float] = []
            var colors: [SIMD4<Float>] = []
            positions.reserveCapacity(m); alphas.reserveCapacity(m)
            halfWidths.reserveCapacity(m); colors.reserveCapacity(m)
            for j in 0..<m {
                let u = Float(j) / Float(m - 1)
                let env = sin(Float.pi * u)
                let off = sin(u * HELIX_TURNS * 2 * Float.pi + phase0) * HELIX_AMP * env
                let normal = averagedNormal(pos, index: j)
                positions.append(pos[j] + normal * off)
                halfWidths.append(strandHW * env)
                // 梯度 alpha
                let aT: Float = u < 0.3 ? u / 0.3 * 0.5
                    : (u < 0.8 ? 0.5 + (u - 0.3) / 0.5 * 0.45 : 0.95 + (u - 0.8) / 0.2 * 0.05)
                alphas.append(aT * sqrt(max(alp[j], 0)))
                // 本體→白刃口（前 25%）
                let wMix = clamp((u - 0.75) / 0.25, 0, 1)
                colors.append(lift(c, wMix))
            }
            appendBladeStrand(positions: positions, alphas: alphas, halfWidths: halfWidths,
                              colors: colors, seedBase: Float(trackID) + phase0, into: &geometry)
        }

        // ── 火花 / 刀光 / 劍氣（跨幀粒子）──
        let mo = headMotion(samples, dtScale: dtScale)
        if throttle(trackID, head: mo.head, threshold: 0.005) {
            if mo.moveNorm > 0.009 { emitBladeBody(samples, minDim: minDim) }
            if mo.moveNorm > 0.013 {
                let dx = pixelToNDCx(mo.head.x) - pixelToNDCx(mo.prev.x)
                let dy = pixelToNDCy(mo.head.y) - pixelToNDCy(mo.prev.y)
                let vxPx = dx * vwHalf / max(dtScale, 1e-4)
                let vyPx = dy * vhHalf / max(dtScale, 1e-4)
                if rnd() > 0.3 { spawnBladeSpark(at: mo.head, vxPx: vxPx, vyPx: vyPx) }
                if rnd() > 0.5 { spawnBladeSpark(at: mo.head, vxPx: vxPx, vyPx: vyPx) }
                if rnd() > 0.55 {
                    let ang = atan2(dy, dx)
                    spawnSwordQi(at: mo.head, angle: ang, moveNorm: mo.moveNorm, minDim: minDim,
                                 base: base)
                }
            }
        }
    }

    /// 葉形雙股需要逐點半寬與顏色，獨立寫入 ribbon。
    private func appendBladeStrand(
        positions: [SIMD2<Float>], alphas: [Float], halfWidths: [Float],
        colors: [SIMD4<Float>], seedBase: Float, into geometry: inout PicFrameGeometry
    ) {
        let count = positions.count
        guard count >= 2 else { return }
        var cumulative = [Float](repeating: 0, count: count)
        for i in 1..<count { cumulative[i] = cumulative[i - 1] + simd_length(positions[i] - positions[i - 1]) }
        let total = max(cumulative.last ?? 1, 1)
        let start = geometry.ribbonVertices.count
        for i in 0..<count {
            let normal = averagedNormal(positions, index: i)
            var c = colors[i]; c.w *= alphas[i]
            let hw = halfWidths[i]
            let trailT = cumulative[i] / total
            let seed = seedBase + Float(i) * 0.013
            geometry.ribbonVertices.append(
                PicRibbonVertex(position: positions[i] - normal * hw, color: c,
                                uv: SIMD2(-1, trailT), style: PicRibbonStyle.blade.rawValue, seed: seed))
            geometry.ribbonVertices.append(
                PicRibbonVertex(position: positions[i] + normal * hw, color: c,
                                uv: SIMD2(1, trailT), style: PicRibbonStyle.blade.rawValue, seed: seed))
        }
        geometry.ribbonRanges.append(PicDrawRange(start: start, count: geometry.ribbonVertices.count - start))
    }

    private func emitBladeBody(_ samples: [Sample], minDim: Float) {
        let n = samples.count
        guard n >= 3 else { return }
        let idx = 1 + min(Int(rnd() * Float(n - 2)), n - 3)
        let b = samples[idx].position
        let tpP = samples[idx - 1].position, tpN = samples[idx + 1].position
        let dir = tpN - tpP
        let len = max(simd_length(dir), 1e-3)
        let perpPx = SIMD2(-dir.y, dir.x) / len
        let perpNDC = simd_normalize(SIMD2(perpPx.x, -perpPx.y))
        var count = rnd() > 0.5 ? 2 : 1
        while count > 0 {
            count -= 1
            let side: Float = rnd() > 0.5 ? 1 : -1
            let burst = rnd() * 5 + 3
            spawnParticle { [self] p in
                p.x = pixelToNDCx(b.x); p.y = pixelToNDCy(b.y)
                p.vx = perpNDC.x * side * burst + (rnd() - 0.5) * 3
                p.vy = perpNDC.y * side * burst + (rnd() - 0.5) * 3
                p.drag = 0.08; p.decay = 0.12; p.size = 6
                p.style = .spark
                if rnd() > 0.4 { p.r = 0.88; p.g = 0.95; p.b = 1.0 }
                else { p.r = 1.0; p.g = 0.94; p.b = 0.54 }
            }
        }
        if rnd() > 0.45 {
            spawnParticle { [self] p in
                p.x = pixelToNDCx(b.x) + (rnd() - 0.5) * 0.015
                p.y = pixelToNDCy(b.y) + (rnd() - 0.5) * 0.015
                p.angle = rnd() * Float.pi
                p.size = minDim * (0.008 + rnd() * 0.008)
                p.style = .spark; p.maxLife = 6; p.life = 0
                p.r = 0.95; p.g = 0.98; p.b = 1.0
            }
        }
    }

    private func spawnBladeSpark(at headPx: SIMD2<Float>, vxPx: Float, vyPx: Float) {
        spawnParticle { [self] p in
            p.x = pixelToNDCx(headPx.x); p.y = pixelToNDCy(headPx.y)
            p.vx = vxPx * 0.4 + (rnd() - 0.5) * 10
            p.vy = -(vyPx * 0.4 + (rnd() - 0.5) * 10)   // 像素 y 向下→NDC y 向上要反號
            p.drag = 0.08; p.decay = 0.12
            p.streak = true; p.streakHalfPx = 1.5 + rnd() * 1.5
            if rnd() > 0.4 { p.r = 0.88; p.g = 0.95; p.b = 1.0 }
            else { p.r = 1.0; p.g = 0.94; p.b = 0.54 }
        }
    }

    private func spawnSwordQi(at headPx: SIMD2<Float>, angle: Float, moveNorm: Float,
                              minDim: Float, base: SIMD4<Float>) {
        // 以放大火環近似 crescent（ring sprite），顏色取陀螺色提亮
        spawnRipple { [self] r in
            let speedPx = 10 + rnd() * 6 + moveNorm * minDim * 0.15
            r.x = pixelToNDCx(headPx.x); r.y = pixelToNDCy(headPx.y)
            r.maxRadius = 0
            r.radius = minDim * (0.035 + rnd() * 0.020)
            r.grow = speedPx * 0.12
            r.alpha = 0.95
            let lit = lift(base, 0.25)
            r.r = lit.x; r.g = lit.y; r.b = lit.z
            r.style = .ring
        }
    }
}

// MARK: - 狂暴冰裂 IceShatter
extension PicTrailSceneBuilder {

    fileprivate func buildIce(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        let base = headColor(samples)
        let positions = samples.map { $0.position }
        let alphas = samples.map { $0.alpha }
        // 冰刃拖尾：銳利刃口（單層，shader case 7 ice 處理鏡面流光）
        appendRibbon(positions: positions, alphas: alphas,
                     halfWidthPx: ndcToPixels(0.028, minDim: minDim),
                     color: base, style: .ice, alphaScale: 0.95,
                     widthTailBias: 0.22, widthHeadBias: 0.78,
                     trailReversed: false, seedBase: Float(trackID), into: &geometry)

        guard samples.count >= 2 else { return }
        // ── 碎片暴衝（只在移動時，量克制）──
        let mo = headMotion(samples, dtScale: dtScale)
        if throttle(trackID, head: mo.head, threshold: 0.007) && mo.moveNorm > 0.008 {
            let chance: Float = mo.moveNorm > 0.018 ? 0.85 : 0.5
            if rnd() < chance { spawnIceShards(samples, moveNorm: mo.moveNorm, minDim: minDim, base: base, width: width, height: height) }
        }
        // ── 冰霜結霜（稀疏，且僅在移動時）+ 中心白霧（很淡，偶爾）──
        if samples.count >= 3 && mo.moveNorm > 0.006 {
            if rnd() < 0.6 * dtScale {
                let idx = min(Int(rnd() * Float(samples.count)), samples.count - 1)
                let f = samples[idx].position
                spawnParticle { [self] p in
                    p.x = pixelToNDCx(f.x) + (rnd() - 0.5) * 0.04
                    p.y = pixelToNDCy(f.y) + (rnd() - 0.5) * 0.04
                    p.size = minDim * (0.004 + rnd() * 0.005)
                    p.alpha = 0.6 + rnd() * 0.3; p.decay = 0.02 + rnd() * 0.015
                    p.style = .star
                    if rnd() > 0.3 {
                        p.r = 0.73 * 0.6 + base.x * 0.4
                        p.g = 0.90 * 0.6 + base.y * 0.4
                        p.b = 1.0
                    } else { p.r = 1; p.g = 1; p.b = 1 }
                }
            }
            if rnd() < 0.3 * dtScale {
                let h = samples[samples.count - 1].position
                spawnParticle { [self] p in
                    p.x = pixelToNDCx(h.x) + (rnd() - 0.5) * 0.03
                    p.y = pixelToNDCy(h.y) + (rnd() - 0.5) * 0.03
                    p.vx = (rnd() - 0.5) * 1.0
                    p.vy = 0.6 + rnd() * 1.0
                    p.size = minDim * (0.04 + rnd() * 0.03)
                    p.grow = 0.014; p.alpha = 0.12; p.decay = 0.006
                    p.style = .haze
                    p.r = 1; p.g = 1; p.b = 1
                }
            }
        }
    }

    private func spawnIceShards(_ samples: [Sample], moveNorm: Float, minDim: Float, base: SIMD4<Float>,
                                width: Float, height: Float) {
        let n = samples.count
        let idx = min(max(Int(rnd() * Float(n - 1)), 0), n - 2)
        let e = samples[idx].position, t = samples[idx + 1].position
        // .kt：segAngle = atan2((ty-ey)*vh, (tx-ex)*vw)，像素空間（注意 iOS y 向下）
        let exN = pixelToNDCx(e.x), eyN = pixelToNDCy(e.y)
        let txN = pixelToNDCx(t.x), tyN = pixelToNDCy(t.y)
        let segAngle = atan2((tyN - eyN) * height, (txN - exN) * width)
        let speedPx = moveNorm * minDim * 0.5
        let halfPi = Float.pi / 2
        var spawned = 0
        let burst = 6   // 對齊 .kt
        for _ in 0..<burst {
            let side: Float = rnd() > 0.5 ? 1 : -1
            let pAngle = segAngle + side * halfPi + (rnd() - 0.5) * 0.8
            let expSpeed = rnd() * 6 + speedPx * 0.4
            let isBig = rnd() > 0.4
            let basePx = isBig ? minDim * (0.013 + rnd() * 0.008)
                               : minDim * (0.005 + rnd() * 0.003)
            let vc = 3 + min(Int(rnd() * 3), 2)   // 3–5
            spawnParticle { [self] p in
                p.x = exN; p.y = eyN
                p.vx = cos(pAngle) * expSpeed
                p.vy = sin(pAngle) * expSpeed + 1.2
                p.angle = rnd() * 2 * Float.pi
                p.spin = (rnd() - 0.5) * 1.2
                p.gravity = 0.65; p.decay = 0.12 + rnd() * 0.05
                // 多邊形頂點
                p.vcount = vc
                for j in 0..<vc {
                    let ang = 2 * Float.pi * Float(j) / Float(vc)
                    let rad = basePx * (rnd() * 0.9 + 0.3)
                    p.ox[j] = cos(ang) * rad
                    p.oy[j] = sin(ang) * rad
                }
                if rnd() > 0.3 {
                    p.r = 0.73 * 0.7 + base.x * 0.3
                    p.g = 0.90 * 0.7 + base.y * 0.3
                    p.b = 1.0
                } else { p.r = 1; p.g = 1; p.b = 1 }
            }
            spawned += 1
            if spawned >= burst { break }
        }
    }
}

// MARK: - 金錢衝擊 Money（依影片：固定金色 $ 錢幣，不跟陀螺色）
extension PicTrailSceneBuilder {

    fileprivate func buildMoney(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        // 依影片：Money 為固定金色 $ 錢幣 + 金色拖尾，不跟陀螺色。
        let gold = SIMD4<Float>(1.0, 0.84, 0.30, 1)
        let positions = samples.map { $0.position }
        let alphas = samples.map { $0.alpha }
        // 金色尾流（shader case 5 money 給金屬光澤），固定金色
        appendRibbon(positions: positions, alphas: alphas,
                     halfWidthPx: ndcToPixels(0.020, minDim: minDim),
                     color: gold, style: .money, alphaScale: 0.90,
                     widthTailBias: 0.3, widthHeadBias: 0.7, seedBase: Float(trackID),
                     into: &geometry)

        guard samples.count >= 2 else { return }
        let mo = headMotion(samples, dtScale: dtScale)
        let dx = pixelToNDCx(mo.head.x) - pixelToNDCx(mo.prev.x)
        let dy = pixelToNDCy(mo.head.y) - pixelToNDCy(mo.prev.y)
        let moveAngle = atan2(dy, dx)
        if throttle(trackID, head: mo.head, threshold: 0.006) {
            if mo.moveNorm > 0.008 {
                let cnt = 1 + min(Int(mo.moveNorm * 70), 2)
                let speed = minDim * (0.006 + mo.moveNorm * 0.35)
                for _ in 0..<cnt {
                    spawnCoin(at: mo.head, angle: moveAngle + Float.pi + (rnd() - 0.5) * 0.6,
                              speedPx: speed * (0.7 + rnd() * 0.4), minDim: minDim)
                }
                if rnd() > 0.4 { spawnGoldSpark(at: mo.head, angle: moveAngle + Float.pi, cone: 0.4, count: 1) }
            }
            if mo.moveNorm > 0.018 {
                let back = moveAngle + Float.pi
                let burst = 3 + Int(rnd() * 3)
                for _ in 0..<burst {
                    spawnCoin(at: mo.head, angle: back + (rnd() - 0.5) * 1.4,
                              speedPx: minDim * (0.008 + rnd() * 0.012), minDim: minDim)
                }
                spawnRipple { [self] r in
                    r.x = pixelToNDCx(mo.head.x); r.y = pixelToNDCy(mo.head.y)
                    r.radius = minDim * 0.010
                    r.maxRadius = min(minDim * (0.035 + mo.moveNorm * 0.4), minDim * 0.065)
                    r.alpha = 0.7
                    r.r = 1.0; r.g = 0.88; r.b = 0.4; r.style = .ring   // 金色衝擊環
                }
                spawnGoldSpark(at: mo.head, angle: back, cone: 0.7, count: 3)
            }
        }
    }

    private func spawnCoin(at headPx: SIMD2<Float>, angle: Float, speedPx: Float, minDim: Float) {
        spawnParticle { [self] p in
            p.x = pixelToNDCx(headPx.x); p.y = pixelToNDCy(headPx.y)
            p.vx = cos(angle) * speedPx
            p.vy = sin(angle) * speedPx + minDim * 0.006
            p.angle = rnd() * 2 * Float.pi
            p.spin = (rnd() - 0.5) * 0.5            // angVel
            p.flip = rnd() * 2 * Float.pi
            p.flipVel = 0.25 + rnd() * 0.4          // 立體翻面
            p.gravity = 0.6; p.drag = 0.02
            p.decay = 0.045 + rnd() * 0.035
            p.size = minDim * (0.020 + rnd() * 0.016)   // 直徑（draw 時 *0.5 取半徑）
            p.style = .coin
            // 對齊 .kt：金色為主，少數亮金 / 深銅
            switch Int(rnd() * 4) {
            case 0: p.r = 1.0; p.g = 0.90; p.b = 0.35   // 亮金
            case 3: p.r = 0.85; p.g = 0.60; p.b = 0.10  // 深銅
            default: p.r = 1.0; p.g = 0.82; p.b = 0.12  // 金（GOLD）
            }
        }
    }

    private func spawnGoldSpark(at headPx: SIMD2<Float>, angle: Float, cone: Float, count: Int) {
        var spawned = 0
        for _ in 0..<count {
            spawnParticle { [self] p in
                let pAngle = angle + (rnd() - 0.5) * 2 * cone
                let speedPx = 8 + rnd() * 20
                p.x = pixelToNDCx(headPx.x); p.y = pixelToNDCy(headPx.y)
                p.vx = cos(pAngle) * speedPx
                p.vy = sin(pAngle) * speedPx
                p.drag = 0.08; p.decay = 0.07 + rnd() * 0.06
                p.streak = true                       // 拉長條狀（對齊 .kt streak）
                p.streakHalfPx = 1.4 + rnd() * 1.8
                if rnd() > 0.4 { p.r = 1; p.g = 0.95; p.b = 0.6 } else { p.r = 1; p.g = 1; p.b = 1 }
            }
            spawned += 1
            if spawned >= count { break }
        }
    }
}

// MARK: - 破壞死光 DeathRay（additive 過載以白芯高 alpha 堆疊模擬）
extension PicTrailSceneBuilder {

    fileprivate func buildDeathRay(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 3 else { return }
        // 依影片：DeathRay 以白熱光為主，陀螺色僅作極輕外暈染色。
        let tint = headColor(samples)
        let faintTint = mix(SIMD4(1, 1, 1, 1), tint, 0.22)   // 幾乎白、帶一點陀螺色

        // ② 厚重白光柱（×3 重採樣）
        let rs = resample(samples, factor: 3, cap: 64)
        let pos = rs.pos, alp = rs.alpha
        // 兩層：外暈（淡白、寬）+ 白芯（窄、高 alpha）模擬 additive 過載
        appendRibbon(positions: pos, alphas: alp,
                     halfWidthPx: ndcToPixels(0.055, minDim: minDim),
                     color: faintTint, style: .deathRay, alphaScale: 0.55,
                     widthTailBias: 0.72, widthHeadBias: 0.28,
                     trailReversed: true, seedBase: Float(trackID), into: &geometry)
        appendRibbon(positions: pos, alphas: alp,
                     halfWidthPx: ndcToPixels(0.030, minDim: minDim),
                     color: SIMD4(1, 1, 1, 1), style: .deathRay, alphaScale: 0.95,
                     widthTailBias: 0.72, widthHeadBias: 0.28,
                     trailReversed: true, seedBase: Float(trackID) + 1, into: &geometry)

        let head = samples[samples.count - 1].position
        // ① 核心電光球（每幀即時）：白熱外暈 + 白核 + 過載閃光
        let jx = (rnd() - 0.5) * minDim * 0.010
        let jy = (rnd() - 0.5) * minDim * 0.010
        let flick = 0.7 + rnd() * 0.6
        appendSprite(center: SIMD2(head.x + jx, head.y + jy),
                     size: SIMD2(minDim * 0.075 * flick, minDim * 0.075 * flick),
                     color: withAlpha(faintTint, 0.9), style: .haze, rotation: 0,
                     seed: Float(trackID), age: 0, into: &geometry)
        appendSprite(center: SIMD2(head.x + jx, head.y + jy),
                     size: SIMD2(minDim * 0.030 * flick, minDim * 0.030 * flick),
                     color: SIMD4(1, 1, 1, 1), style: .softCircle, rotation: 0,
                     seed: 0, age: 0, into: &geometry)
        if rnd() < 0.5 {
            appendSprite(center: head,
                         size: SIMD2(minDim * 0.11 * flick, minDim * 0.11 * flick),
                         color: SIMD4(1, 1, 1, 0.8), style: .haze, rotation: 0,
                         seed: 0, age: 0, into: &geometry)
        }

        // ① 向心微粒漩渦（跨幀，被吸入核心）
        let hx = pixelToNDCx(head.x), hy = pixelToNDCy(head.y)
        var spawns = 4 * dtScale
        while spawns > 0 {
            if spawns < 1 && rnd() > spawns { break }
            spawnDeathVortex(cx: hx, cy: hy, minDim: minDim, tint: faintTint)
            spawns -= 1
        }

        // ④ 熱浪（沿軌跡隨機，墊在光柱下層感）
        if rnd() < 0.9 * dtScale {
            let idx = min(Int(rnd() * Float(samples.count)), samples.count - 1)
            let b = samples[idx].position
            spawnParticle { [self] p in
                p.x = pixelToNDCx(b.x) + (rnd() - 0.5) * 0.05
                p.y = pixelToNDCy(b.y) + (rnd() - 0.5) * 0.05
                p.size = minDim * (0.04 + rnd() * 0.03)
                p.grow = 0.012; p.alpha = 0.10; p.decay = 0.002
                p.style = .haze
                p.r = 0.80; p.g = 0.90; p.b = 1.0
            }
        }
    }

    /// 向心微粒漩渦：極座標繞核心收斂（完全對齊 .kt updateVortex/drawVortexPoints）。
    private func spawnDeathVortex(cx: Float, cy: Float, minDim: Float, tint: SIMD4<Float>) {
        spawnParticle { [self] p in
            p.orbital = true
            p.cx = cx; p.cy = cy
            p.angle = rnd() * 2 * Float.pi
            p.orbSpawnRadiusPx = minDim * (0.07 + rnd() * 0.06)
            p.orbRadiusPx = p.orbSpawnRadiusPx
            p.orbAngVel = 0.16 + rnd() * 0.12        // 同向 → 一致漩渦
            p.orbInVelPx = minDim * (0.009 + rnd() * 0.006)
            p.size = 3 + rnd() * 3
            p.style = .softCircle
            if rnd() < 0.35 { p.r = 1; p.g = 1; p.b = 1 }
            else { p.r = tint.x; p.g = tint.y; p.b = tint.z }
        }
    }
}

// MARK: - 翡翠破壞 Emerald
extension PicTrailSceneBuilder {

    fileprivate func buildEmerald(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 3 else { return }
        let base = headColor(samples)

        // ③ 神木年輪（最底層，淡同心圓 ring sprite）
        let head = samples[samples.count - 1].position
        let pulse = 0.92 + 0.08 * sin(now * 1.5)
        for ring in 0..<4 {
            let rad = minDim * (0.045 + Float(ring) * 0.038) * pulse
            let a: Float = 0.16 * (1 - Float(ring) / 4 * 0.5)
            appendSprite(center: head,
                         size: SIMD2(rad * 2 / 0.72, rad * 2 / 0.72),
                         color: SIMD4(base.x, base.y, base.z, a),
                         style: .ring, rotation: now * 0.2 * (ring % 2 == 0 ? 1 : -1),
                         seed: Float(ring), age: 0.2, into: &geometry)
        }

        // ① 藤蔓拖尾（×3 重採樣 + 蜿蜒），shader case 10 emerald 給葉脈
        let rs = resample(samples, factor: 3, cap: 64)
        let pos = rs.pos, alp = rs.alpha
        let m = pos.count
        let VINE_AMP = ndcToPixels(0.018, minDim: minDim)
        let offset: (Int, Float, SIMD2<Float>) -> SIMD2<Float> = { [self] j, life, normal in
            let u = Float(j) / Float(m - 1)
            let wave = sin(u * 2.0 * 2 * Float.pi - now * 4.0)
            return normal * (wave * VINE_AMP * (1 - u))
        }
        appendRibbon(positions: pos, alphas: alp,
                     halfWidthPx: ndcToPixels(0.030, minDim: minDim),
                     color: base, style: .emerald, alphaScale: 1.0,
                     widthTailBias: 0.35, widthHeadBias: 0.65,
                     centerlineOffset: offset, trailReversed: true,
                     seedBase: Float(trackID), into: &geometry)

        // ④ 風中翻滾葉片（跨幀）
        guard samples.count >= 4 else { return }
        let mo = headMotion(samples, dtScale: dtScale)
        let dx = pixelToNDCx(mo.head.x) - pixelToNDCx(mo.prev.x)
        let dy = pixelToNDCy(mo.head.y) - pixelToNDCy(mo.prev.y)
        let dirAngle = atan2(dy, dx)
        if rnd() < 0.5 * dtScale {
            let idx = min(Int(rnd() * Float(samples.count) * 0.7), samples.count - 1)
            let l = samples[idx].position
            spawnParticle { [self] p in
                let back = dirAngle + Float.pi + (rnd() - 0.5) * 1.0
                let speed = minDim * (0.004 + rnd() * 0.006)
                p.x = pixelToNDCx(l.x) + (rnd() - 0.5) * 0.03
                p.y = pixelToNDCy(l.y) + (rnd() - 0.5) * 0.03
                p.vx = cos(back) * speed
                p.vy = sin(back) * speed
                p.angle = rnd() * 2 * Float.pi
                p.spin = (0.12 + rnd() * 0.18) * (rnd() < 0.5 ? 1 : -1)
                p.drag = 0.02; p.decay = 0.025 + rnd() * 0.02
                p.size = minDim * (0.018 + rnd() * 0.016)   // lenPx
                p.aspect = 0.45 + rnd() * 0.25              // widPx/lenPx
                p.style = .leaf
                let withered = rnd() < 0.45
                let c = withered ? darken(base, 0.45) : base
                p.r = c.x; p.g = c.y; p.b = c.z
            }
        }
    }
}

// MARK: - 水墨橫空 InkWash
extension PicTrailSceneBuilder {

    fileprivate func buildInkWash(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 3 else { return }
        let base = headColor(samples)
        let rs = resample(samples, factor: 3, cap: 64)
        let pos = rs.pos, alp = rs.alpha
        let m = pos.count
        let INK_HW = ndcToPixels(0.040, minDim: minDim)
        let INK_AMP = ndcToPixels(0.022, minDim: minDim)

        // 3 束：strand0 主墨帶（壓上），strand1/2 極細破空弧線（墊底）→ 由後往前畫
        for strand in stride(from: 2, through: 0, by: -1) {
            let isMain = strand == 0
            let hwBase = isMain ? INK_HW : INK_HW * 0.16
            let sideSign: Float = strand % 2 == 1 ? 1 : -1
            let ampMult: Float = isMain ? 0.30 : 1
            let phase = Float(strand) * 1.7
            let offset: (Int, Float, SIMD2<Float>) -> SIMD2<Float> = { [self] j, life, normal in
                let u = Float(j) / Float(m - 1)
                let wave = sin(u * 1.6 * 2 * Float.pi + phase - now * 3.0)
                let off = wave * INK_AMP * ampMult * (1 - 0.4 * u)
                    + sideSign * hwBase * (isMain ? 0 : 2.2)
                return normal * off
            }
            appendRibbon(positions: pos, alphas: alp,
                         halfWidthPx: hwBase,
                         color: base, style: .inkWash, alphaScale: isMain ? 1.0 : 0.45,
                         widthTailBias: 0.30, widthHeadBias: 0.70,
                         centerlineOffset: offset, trailReversed: true,
                         seedBase: Float(trackID) + phase, into: &geometry)
        }

        // 墨滴飛濺（跨幀，dissolve 以 inkDrop sprite + 縮短壽命近似）
        if rnd() < 0.25 * dtScale {
            let idx = min(Int(rnd() * Float(samples.count) * 0.7), samples.count - 1)
            let t = samples[idx].position
            spawnParticle { [self] p in
                let angle = rnd() * 2 * Float.pi
                let speed = minDim * (0.002 + rnd() * 0.004)
                p.x = pixelToNDCx(t.x) + (rnd() - 0.5) * 0.02
                p.y = pixelToNDCy(t.y) + (rnd() - 0.5) * 0.02
                p.vx = cos(angle) * speed
                p.vy = sin(angle) * speed
                p.drag = 0.04; p.grow = 0.015 + rnd() * 0.02
                p.size = minDim * (0.006 + rnd() * 0.010)   // sizePx（GL_POINTS 直徑）
                p.maxLife = 18 + rnd() * 16                 // .kt life（幀），age/life 控制溶散
                p.style = .inkDrop
                let c = darken(base, 0.6)
                p.r = c.x; p.g = c.y; p.b = c.z
            }
        }
    }
}

// MARK: - 噴漆塗鴉 SprayPaint
extension PicTrailSceneBuilder {

    fileprivate func buildSprayPaint(
        _ samples: [Sample], trackID: Int, now: Float, dtScale: Float,
        minDim: Float, width: Float, height: Float, geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 3 else { return }
        let vividColor = vivid(headColor(samples))
        let positions = samples.map { $0.position }
        let alphas = samples.map { $0.alpha }

        // 噴漆拖尾（shader case 12 spray paint 給顆粒），鮮豔平塗——這是主視覺
        appendRibbon(positions: positions, alphas: alphas,
                     halfWidthPx: ndcToPixels(0.034, minDim: minDim),
                     color: vividColor, style: .sprayPaint, alphaScale: 0.96,
                     widthTailBias: 0.45, widthHeadBias: 0.55, seedBase: Float(trackID),
                     into: &geometry)

        // 對齊 .kt splat 生成條件；依需求5「不鋪滿畫面」，保留 .kt 的 splat 但不啟用每幀 mist。
        guard samples.count >= 2 else { return }
        let mo = headMotion(samples, dtScale: dtScale)
        let dx = pixelToNDCx(mo.head.x) - pixelToNDCx(mo.prev.x)
        let dy = pixelToNDCy(mo.head.y) - pixelToNDCy(mo.prev.y)
        let moveAngle = atan2(dy, dx)
        if throttle(trackID, head: mo.head, threshold: 0.006) {
            if mo.moveNorm > 0.010 && rnd() > 0.45 {
                let side: Float = rnd() > 0.5 ? 1 : -1
                spawnSplat(at: mo.head, angle: moveAngle + side * 1.4, minDim: minDim,
                           samples: samples, big: false)
            }
            if mo.moveNorm > 0.018 {
                let back = moveAngle + Float.pi
                for _ in 0..<2 {
                    spawnSplat(at: mo.head, angle: back + (rnd() - 0.5) * 1.2, minDim: minDim,
                               samples: samples, big: true)
                }
            }
        }
    }

    private func spawnSplat(at headPx: SIMD2<Float>, angle: Float, minDim: Float,
                            samples: [Sample], big: Bool) {
        spawnParticle { [self] p in
            let speed = big ? minDim * (0.006 + rnd() * 0.010) : minDim * (0.004 + rnd() * 0.006)
            p.x = pixelToNDCx(headPx.x) + (rnd() - 0.5) * 0.02
            p.y = pixelToNDCy(headPx.y) + (rnd() - 0.5) * 0.02
            p.vx = cos(angle) * speed
            p.vy = sin(angle) * speed
            p.drag = 0.18
            p.grow = 0.12 + rnd() * 0.08
            p.size = big ? minDim * (0.020 + rnd() * 0.020) : minDim * (0.010 + rnd() * 0.010)
            p.decay = big ? 0.025 + rnd() * 0.02 : 0.04 + rnd() * 0.03
            p.seed = rnd() * 2 * Float.pi
            p.style = .splat
            let c = vivid(headColor(samples), lightJitter: (rnd() - 0.5) * 0.2)
            p.r = c.x; p.g = c.y; p.b = c.z
        }
    }
}

// MARK: - Lightning / Fire / Stardust
// 三個基礎特效只有軌跡，不產生任何獨立粒子。

extension PicTrailSceneBuilder {

    private func appendGenericTrail(
        _ samples: [Sample],
        style: PicRibbonStyle,
        color: SIMD4<Float>,
        glowMult: Float,
        coreMult: Float,
        minDim: Float,
        seed: Float,
        into geometry: inout PicFrameGeometry
    ) {
        let positions = samples.map {
            $0.position
        }

        let alphas = samples.map {
            $0.alpha
        }

        // 外層 Glow
        appendRibbon(
            positions: positions,
            alphas: alphas,
            halfWidthPx: ndcToPixels(
                0.070 * glowMult,
                minDim: minDim
            ),
            color: color,
            style: style,
            alphaScale: 0.45,
            widthTailBias: 0.3,
            widthHeadBias: 0.7,
            seedBase: seed,
            into: &geometry
        )

        // 內層 Core
        appendRibbon(
            positions: positions,
            alphas: alphas,
            halfWidthPx: ndcToPixels(
                0.022 * coreMult,
                minDim: minDim
            ),
            color: color,
            style: style,
            alphaScale: 0.92,
            widthTailBias: 0.3,
            widthHeadBias: 0.7,
            seedBase: seed + 1,
            into: &geometry
        )
    }

    fileprivate func buildLightning(
        _ samples: [Sample],
        trackID: Int,
        now: Float,
        dtScale: Float,
        minDim: Float,
        geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 2 else {
            return
        }

        let yellow = SIMD4<Float>(
            1.0,
            1.0,
            0.333,
            1.0
        )

        appendGenericTrail(
            samples,
            style: .lightning,
            color: yellow,
            glowMult: 1.0,
            coreMult: 1.0,
            minDim: minDim,
            seed: Float(trackID),
            into: &geometry
        )

        // 不生成閃電火花。
        _ = now
        _ = dtScale
    }

    fileprivate func buildFire(
        _ samples: [Sample],
        trackID: Int,
        now: Float,
        dtScale: Float,
        minDim: Float,
        geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 2 else {
            return
        }

        let red = SIMD4<Float>(
            1.0,
            0.165,
            0.07,
            1.0
        )

        appendGenericTrail(
            samples,
            style: .fire,
            color: red,
            glowMult: 1.0,
            coreMult: 1.0,
            minDim: minDim,
            seed: Float(trackID),
            into: &geometry
        )

        // 不生成火球粒子。
        _ = now
        _ = dtScale
    }

    fileprivate func buildStardust(
        _ samples: [Sample],
        trackID: Int,
        now: Float,
        dtScale: Float,
        minDim: Float,
        geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 2 else {
            return
        }

        let baseColor = headColor(samples)

        appendGenericTrail(
            samples,
            style: .stardust,
            color: baseColor,
            glowMult: 1.0,
            coreMult: 1.0,
            minDim: minDim,
            seed: Float(trackID),
            into: &geometry
        )

        // 不生成星形 Sprite。
        _ = now
        _ = dtScale
    }
}
