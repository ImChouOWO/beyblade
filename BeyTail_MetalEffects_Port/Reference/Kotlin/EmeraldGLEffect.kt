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
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 翡翠破壞 effect — 神木 / 植物殺伐：
 *
 *   ① 藤蔓拖尾（= 軌跡本體）：不規則有機攀附的藤蔓，邊緣被雜訊咬成葉緣鋸齒，
 *      中肋亮線；尾端漸枯（withered）。
 *   ② 飛葉快刀（V 字爆發）：猛烈位移時，沿位移方向呈 V 字向四周狂暴炸開大量
 *      極度拉長的梭形葉刃（兩頭收縮針狀），像碎玻璃般高速自轉飛散。
 *   ③ 神木年輪力場：陀螺底盤正下方淡淡刷出多重同心圓年輪圖騰（古木穩固、耐打）。
 *   ④ 風速感：旋轉的微型綠葉 + 枯葉殘影沿位移方向往後翻滾拖尾。
 *
 * 色調一律跟隨陀螺中心偵測色（逐軌道各自上色），中肋/反光提亮成白；枯葉用陀螺色暗化版。
 * 所有每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class EmeraldGLEffect : GLEffect() {

    // ── 藤蔓 ribbon program ────────────────────────────────────────────────
    private var vineProgram = 0
    private var vPosLoc = -1; private var vColLoc = -1
    private var vDistLoc = -1; private var vTrailLoc = -1; private var vTimeLoc = -1

    // ── 葉刃 / 葉片 quad program（梭形 shape by shader） ─────────────────────
    private var leafProgram = 0
    private var lfPosLoc = -1; private var lfUvLoc = -1; private var lfColLoc = -1

    // ── 年輪力場 line program ──────────────────────────────────────────────
    private var ringProgram = 0
    private var rgPosLoc = -1; private var rgColLoc = -1

    // ── 葉刃 / 葉片粒子 ─────────────────────────────────────────────────────
    private class Leaf {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f          // px/frame
        var angle = 0f; var angVel = 0f   // rad / rad-per-frame（自轉）
        var lenPx = 20f; var widPx = 5f
        var grow = 0f                     // 每幀拉長比例（飛葉快刀邊飛邊拉長）
        var alpha = 0f; var decay = 0.05f
        var r = 0.4f; var g = 1f; var b = 0.5f
    }
    private val leaves = Array(MAX_LEAVES) { Leaf() }   // 翻滾微型綠葉 / 枯葉殘影
    private val leafBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_LEAVES * 6 * BYTES_PER_LEAF_VERT).order(ByteOrder.nativeOrder())
    private val leafFloats: FloatBuffer = leafBuf.asFloatBuffer()

    // ── 年輪力場 ────────────────────────────────────────────────────────────
    private val ringBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_HEADS * RING_COUNT * RING_SEG * 2 * BYTES_PER_LINE)
            .order(ByteOrder.nativeOrder())
    private val ringFloats: FloatBuffer = ringBuf.asFloatBuffer()

    private var time = 0f

    // 藤蔓重採樣
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val rX  = FloatArray(MAX_RESAMPLE)
    private val rY  = FloatArray(MAX_RESAMPLE)
    private val rA  = FloatArray(MAX_RESAMPLE)
    private val cum = FloatArray(MAX_RESAMPLE)

    private var vwHalf = 1f
    private var vhHalf = 1f

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        vineProgram = GLHelper.buildProgram(VINE_VERT, VINE_FRAG)
        vPosLoc   = GLES20.glGetAttribLocation(vineProgram, "aPosition")
        vColLoc   = GLES20.glGetAttribLocation(vineProgram, "aColor")
        vDistLoc  = GLES20.glGetAttribLocation(vineProgram, "aCenterDist")
        vTrailLoc = GLES20.glGetAttribLocation(vineProgram, "aTrailDist")
        vTimeLoc  = GLES20.glGetUniformLocation(vineProgram, "uTime")

        leafProgram = GLHelper.buildProgram(LEAF_VERT, LEAF_FRAG)
        lfPosLoc = GLES20.glGetAttribLocation(leafProgram, "aPosition")
        lfUvLoc  = GLES20.glGetAttribLocation(leafProgram, "aUV")
        lfColLoc = GLES20.glGetAttribLocation(leafProgram, "aColor")

        ringProgram = GLHelper.buildProgram(RING_VERT, RING_FRAG)
        rgPosLoc = GLES20.glGetAttribLocation(ringProgram, "aPosition")
        rgColLoc = GLES20.glGetAttribLocation(ringProgram, "aColor")
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

        // ③ 神木年輪力場（最底層，淡淡墊在陀螺下方）
        drawTreeRings(trackData, ctx)

        // ④ 翻滾葉片殘影（在藤蔓下層 → 像被甩在後方的風中落葉）
        updateLeaves(ctx)
        drawLeafQuads(leaves, leafBuf, leafFloats)

        // ① 藤蔓拖尾本體
        GLES20.glUseProgram(vineProgram)
        GLES20.glUniform1f(vTimeLoc, time)
        GLES20.glEnableVertexAttribArray(vPosLoc)
        GLES20.glEnableVertexAttribArray(vColLoc)
        GLES20.glEnableVertexAttribArray(vDistLoc)
        GLES20.glEnableVertexAttribArray(vTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 3) drawVine(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(vPosLoc)
        GLES20.glDisableVertexAttribArray(vColLoc)
        GLES20.glDisableVertexAttribArray(vDistLoc)
        GLES20.glDisableVertexAttribArray(vTrailLoc)

        // 補生風中翻滾葉片（下一幀繪製）
        spawnFromTrack(trackData, ctx)
    }

    // ── ① 藤蔓拖尾 ──────────────────────────────────────────────────────────

    private fun drawVine(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
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
        if (m * 2 * BYTES_PER_VERT_VINE > ctx.ribbonBuf.capacity()) return

        val c  = pts.last().first.color
        val cr = (c shr 16 and 0xFF) / 255f
        val cg = (c shr  8 and 0xFF) / 255f
        val cb = (c        and 0xFF) / 255f

        ctx.ribbonFloats.clear()
        for (j in 0 until m) {
            val x = rX[j]; val y = rY[j]
            val (nx, ny) = when {
                j == 0     -> GLHelper.segNormal(x, y, rX[1], rY[1])
                j == m - 1 -> GLHelper.segNormal(rX[j-1], rY[j-1], x, y)
                else       -> GLHelper.avgNormal(rX[j-1], rY[j-1], x, y, rX[j+1], rY[j+1])
            }
            val u    = j.toFloat() / (m - 1)        // 0 = 尾, 1 = 頭
            val life = rA[j]
            // 藤蔓有機攀附：沿軌跡緩慢蜿蜒擺動（頭端緊貼陀螺）
            val wave = sin(u * VINE_FREQ * 2f * PI_F - time * VINE_SPEED)
            val off  = wave * VINE_AMP * (1f - u)
            val hw   = VINE_HALF_WIDTH * (0.35f + 0.65f * life)
            val cx   = x + nx * off
            val cy   = y + ny * off
            val trail = totalLen - cum[j]
            ctx.ribbonFloats.put(cx - nx*hw).put(cy - ny*hw).put(cr).put(cg).put(cb).put(life).put(-1f).put(trail)
            ctx.ribbonFloats.put(cx + nx*hw).put(cy + ny*hw).put(cr).put(cg).put(cb).put(life).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(vPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_VINE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(vColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_VINE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(vDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_VINE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(vTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_VINE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, m * 2)
    }

    // ── ②④ 飛葉快刀 + 翻滾葉片 ────────────────────────────────────────────

    private fun spawnFromTrack(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)

        for ((_, pts) in trackData) {
            if (pts.size < 4) continue
            val (tp,  _) = pts.last()
            val (tp1, _) = pts[pts.size - 2]
            val x  = (tp.center.x  * 2f - 1f) * ctx.quadScaleX
            val y  = (1f - tp.center.y  * 2f) * ctx.quadScaleY
            val x1 = (tp1.center.x * 2f - 1f) * ctx.quadScaleX
            val y1 = (1f - tp1.center.y * 2f) * ctx.quadScaleY
            // 位移方向角（px 空間，故乘回半寬高還原比例）
            val dirAngle = atan2((y - y1) * vhHalf, (x - x1) * vwHalf)

            // ④ 風中落葉：沿軌跡偏尾段持續往位移反方向甩出翻滾葉片
            if (Math.random() < 0.5f * ctx.dtScale) {
                val idx = (Math.random() * pts.size * 0.7).toInt().coerceAtMost(pts.size - 1)
                val ltp = pts[idx].first
                spawnTumbleLeaf(
                    (ltp.center.x * 2f - 1f) * ctx.quadScaleX,
                    (1f - ltp.center.y * 2f) * ctx.quadScaleY,
                    dirAngle, minDim, tp.color)
            }
        }
    }

    private fun spawnTumbleLeaf(x: Float, y: Float, dirAngle: Float, minDim: Float, color: Int) {
        for (lf in leaves) {
            if (lf.active) continue
            // 往位移反方向甩出（帶起後方一陣翻滾）+ 側向亂飄
            val back = dirAngle + PI_F + (Math.random().toFloat() - 0.5f) * 1.0f
            val speed = minDim * (0.004f + Math.random().toFloat() * 0.006f)
            lf.active = true
            lf.x = x + (Math.random().toFloat() - 0.5f) * 0.03f
            lf.y = y + (Math.random().toFloat() - 0.5f) * 0.03f
            lf.vx = cos(back) * speed
            lf.vy = sin(back) * speed
            lf.angle = Math.random().toFloat() * TWO_PI
            lf.angVel = (0.12f + Math.random().toFloat() * 0.18f) * (if (Math.random() < 0.5f) 1f else -1f)
            lf.lenPx = minDim * (0.018f + Math.random().toFloat() * 0.016f)  // 微型葉
            lf.widPx = lf.lenPx * (0.45f + Math.random().toFloat() * 0.25f)
            lf.grow  = 0f
            lf.alpha = 0.9f
            lf.decay = 0.025f + Math.random().toFloat() * 0.02f
            setLeafColor(lf, color, withered = Math.random() < 0.45f)         // 近半數枯葉殘影
            return
        }
    }

    private fun setLeafColor(lf: Leaf, color: Int, withered: Boolean) {
        val cr = (color shr 16 and 0xFF) / 255f
        val cg = (color shr  8 and 0xFF) / 255f
        val cb = (color        and 0xFF) / 255f
        if (withered) {                       // 枯葉 = 陀螺色暗化版（殘影感）
            lf.r = cr * 0.45f; lf.g = cg * 0.45f; lf.b = cb * 0.45f
        } else {
            lf.r = cr; lf.g = cg; lf.b = cb
        }
    }

    private fun updateLeaves(ctx: GLRenderContext) {
        val dt = ctx.dtScale
        for (lf in leaves) {
            if (!lf.active) continue
            lf.x += lf.vx * dt / vwHalf
            lf.y += lf.vy * dt / vhHalf
            lf.vx *= 1f - 0.02f * dt
            lf.vy *= 1f - 0.02f * dt
            lf.angle += lf.angVel * dt
            lf.alpha -= lf.decay * dt
            if (lf.alpha <= 0f) lf.active = false
        }
    }

    /** 把一個 Leaf 池畫成梭形 quad（共用 leafProgram）。 */
    private fun drawLeafQuads(pool: Array<Leaf>, buf: ByteBuffer, floats: FloatBuffer) {
        floats.clear()
        var quads = 0
        for (lf in pool) {
            if (!lf.active) continue
            emitLeafQuad(floats, lf)
            quads++
        }
        if (quads == 0) return

        GLES20.glUseProgram(leafProgram)
        GLES20.glEnableVertexAttribArray(lfPosLoc)
        GLES20.glEnableVertexAttribArray(lfUvLoc)
        GLES20.glEnableVertexAttribArray(lfColLoc)
        buf.position(0)
        GLES20.glVertexAttribPointer(lfPosLoc, 2, GLES20.GL_FLOAT, false, BYTES_PER_LEAF_VERT, buf)
        buf.position(8)
        GLES20.glVertexAttribPointer(lfUvLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_LEAF_VERT, buf)
        buf.position(16)
        GLES20.glVertexAttribPointer(lfColLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_LEAF_VERT, buf)
        buf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, quads * 6)
        GLES20.glDisableVertexAttribArray(lfPosLoc)
        GLES20.glDisableVertexAttribArray(lfUvLoc)
        GLES20.glDisableVertexAttribArray(lfColLoc)
    }

    private fun emitLeafQuad(fb: FloatBuffer, lf: Leaf) {
        val c = cos(lf.angle); val s = sin(lf.angle)
        val hl = lf.lenPx * 0.5f; val hw = lf.widPx * 0.5f
        val a = lf.alpha.coerceIn(0f, 1f)
        // 四角（local u,v ∈ ±1 → ±hl, ±hw），旋轉後轉 NDC
        // A(-1,-1) B(1,-1) C(1,1) D(-1,1)
        val ax = lf.x + (-hl * c - -hw * s) / vwHalf; val ay = lf.y + (-hl * s + -hw * c) / vhHalf
        val bx = lf.x + ( hl * c - -hw * s) / vwHalf; val by = lf.y + ( hl * s + -hw * c) / vhHalf
        val cx = lf.x + ( hl * c -  hw * s) / vwHalf; val cy = lf.y + ( hl * s +  hw * c) / vhHalf
        val dx = lf.x + (-hl * c -  hw * s) / vwHalf; val dy = lf.y + (-hl * s +  hw * c) / vhHalf
        // tri1: A,B,C
        fb.put(ax).put(ay).put(-1f).put(-1f).put(lf.r).put(lf.g).put(lf.b).put(a)
        fb.put(bx).put(by).put( 1f).put(-1f).put(lf.r).put(lf.g).put(lf.b).put(a)
        fb.put(cx).put(cy).put( 1f).put( 1f).put(lf.r).put(lf.g).put(lf.b).put(a)
        // tri2: A,C,D
        fb.put(ax).put(ay).put(-1f).put(-1f).put(lf.r).put(lf.g).put(lf.b).put(a)
        fb.put(cx).put(cy).put( 1f).put( 1f).put(lf.r).put(lf.g).put(lf.b).put(a)
        fb.put(dx).put(dy).put(-1f).put( 1f).put(lf.r).put(lf.g).put(lf.b).put(a)
    }

    // ── ③ 神木年輪力場 ──────────────────────────────────────────────────────

    private fun drawTreeRings(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)

        ringFloats.clear()
        var verts = 0
        var heads = 0
        for ((_, pts) in trackData) {
            if (pts.isEmpty() || heads >= MAX_HEADS) continue
            heads++
            val tp = pts.last().first
            val cx = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            val cy = (1f - tp.center.y * 2f) * ctx.quadScaleY
            val c = tp.color
            val cr = (c shr 16 and 0xFF) / 255f
            val cg = (c shr  8 and 0xFF) / 255f
            val cb = (c        and 0xFF) / 255f
            // 呼吸脈動 → 力場有生命感
            val pulse = 0.92f + 0.08f * sin(time * 1.5f)
            for (ring in 0 until RING_COUNT) {
                val rad = minDim * (0.045f + ring * 0.038f) * pulse
                val a = RING_ALPHA * (1f - ring.toFloat() / RING_COUNT * 0.5f)
                var prevX = 0f; var prevY = 0f
                for (seg in 0..RING_SEG) {
                    val ang = TWO_PI * seg / RING_SEG + time * 0.2f * (if (ring % 2 == 0) 1f else -1f)
                    val px = cx + cos(ang) * rad / vwHalf
                    val py = cy + sin(ang) * rad / vhHalf
                    if (seg > 0) {
                        ringFloats.put(prevX).put(prevY).put(cr).put(cg).put(cb).put(a)
                        ringFloats.put(px).put(py).put(cr).put(cg).put(cb).put(a)
                        verts += 2
                    }
                    prevX = px; prevY = py
                }
            }
        }
        if (verts == 0) return

        GLES20.glUseProgram(ringProgram)
        GLES20.glLineWidth(2f)
        GLES20.glEnableVertexAttribArray(rgPosLoc)
        GLES20.glEnableVertexAttribArray(rgColLoc)
        ringBuf.position(0)
        GLES20.glVertexAttribPointer(rgPosLoc, 2, GLES20.GL_FLOAT, false, BYTES_PER_LINE, ringBuf)
        ringBuf.position(8)
        GLES20.glVertexAttribPointer(rgColLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_LINE, ringBuf)
        ringBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, verts)
        GLES20.glDisableVertexAttribArray(rgPosLoc)
        GLES20.glDisableVertexAttribArray(rgColLoc)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_LEAF_VERT = 32   // 8 floats × 4 (pos2 uv2 col4)
        private const val BYTES_PER_LINE      = 24   // 6 floats × 4 (pos2 col4)
        private const val BYTES_PER_VERT_VINE = 32   // 8 floats × 4 (pos2 col4 dist1 trail1)
        private const val MAX_LEAVES          = 48
        private const val MAX_HEADS           = 8
        private const val MAX_TRAIL_POINTS    = 256
        private const val MAX_RESAMPLE        = 64
        private const val RING_COUNT          = 4
        private const val RING_SEG            = 32
        private const val RING_ALPHA          = 0.16f
        private const val VINE_HALF_WIDTH     = 0.030f
        private const val VINE_AMP            = 0.018f  // 藤蔓蜿蜒振幅（NDC）
        private const val VINE_FREQ           = 2.0f
        private const val VINE_SPEED          = 4.0f
        private const val PI_F                = Math.PI.toFloat()
        private const val TWO_PI              = (Math.PI * 2).toFloat()
        private const val TIME_WRAP           = 120f

        private val VINE_VERT = """
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

        // 藤蔓：邊緣被雜訊咬成葉緣鋸齒，中肋亮線，尾端漸枯
        private val VINE_FRAG = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;

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

                // 葉緣鋸齒：高頻雜訊撕邊
                float n  = noise(vec2(vTrailDist * 40.0, vCenterDist * 3.0));
                float cut = 0.80 + (n - 0.5) * 0.55;
                float body = 1.0 - smoothstep(cut - 0.12, cut + 0.04, d);

                // 尾端漸枯：雜訊把尾巴啃出缺口
                float wither = smoothstep(life * 1.1, life * 1.1 + 0.22, n);
                body *= 1.0 - wither * 0.7;
                if (body <= 0.004) discard;

                // 中肋亮線（葉脈），本體 = 陀螺色，邊緣壓深
                float vein = 1.0 - smoothstep(0.0, 0.22, d);
                vec3 col = mix(vColor.rgb * 0.55, vColor.rgb, smoothstep(0.0, 0.6, 1.0 - d));
                col = mix(col, vec3(1.0), vein * 0.40);

                float a = body * (0.45 + 0.55 * life);
                gl_FragColor = vec4(col, min(a, 1.0));
            }""".trimIndent()

        private val LEAF_VERT = """
            attribute vec2 aPosition;
            attribute vec2 aUV;
            attribute vec4 aColor;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vUV = aUV;
                vColor = aColor;
            }""".trimIndent()

        // 梭形葉刃：兩頭收縮針狀（沿 u 軸尖銳），中肋反光提亮成白（像碎玻璃刃口）
        private val LEAF_FRAG = """
            precision mediump float;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                float u = vUV.x;
                float v = vUV.y;
                // 兩頭收縮的半寬輪廓（pow>1 → 更尖的針狀）
                float prof = pow(max(0.0, 1.0 - u * u), 0.65);
                float d = abs(v) / max(prof, 0.001);
                if (d > 1.0) discard;
                float edge = 1.0 - smoothstep(0.72, 1.0, d);
                // 中肋亮線（葉脈 / 刃口反光）
                float vein = 1.0 - smoothstep(0.0, 0.16, abs(v));
                vec3 col = mix(vColor.rgb, vec3(1.0), vein * 0.6);
                gl_FragColor = vec4(col, vColor.a * edge);
            }""".trimIndent()

        private val RING_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }""".trimIndent()

        private val RING_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }""".trimIndent()
    }
}
