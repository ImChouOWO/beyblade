package com.beyblade.trailfilter.gl.effects

import android.opengl.GLES20
import com.beyblade.trailfilter.effects.EffectType
import com.beyblade.trailfilter.effects.TrailPoint
import com.beyblade.trailfilter.gl.GLEffect
import com.beyblade.trailfilter.gl.GLHelper
import com.beyblade.trailfilter.gl.GLRenderContext
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 破壞死光 effect — 光學過載的湮滅死光：
 *
 *   ① 蓄力（陀螺核心，與紅蓮破滅同位置 = pts.last 頭端）：
 *      極小極亮、高頻率劇烈震動的電光球體，表面伴隨不穩定能量外洩折線（每幀重生 →
 *      隨時炸裂感），周圍微粒被引力向心吸入核心（向心逆流漩渦），蓄勢待發的壓迫感。
 *   ② 死光主幹（= 軌跡本體）：完全實心的純白光柱，不是線條而是極粗的厚重光柱，
 *      白熱實心核心 + 光學過載外溢光暈（additive 疊加 → 刺眼純白）。
 *   ③ 收尾（尾端）：不是平淡變透明 — 雜訊把尾巴啃成一個個空洞（物質被燒盡蒸發、
 *      空洞被吞噬），破洞邊緣留下燃燒餘光的鋸齒殘邊。
 *   ④ 熱浪：光柱兩側極淡暖白微光緩慢膨脹淡出，擬空氣超高溫的折射殘留（擬真、零成本，
 *      非真正取樣背景扭曲）。
 *
 * 色調由 colorOverride 提供電光藍白基底；核心一律過載成純白。
 * 所有每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class DeathRayGLEffect : GLEffect() {

    // ── 死光光柱 ribbon program ────────────────────────────────────────────
    private var beamProgram = 0
    private var bPosLoc = -1; private var bColLoc = -1
    private var bDistLoc = -1; private var bTrailLoc = -1
    private var bTimeLoc = -1; private var bTintLoc = -1

    // ── 點精靈 program（向心微粒 / 熱浪 / 核心電光球） ──────────────────────
    private var pointProgram = 0
    private var pPosLoc = -1; private var pColLoc = -1; private var pSizeLoc = -1

    // ── 折線 program（能量外洩電弧，GL_LINES） ─────────────────────────────
    private var lineProgram = 0
    private var lPosLoc = -1; private var lColLoc = -1

    // ── 向心微粒（被引力吸入核心的逆流漩渦） ──────────────────────────────
    private class Vortex {
        var active = false
        var cx = 0f; var cy = 0f           // 吸引中心（NDC，spawn 當下的陀螺核心）
        var angle = 0f                      // 極座標角（rad）
        var radiusPx = 0f                   // 距核心半徑（px）
        var angVel = 0f                     // 角速度（rad/frame）
        var inVelPx = 0f                    // 向心速度（px/frame）
        var spawnRadiusPx = 1f
        var sizePx = 4f
        var r = 0.8f; var g = 0.92f; var b = 1f
    }
    private val vortices = Array(MAX_VORTEX) { Vortex() }
    private val vortexBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_VORTEX * BYTES_PER_PT).order(ByteOrder.nativeOrder())
    private val vortexFloats: FloatBuffer = vortexBuf.asFloatBuffer()

    // ── 熱浪折射殘影（極淡、緩慢淡出） ────────────────────────────────────
    private class Haze {
        var active = false
        var x = 0f; var y = 0f
        var sizePx = 30f
        var alpha = 0f
    }
    private val hazes = Array(MAX_HAZE) { Haze() }
    private val hazeBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_HAZE * BYTES_PER_PT).order(ByteOrder.nativeOrder())
    private val hazeFloats: FloatBuffer = hazeBuf.asFloatBuffer()

    // ── 核心電光球（每幀即時繪製，不留狀態） ──────────────────────────────
    private val coreBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_HEADS * 3 * BYTES_PER_PT).order(ByteOrder.nativeOrder())
    private val coreFloats: FloatBuffer = coreBuf.asFloatBuffer()

    // ── 能量外洩折線（每幀重生 → 高頻不穩定） ──────────────────────────────
    private val arcBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_ARC_VERTS * BYTES_PER_LINE).order(ByteOrder.nativeOrder())
    private val arcFloats: FloatBuffer = arcBuf.asFloatBuffer()

    private var time = 0f
    private var hazeAccum = 0f

    // 重採樣中心線（光柱需要平滑曲線）
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val rX  = FloatArray(MAX_RESAMPLE)
    private val rY  = FloatArray(MAX_RESAMPLE)
    private val rA  = FloatArray(MAX_RESAMPLE)
    private val cum = FloatArray(MAX_RESAMPLE)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        beamProgram = GLHelper.buildProgram(BEAM_VERT, BEAM_FRAG)
        bPosLoc   = GLES20.glGetAttribLocation(beamProgram, "aPosition")
        bColLoc   = GLES20.glGetAttribLocation(beamProgram, "aColor")
        bDistLoc  = GLES20.glGetAttribLocation(beamProgram, "aCenterDist")
        bTrailLoc = GLES20.glGetAttribLocation(beamProgram, "aTrailDist")
        bTimeLoc  = GLES20.glGetUniformLocation(beamProgram, "uTime")
        bTintLoc  = GLES20.glGetUniformLocation(beamProgram, "uTint")

        pointProgram = GLHelper.buildProgram(POINT_VERT, POINT_FRAG)
        pPosLoc  = GLES20.glGetAttribLocation(pointProgram, "aPosition")
        pColLoc  = GLES20.glGetAttribLocation(pointProgram, "aColor")
        pSizeLoc = GLES20.glGetAttribLocation(pointProgram, "aSize")

        lineProgram = GLHelper.buildProgram(LINE_VERT, LINE_FRAG)
        lPosLoc = GLES20.glGetAttribLocation(lineProgram, "aPosition")
        lColLoc = GLES20.glGetAttribLocation(lineProgram, "aColor")
    }

    // ── draw ──────────────────────────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        time += (1f / 30f) * ctx.dtScale
        if (time > TIME_WRAP) time -= TIME_WRAP

        vwHalf = (ctx.viewWidth * 0.5f).coerceAtLeast(1f)
        vhHalf = (ctx.viewHeight * 0.5f).coerceAtLeast(1f)

        // 過載疊加：所有元素改用 additive，讓白芯與光暈刺眼爆出
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE)

        // ④ 熱浪墊底（在光柱下層才像空氣折射殘留）
        spawnHaze(trackData, ctx)
        updateHaze(ctx.dtScale)
        drawHazePoints()

        // ② 死光主幹光柱 — 外暈/餘光抓陀螺中心色，白芯一律過載成純白（逐軌道各自上色）
        GLES20.glUseProgram(beamProgram)
        GLES20.glUniform1f(bTimeLoc, time)
        GLES20.glEnableVertexAttribArray(bPosLoc)
        GLES20.glEnableVertexAttribArray(bColLoc)
        GLES20.glEnableVertexAttribArray(bDistLoc)
        GLES20.glEnableVertexAttribArray(bTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size < 3) continue
            val c = pts.last().first.color
            GLES20.glUniform3f(bTintLoc,
                (c shr 16 and 0xFF) / 255f, (c shr 8 and 0xFF) / 255f, (c and 0xFF) / 255f)
            drawBeam(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(bPosLoc)
        GLES20.glDisableVertexAttribArray(bColLoc)
        GLES20.glDisableVertexAttribArray(bDistLoc)
        GLES20.glDisableVertexAttribArray(bTrailLoc)

        // ① 蓄力：向心微粒 + 核心電光球 + 能量外洩折線
        spawnVortex(trackData, ctx)
        updateVortex(ctx)
        drawVortexPoints()
        drawCoreAndArcs(trackData, ctx)

        // 還原成預設 alpha 混合，不影響其他繪製
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
    }

    // ── ② 死光主幹光柱 ────────────────────────────────────────────────────

    private fun drawBeam(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = min(pts.size, MAX_TRAIL_POINTS)
        if (n < 3) return

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
        }
        val m = (n * 3).coerceAtMost(MAX_RESAMPLE)
        for (j in 0 until m) {
            val f  = j.toFloat() / (m - 1) * (n - 1)
            val i0 = f.toInt().coerceAtMost(n - 2)
            val fr = f - i0
            rX[j] = ptX[i0] + (ptX[i0+1] - ptX[i0]) * fr
            rY[j] = ptY[i0] + (ptY[i0+1] - ptY[i0]) * fr
            rA[j] = pts[i0].second + (pts[i0+1].second - pts[i0].second) * fr
            cum[j] = if (j == 0) 0f else {
                val dx = rX[j] - rX[j-1]; val dy = rY[j] - rY[j-1]
                cum[j-1] + sqrt(dx * dx + dy * dy)
            }
        }
        val totalLen = cum[m - 1]
        if (m * 2 * BYTES_PER_VERT_BEAM > ctx.ribbonBuf.capacity()) return

        ctx.ribbonFloats.clear()
        for (j in 0 until m) {
            val x = rX[j]; val y = rY[j]
            val (nx, ny) = when {
                j == 0     -> GLHelper.segNormal(x, y, rX[1], rY[1])
                j == m - 1 -> GLHelper.segNormal(rX[j-1], rY[j-1], x, y)
                else       -> GLHelper.avgNormal(rX[j-1], rY[j-1], x, y, rX[j+1], rY[j+1])
            }
            val life = rA[j]
            // 厚重光柱：大致等寬，頭端再略粗（蓄力端最猛）
            val hw    = BEAM_HALF_WIDTH * (0.72f + 0.28f * life)
            val trail = totalLen - cum[j]
            ctx.ribbonFloats.put(x - nx*hw).put(y - ny*hw).put(1f).put(1f).put(1f).put(life).put(-1f).put(trail)
            ctx.ribbonFloats.put(x + nx*hw).put(y + ny*hw).put(1f).put(1f).put(1f).put(life).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(bPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BEAM, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(bColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BEAM, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(bDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BEAM, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(bTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BEAM, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, m * 2)
    }

    // ── ① 向心微粒漩渦 ────────────────────────────────────────────────────

    private fun spawnVortex(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)
        for ((_, pts) in trackData) {
            if (pts.isEmpty()) continue
            val tp = pts.last().first
            val cx = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            val cy = (1f - tp.center.y * 2f) * ctx.quadScaleY
            // 每幀補幾顆（×dtScale 保持 60fps 一致）
            var spawns = VORTEX_PER_FRAME * ctx.dtScale
            while (spawns > 0f) {
                if (spawns < 1f && Math.random() > spawns) break
                spawnOneVortex(cx, cy, minDim, tp.color)
                spawns -= 1f
            }
        }
    }

    private fun spawnOneVortex(cx: Float, cy: Float, minDim: Float, color: Int) {
        for (v in vortices) {
            if (v.active) continue
            v.active = true
            v.cx = cx; v.cy = cy
            v.angle = Math.random().toFloat() * TWO_PI
            v.spawnRadiusPx = minDim * (0.07f + Math.random().toFloat() * 0.06f)
            v.radiusPx = v.spawnRadiusPx
            v.angVel  = (0.16f + Math.random().toFloat() * 0.12f)   // 同向 → 一致漩渦
            v.inVelPx = minDim * (0.009f + Math.random().toFloat() * 0.006f)
            v.sizePx  = 3f + Math.random().toFloat() * 3f
            // 多數抓陀螺色、少數白熱
            if (Math.random() < 0.35f) {
                v.r = 1f; v.g = 1f; v.b = 1f
            } else {
                v.r = (color shr 16 and 0xFF) / 255f
                v.g = (color shr  8 and 0xFF) / 255f
                v.b = (color        and 0xFF) / 255f
            }
            return
        }
    }

    private fun updateVortex(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (v in vortices) {
            if (!v.active) continue
            v.inVelPx *= 1f + 0.05f * dt          // 引力加速向心
            v.radiusPx -= v.inVelPx * dt
            v.angle += v.angVel * dt
            if (v.radiusPx <= minOf(vw, vh) * 0.010f) { v.active = false }
        }
    }

    private fun drawVortexPoints() {
        vortexFloats.clear()
        var count = 0
        for (v in vortices) {
            if (!v.active) continue
            val x = v.cx + cos(v.angle) * v.radiusPx / (vwHalf)
            val y = v.cy + sin(v.angle) * v.radiusPx / (vhHalf)
            // 越靠核心越亮、越小（被壓縮吸入）
            val t = (1f - v.radiusPx / v.spawnRadiusPx).coerceIn(0f, 1f)
            val a = (0.35f + 0.65f * t)
            val sz = v.sizePx * (1f - 0.4f * t)
            vortexFloats.put(x).put(y).put(v.r).put(v.g).put(v.b).put(a).put(sz)
            count++
        }
        if (count == 0) return
        drawPoints(vortexBuf, count)
    }

    // ── ① 核心電光球 + 能量外洩折線 ───────────────────────────────────────

    private fun drawCoreAndArcs(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext
    ) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)

        coreFloats.clear(); arcFloats.clear()
        var coreCount = 0; var arcVerts = 0
        var headCount = 0
        for ((_, pts) in trackData) {
            if (pts.isEmpty() || headCount >= MAX_HEADS) continue
            headCount++
            val tp = pts.last().first
            val cx = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            val cy = (1f - tp.center.y * 2f) * ctx.quadScaleY
            // 外暈/電弧抓該陀螺中心色（核心仍過載成純白）
            val tr = (tp.color shr 16 and 0xFF) / 255f
            val tg = (tp.color shr  8 and 0xFF) / 255f
            val tb = (tp.color        and 0xFF) / 255f

            // 高頻劇烈震動：每幀微抖位置 + 尺寸狂閃
            val jx = (Math.random().toFloat() - 0.5f) * minDim * 0.010f / vwHalf
            val jy = (Math.random().toFloat() - 0.5f) * minDim * 0.010f / vhHalf
            val flick = 0.7f + Math.random().toFloat() * 0.6f
            // 外層電光暈（藍白）
            coreFloats.put(cx + jx).put(cy + jy).put(tr).put(tg).put(tb).put(0.9f)
                .put(minDim * 0.075f * flick); coreCount++
            // 內層白熱核（極小極亮）
            coreFloats.put(cx + jx).put(cy + jy).put(1f).put(1f).put(1f).put(1f)
                .put(minDim * 0.030f * flick); coreCount++
            // 過載閃光（隨機強脈衝）
            if (Math.random() < 0.5f) {
                coreFloats.put(cx).put(cy).put(1f).put(1f).put(1f).put(0.8f)
                    .put(minDim * 0.11f * flick); coreCount++
            }

            // 能量外洩折線：每幀重生 N 條鋸齒電弧（隨時炸裂感）
            val arcs = ARCS_PER_HEAD
            for (a in 0 until arcs) {
                if (arcVerts + ARC_SEGS * 2 > MAX_ARC_VERTS) break
                var px = cx; var py = cy
                var ang = Math.random().toFloat() * TWO_PI
                val segLen = minDim * (0.018f + Math.random().toFloat() * 0.020f)
                for (s in 0 until ARC_SEGS) {
                    ang += (Math.random().toFloat() - 0.5f) * 1.6f      // 鋸齒折角
                    val nx = px + cos(ang) * segLen / vwHalf
                    val ny = py + sin(ang) * segLen / vhHalf
                    // 由內而外漸暗
                    val fade = 1f - s.toFloat() / ARC_SEGS
                    val ar = tr * 0.4f + 0.6f; val ag = tg * 0.4f + 0.6f; val ab = tb * 0.4f + 0.6f
                    arcFloats.put(px).put(py).put(ar).put(ag).put(ab).put(0.85f * fade)
                    arcFloats.put(nx).put(ny).put(ar).put(ag).put(ab).put(0.85f * (1f - (s + 1f) / ARC_SEGS))
                    arcVerts += 2
                    px = nx; py = ny
                }
            }
        }

        if (coreCount > 0) drawPoints(coreBuf, coreCount)
        if (arcVerts > 0) drawArcs(arcVerts)
    }

    private fun drawArcs(vertCount: Int) {
        GLES20.glUseProgram(lineProgram)
        GLES20.glLineWidth(2f)
        GLES20.glEnableVertexAttribArray(lPosLoc)
        GLES20.glEnableVertexAttribArray(lColLoc)
        arcBuf.position(0)
        GLES20.glVertexAttribPointer(lPosLoc, 2, GLES20.GL_FLOAT, false, BYTES_PER_LINE, arcBuf)
        arcBuf.position(8)
        GLES20.glVertexAttribPointer(lColLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_LINE, arcBuf)
        arcBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, vertCount)
        GLES20.glDisableVertexAttribArray(lPosLoc)
        GLES20.glDisableVertexAttribArray(lColLoc)
    }

    // ── ④ 熱浪折射殘影 ────────────────────────────────────────────────────

    private fun spawnHaze(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)
        hazeAccum += HAZE_SPAWN_RATE * ctx.dtScale
        while (hazeAccum >= 1f) {
            hazeAccum -= 1f
            // 沿某條軌跡隨機取一點，光柱兩側冒出熱浪
            val pts = trackData.values.randomOrNullCompat() ?: break
            if (pts.size < 2) break
            val idx = (Math.random() * pts.size).toInt().coerceAtMost(pts.size - 1)
            val tp = pts[idx].first
            val bx = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            val by = (1f - tp.center.y * 2f) * ctx.quadScaleY
            spawnOneHaze(
                bx + (Math.random().toFloat() - 0.5f) * 0.05f,
                by + (Math.random().toFloat() - 0.5f) * 0.05f,
                minDim)
        }
    }

    private fun spawnOneHaze(x: Float, y: Float, minDim: Float) {
        for (hz in hazes) {
            if (hz.active) continue
            hz.active = true
            hz.x = x; hz.y = y
            hz.sizePx = minDim * (0.04f + Math.random().toFloat() * 0.03f)
            hz.alpha  = 0.08f
            return
        }
    }

    private fun updateHaze(dt: Float) {
        for (hz in hazes) {
            if (!hz.active) continue
            hz.sizePx *= 1f + 0.012f * dt
            hz.alpha  -= 0.0020f * dt
            if (hz.alpha <= 0f) hz.active = false
        }
    }

    private fun drawHazePoints() {
        hazeFloats.clear()
        var count = 0
        for (hz in hazes) {
            if (!hz.active) continue
            hazeFloats.put(hz.x).put(hz.y)
                .put(0.80f).put(0.90f).put(1f)               // 冷白 — 超高溫折射微光
                .put(hz.alpha.coerceIn(0f, 1f)).put(hz.sizePx)
            count++
        }
        if (count == 0) return
        drawPoints(hazeBuf, count)
    }

    // ── 共用：GL_POINTS 繪製 ──────────────────────────────────────────────

    private fun drawPoints(buf: ByteBuffer, count: Int) {
        GLES20.glUseProgram(pointProgram)
        GLES20.glEnableVertexAttribArray(pPosLoc)
        GLES20.glEnableVertexAttribArray(pColLoc)
        GLES20.glEnableVertexAttribArray(pSizeLoc)
        buf.position(0)
        GLES20.glVertexAttribPointer(pPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(8)
        GLES20.glVertexAttribPointer(pColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(24)
        GLES20.glVertexAttribPointer(pSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(pPosLoc)
        GLES20.glDisableVertexAttribArray(pColLoc)
        GLES20.glDisableVertexAttribArray(pSizeLoc)
    }

    // 視窗半寬高快取（drawVortexPoints / drawCoreAndArcs 用，避免重算）
    private var vwHalf = 1f
    private var vhHalf = 1f

    private fun <T> Collection<List<T>>.randomOrNullCompat(): List<T>? {
        if (isEmpty()) return null
        val idx = (Math.random() * size).toInt().coerceAtMost(size - 1)
        return elementAt(idx)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_PT        = 28   // 7 floats × 4 (pos2 col4 size1)
        private const val BYTES_PER_LINE      = 24   // 6 floats × 4 (pos2 col4)
        private const val BYTES_PER_VERT_BEAM = 32   // 8 floats × 4 (pos2 col4 dist1 trail1)
        private const val MAX_VORTEX          = 64
        private const val MAX_HAZE            = 24
        private const val MAX_HEADS           = 8
        private const val MAX_TRAIL_POINTS    = 256
        private const val MAX_RESAMPLE        = 64
        private const val MAX_ARC_VERTS       = 1024
        private const val VORTEX_PER_FRAME    = 4f
        private const val ARCS_PER_HEAD       = 5
        private const val ARC_SEGS            = 4
        private const val HAZE_SPAWN_RATE     = 0.9f
        private const val BEAM_HALF_WIDTH     = 0.055f  // 極粗厚重光柱（NDC 半寬）
        private const val TWO_PI              = (Math.PI * 2).toFloat()
        private const val TIME_WRAP           = 120f

        private val BEAM_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            attribute float aTrailDist;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
                vTrailDist = aTrailDist;
            }""".trimIndent()

        // 死光主幹（additive 過載）：實心白芯 + 電光藍白外溢光暈；
        // 尾端雜訊啃出空洞（物質被燒盡蒸發），破洞邊緣留燃燒餘光鋸齒殘邊。
        private val BEAM_FRAG = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            uniform vec3  uTint;

            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            float noise(vec2 p) {
                vec2 i = floor(p);
                vec2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash(i),                  hash(i + vec2(1.0, 0.0)), f.x),
                           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
            }

            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;
                float tail = 1.0 - life;

                // 沿光柱捲動的雜訊 → 尾端啃蝕
                vec2  uv = vec2(vTrailDist * 22.0 - uTime * 3.0, vCenterDist * 3.0);
                float n1 = noise(uv);
                float n2 = noise(uv * 2.3 + 5.1);
                float nz = n1 * 0.6 + n2 * 0.4;

                // 實心白芯 + 過載光暈
                float core = 1.0 - smoothstep(0.18, 0.46, d);
                float glow = exp(-d * d * 6.0);

                // 尾端「燒盡」：雜訊把尾巴咬成一束束空洞（越靠尾洞越大）
                float burn = smoothstep(life * 1.05, life * 1.05 + 0.20, nz);
                // 破洞邊緣的燃燒餘光鋸齒殘邊
                float rim  = (1.0 - smoothstep(0.0, 0.10, abs(nz - life * 1.05))) * tail;

                float body = (core * 1.0 + glow * 0.55) * (1.0 - burn);
                body += rim * (0.5 + 0.5 * tail);
                if (body <= 0.004) discard;

                // 白芯 → 電光藍白光暈
                vec3 col = mix(uTint, vec3(1.0), core);
                col = mix(col, vec3(1.0), rim * 0.7);

                float inten = body * (0.55 + 0.45 * life);
                gl_FragColor = vec4(col, min(inten, 1.0));
            }""".trimIndent()

        private val POINT_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }""".trimIndent()

        // 點精靈：高斯光點（向心微粒 / 熱浪 / 核心電光球共用）
        private val POINT_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.2);
                gl_FragColor = vec4(vColor.rgb, a);
            }""".trimIndent()

        private val LINE_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }""".trimIndent()

        private val LINE_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }""".trimIndent()
    }
}
