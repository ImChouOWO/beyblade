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
 * 水墨橫空 effect — 飛白乾筆殘影：
 *
 *   ① 主墨帶（= 軌跡本體）：核心飽和焦墨（濃、深），向兩側法線過渡到半透明微濕行墨，
 *      濃淡層次（Shading）速度感極強。高速帶過時露出不規則飛白白隙（露背景），
 *      中段與尾端出現像毛筆開叉的縱向分束。
 *   ② 破空弧線 / 氣流亂流：主墨帶周圍幾條極細、帶弧度的動態墨線（隨時間擺盪），
 *      與主帶重疊 → 煙灰深灰的堆墨層次；多軌交織時更明顯。
 *   ③ 墨滴飛濺：沿墨帶偶爾甩出墨滴。
 *   ④ 收尾 Dissolve：尾端不平淡變透明，而是噪點侵蝕、微粒化煙散（像墨跡風乾、
 *      被風吹散細沙），約 0.15 秒蒸發殆盡 → 乾淨留白、俐落歸於虛空。
 *
 * 色調完全跟隨陀螺中心偵測色（逐軌道各自上色），核心壓暗成焦墨、邊緣淡成行墨。
 * 所有每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class InkWashGLEffect : GLEffect() {

    // ── 墨帶 ribbon program ────────────────────────────────────────────────
    private var inkProgram = 0
    private var iPosLoc = -1; private var iColLoc = -1
    private var iDistLoc = -1; private var iTrailLoc = -1
    private var iTimeLoc = -1; private var iStrandLoc = -1

    // ── 墨滴 / 微粒 point program ──────────────────────────────────────────
    private var dropProgram = 0
    private var dPosLoc = -1; private var dColLoc = -1; private var dSizeLoc = -1; private var dDisLoc = -1

    // ── 墨滴（飛濺後微粒化煙散） ────────────────────────────────────────────
    private class Drop {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f          // px/frame
        var sizePx = 6f; var grow = 0.02f
        var age = 0f; var life = 30f      // frames（30fps 基準）
        var r = 0.2f; var g = 0.2f; var b = 0.2f
    }
    private val drops = Array(MAX_DROPS) { Drop() }
    private val dropBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_DROPS * BYTES_PER_DROP).order(ByteOrder.nativeOrder())
    private val dropFloats: FloatBuffer = dropBuf.asFloatBuffer()

    private var time = 0f
    private var vwHalf = 1f
    private var vhHalf = 1f

    // 墨帶重採樣
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val rX  = FloatArray(MAX_RESAMPLE)
    private val rY  = FloatArray(MAX_RESAMPLE)
    private val rA  = FloatArray(MAX_RESAMPLE)
    private val cum = FloatArray(MAX_RESAMPLE)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        inkProgram = GLHelper.buildProgram(INK_VERT, INK_FRAG)
        iPosLoc   = GLES20.glGetAttribLocation(inkProgram, "aPosition")
        iColLoc   = GLES20.glGetAttribLocation(inkProgram, "aColor")
        iDistLoc  = GLES20.glGetAttribLocation(inkProgram, "aCenterDist")
        iTrailLoc = GLES20.glGetAttribLocation(inkProgram, "aTrailDist")
        iTimeLoc  = GLES20.glGetUniformLocation(inkProgram, "uTime")
        iStrandLoc = GLES20.glGetUniformLocation(inkProgram, "uStrandAlpha")

        dropProgram = GLHelper.buildProgram(DROP_VERT, DROP_FRAG)
        dPosLoc  = GLES20.glGetAttribLocation(dropProgram, "aPosition")
        dColLoc  = GLES20.glGetAttribLocation(dropProgram, "aColor")
        dSizeLoc = GLES20.glGetAttribLocation(dropProgram, "aSize")
        dDisLoc  = GLES20.glGetAttribLocation(dropProgram, "aDissolve")
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

        // ①② 墨帶 + 破空弧線（多束疊出堆墨層次）
        GLES20.glUseProgram(inkProgram)
        GLES20.glUniform1f(iTimeLoc, time)
        GLES20.glEnableVertexAttribArray(iPosLoc)
        GLES20.glEnableVertexAttribArray(iColLoc)
        GLES20.glEnableVertexAttribArray(iDistLoc)
        GLES20.glEnableVertexAttribArray(iTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size < 3) continue
            // 先畫極細破空弧線（墊底堆墨），再畫主墨帶（壓在最上）
            for (s in STRAND_COUNT - 1 downTo 0) drawInkStrand(pts, ctx, s)
        }
        GLES20.glDisableVertexAttribArray(iPosLoc)
        GLES20.glDisableVertexAttribArray(iColLoc)
        GLES20.glDisableVertexAttribArray(iDistLoc)
        GLES20.glDisableVertexAttribArray(iTrailLoc)

        // ③④ 墨滴飛濺 + 微粒化煙散
        spawnDrops(trackData, ctx)
        updateDrops(ctx)
        drawDrops()
    }

    // ── ①② 墨帶（strand 0 = 主帶；其餘 = 極細破空弧線） ───────────────────

    private fun drawInkStrand(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext, strand: Int) {
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
        if (m * 2 * BYTES_PER_VERT_INK > ctx.ribbonBuf.capacity()) return

        val c  = pts.last().first.color
        val cr = (c shr 16 and 0xFF) / 255f
        val cg = (c shr  8 and 0xFF) / 255f
        val cb = (c        and 0xFF) / 255f

        val isMain = strand == 0
        val hwBase = if (isMain) INK_HALF_WIDTH else INK_HALF_WIDTH * 0.16f
        val sideSign = if (strand % 2 == 1) 1f else -1f
        val ampMult = if (isMain) 0.30f else 1f                 // 主帶幾乎不偏，弧線擺盪大
        val phase = strand * 1.7f
        GLES20.glUniform1f(iStrandLoc, if (isMain) 1f else 0.45f)

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
            // 帶弧度的動態墨線：沿法線方向隨時間擺盪（破空亂流），尾端甩動更大
            val wave = sin(u * INK_FREQ * 2f * PI_F + phase - time * INK_SWAY)
            val off  = wave * INK_AMP * ampMult * (1f - 0.4f * u) + sideSign * hwBase * (if (isMain) 0f else 2.2f)
            val hw   = hwBase * (0.30f + 0.70f * life)
            val cx   = x + nx * off
            val cy   = y + ny * off
            val trail = totalLen - cum[j]
            ctx.ribbonFloats.put(cx - nx*hw).put(cy - ny*hw).put(cr).put(cg).put(cb).put(life).put(-1f).put(trail)
            ctx.ribbonFloats.put(cx + nx*hw).put(cy + ny*hw).put(cr).put(cg).put(cb).put(life).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(iPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_INK, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(iColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_INK, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(iDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_INK, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(iTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_INK, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, m * 2)
    }

    // ── ③④ 墨滴 + 微粒化煙散 ──────────────────────────────────────────────

    private fun spawnDrops(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)
        for ((_, pts) in trackData) {
            if (pts.size < 3) continue
            // 沿墨帶偏中後段偶爾甩出墨滴（克制 → 保留水墨乾淨）
            if (Math.random() < DROP_RATE * ctx.dtScale) {
                val idx = (Math.random() * pts.size * 0.7).toInt().coerceAtMost(pts.size - 1)
                val tp = pts[idx].first
                spawnOneDrop(
                    (tp.center.x * 2f - 1f) * ctx.quadScaleX,
                    (1f - tp.center.y * 2f) * ctx.quadScaleY,
                    minDim, pts.last().first.color)
            }
        }
    }

    private fun spawnOneDrop(x: Float, y: Float, minDim: Float, color: Int) {
        for (dp in drops) {
            if (dp.active) continue
            val angle = Math.random().toFloat() * TWO_PI
            val speed = minDim * (0.002f + Math.random().toFloat() * 0.004f)
            dp.active = true
            dp.x = x + (Math.random().toFloat() - 0.5f) * 0.02f
            dp.y = y + (Math.random().toFloat() - 0.5f) * 0.02f
            dp.vx = cos(angle) * speed
            dp.vy = sin(angle) * speed
            dp.sizePx = minDim * (0.006f + Math.random().toFloat() * 0.010f)
            dp.grow = 0.015f + Math.random().toFloat() * 0.02f
            dp.age = 0f
            dp.life = 18f + Math.random().toFloat() * 16f         // 短命 → 俐落煙散
            dp.r = (color shr 16 and 0xFF) / 255f * 0.6f          // 墨滴偏濃（壓暗）
            dp.g = (color shr  8 and 0xFF) / 255f * 0.6f
            dp.b = (color        and 0xFF) / 255f * 0.6f
            return
        }
    }

    private fun updateDrops(ctx: GLRenderContext) {
        val dt = ctx.dtScale
        for (dp in drops) {
            if (!dp.active) continue
            dp.x += dp.vx * dt / vwHalf
            dp.y += dp.vy * dt / vhHalf
            dp.vx *= 1f - 0.04f * dt
            dp.vy *= 1f - 0.04f * dt
            dp.sizePx *= 1f + dp.grow * dt                        // 邊風乾邊鬆散擴大
            dp.age += dt
            if (dp.age >= dp.life) dp.active = false
        }
    }

    private fun drawDrops() {
        dropFloats.clear()
        var count = 0
        for (dp in drops) {
            if (!dp.active) continue
            val dissolve = (dp.age / dp.life).coerceIn(0f, 1f)   // 0 實 → 1 散盡
            val a = (1f - dissolve) * 0.9f
            dropFloats.put(dp.x).put(dp.y).put(dp.r).put(dp.g).put(dp.b).put(a)
                .put(dp.sizePx).put(dissolve)
            count++
        }
        if (count == 0) return

        GLES20.glUseProgram(dropProgram)
        GLES20.glEnableVertexAttribArray(dPosLoc)
        GLES20.glEnableVertexAttribArray(dColLoc)
        GLES20.glEnableVertexAttribArray(dSizeLoc)
        GLES20.glEnableVertexAttribArray(dDisLoc)
        dropBuf.position(0)
        GLES20.glVertexAttribPointer(dPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_DROP, dropBuf)
        dropBuf.position(8)
        GLES20.glVertexAttribPointer(dColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_DROP, dropBuf)
        dropBuf.position(24)
        GLES20.glVertexAttribPointer(dSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_DROP, dropBuf)
        dropBuf.position(28)
        GLES20.glVertexAttribPointer(dDisLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_DROP, dropBuf)
        dropBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(dPosLoc)
        GLES20.glDisableVertexAttribArray(dColLoc)
        GLES20.glDisableVertexAttribArray(dSizeLoc)
        GLES20.glDisableVertexAttribArray(dDisLoc)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT_INK = 32   // 8 floats × 4 (pos2 col4 dist1 trail1)
        private const val BYTES_PER_DROP     = 32   // 8 floats × 4 (pos2 col4 size1 dissolve1)
        private const val MAX_DROPS          = 32
        private const val MAX_TRAIL_POINTS   = 256
        private const val MAX_RESAMPLE       = 64
        private const val STRAND_COUNT       = 3    // 1 主墨帶 + 2 極細破空弧線
        private const val INK_HALF_WIDTH     = 0.040f
        private const val INK_AMP            = 0.022f  // 破空弧線擺盪振幅（NDC）
        private const val INK_FREQ           = 1.6f
        private const val INK_SWAY           = 3.0f
        private const val DROP_RATE          = 0.25f
        private const val PI_F               = Math.PI.toFloat()
        private const val TWO_PI             = (Math.PI * 2).toFloat()
        private const val TIME_WRAP          = 120f

        private val INK_VERT = """
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

        // 墨帶：焦墨核心 → 微濕行墨邊緣（濃淡層次）；飛白縱向白隙；毛筆開叉分束；
        // 尾端噪點侵蝕、微粒化蒸發（不平淡變透明）→ 乾淨留白。
        private val INK_FRAG = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            uniform float uStrandAlpha;

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

                // 濃淡層次：核心濃（density=1）→ 兩側淡（density=0）
                float density = 1.0 - smoothstep(0.0, 1.0, d);

                // 焦墨核心（壓暗陀螺色）→ 微濕行墨邊緣（原陀螺色、半透明）
                vec3 jiao = vColor.rgb * 0.42;
                vec3 col  = mix(vColor.rgb, jiao, smoothstep(0.25, 0.95, density));

                // 飛白：沿筆觸方向的條狀噪點 → 不規則白色空隙（速度感、往中後段加劇）
                float fb  = noise(vec2(vTrailDist * 70.0, vCenterDist * 7.0)) * 0.6
                          + noise(vec2(vTrailDist * 24.0, vCenterDist * 3.0)) * 0.4;
                float fbAmt = 0.22 + smoothstep(0.0, 0.6, tail) * 0.55;
                float feibai = 1.0 - smoothstep(1.0 - fbAmt, 1.0, fb);

                // 毛筆開叉：低頻噪點把中後段墨帶縱向撕成幾束
                float fork = smoothstep(0.40, 0.62, noise(vec2(vTrailDist * 6.0, vCenterDist * 1.6)));
                float forkCut = 1.0 - fork * smoothstep(0.2, 0.85, tail) * 0.7;

                // 收尾 Dissolve：尾端噪點侵蝕、微粒化蒸發（陡峭 → 俐落留白）
                float dis = smoothstep(life * 1.08, life * 1.08 + 0.10, fb);

                float body = density * (0.35 + 0.65 * density);
                body *= feibai * forkCut * (1.0 - dis);
                if (body <= 0.004) discard;

                float a = body * (0.55 + 0.45 * life) * uStrandAlpha;
                gl_FragColor = vec4(col, min(a, 1.0));
            }""".trimIndent()

        private val DROP_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            attribute float aDissolve;
            varying vec4 vColor;
            varying float vDissolve;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
                vDissolve = aDissolve;
            }""".trimIndent()

        // 墨滴：圓潤墨點；隨 dissolve 上升被噪點咬碎 → 微粒化煙散（非平淡變透明）
        private val DROP_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vDissolve;
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
                vec2 c = gl_PointCoord - vec2(0.5);
                float r2 = dot(c, c) * 4.0;
                if (r2 > 1.0) discard;
                float base = exp(-r2 * 2.0);
                // 微粒化：噪點侵蝕，dissolve 越高破得越碎（煙散）
                float n = noise(gl_PointCoord * 9.0);
                if (n < vDissolve) discard;
                float a = vColor.a * base;
                if (a < 0.02) discard;
                gl_FragColor = vec4(vColor.rgb, a);
            }""".trimIndent()
    }
}
