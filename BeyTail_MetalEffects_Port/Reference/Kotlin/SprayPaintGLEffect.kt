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
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 噴漆塗鴉 effect — Splatoon 風格鮮豔噴漆：
 *   ① 噴漆拖尾（= 軌跡本體）：實心漆芯 + 邊緣噪點碎成噴霧顆粒（硬邊顆粒感），
 *      尾端漸散成噴點消失（噴漆飛白感）。
 *   ② 漆塊潑濺：沿軌跡甩出不規則有機漆塊（墨漬輪廓），噴上後快速擴張定住、淡掉。
 *   ③ 噴霧細點：周圍細小 overspray 點。
 *
 * 顏色跟隨陀螺中心色，但拉高飽和/亮度讓它「色彩鮮明」（Splatoon 感）。
 * 所有每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class SprayPaintGLEffect : GLEffect() {

    // ── 噴漆拖尾 ribbon program ────────────────────────────────────────────
    private var paintProgram = 0
    private var pPosLoc = -1; private var pColLoc = -1
    private var pDistLoc = -1; private var pTrailLoc = -1; private var pTimeLoc = -1

    // ── 漆塊 / 噴霧 point program ──────────────────────────────────────────
    private var splatProgram = 0
    private var sPosLoc = -1; private var sColLoc = -1; private var sSizeLoc = -1; private var sSeedLoc = -1

    // ── 漆塊 / 噴霧細點（共用結構） ────────────────────────────────────────
    private class Blob {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f          // px/frame
        var sizePx = 10f; var grow = 0f
        var alpha = 0f; var decay = 0.04f
        var r = 1f; var g = 1f; var b = 1f
        var seed = 0f
    }
    private val splats = Array(MAX_SPLATS) { Blob() }
    private val mist   = Array(MAX_MIST) { Blob() }
    private val splatBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_SPLATS * BYTES_PER_BLOB).order(ByteOrder.nativeOrder())
    private val splatFloats: FloatBuffer = splatBuf.asFloatBuffer()
    private val mistBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_MIST * BYTES_PER_BLOB).order(ByteOrder.nativeOrder())
    private val mistFloats: FloatBuffer = mistBuf.asFloatBuffer()

    private val lastPos = HashMap<Int, Pair<Float, Float>>(8)
    private var time = 0f
    private var vwHalf = 1f
    private var vhHalf = 1f

    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val cum = FloatArray(MAX_TRAIL_POINTS)
    private val vividRGB = FloatArray(3)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        paintProgram = GLHelper.buildProgram(PAINT_VERT, PAINT_FRAG)
        pPosLoc   = GLES20.glGetAttribLocation(paintProgram, "aPosition")
        pColLoc   = GLES20.glGetAttribLocation(paintProgram, "aColor")
        pDistLoc  = GLES20.glGetAttribLocation(paintProgram, "aCenterDist")
        pTrailLoc = GLES20.glGetAttribLocation(paintProgram, "aTrailDist")
        pTimeLoc  = GLES20.glGetUniformLocation(paintProgram, "uTime")

        splatProgram = GLHelper.buildProgram(SPLAT_VERT, SPLAT_FRAG)
        sPosLoc  = GLES20.glGetAttribLocation(splatProgram, "aPosition")
        sColLoc  = GLES20.glGetAttribLocation(splatProgram, "aColor")
        sSizeLoc = GLES20.glGetAttribLocation(splatProgram, "aSize")
        sSeedLoc = GLES20.glGetAttribLocation(splatProgram, "aSeed")
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

        // 漆塊潑濺墊底（被拖尾蓋住一部分 → 像噴在底層）
        updateBlobs(splats, ctx)
        drawBlobs(splats, splatBuf, splatFloats)

        // ① 噴漆拖尾
        GLES20.glUseProgram(paintProgram)
        GLES20.glUniform1f(pTimeLoc, time)
        GLES20.glEnableVertexAttribArray(pPosLoc)
        GLES20.glEnableVertexAttribArray(pColLoc)
        GLES20.glEnableVertexAttribArray(pDistLoc)
        GLES20.glEnableVertexAttribArray(pTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 3) drawPaintTrail(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(pPosLoc)
        GLES20.glDisableVertexAttribArray(pColLoc)
        GLES20.glDisableVertexAttribArray(pDistLoc)
        GLES20.glDisableVertexAttribArray(pTrailLoc)

        // ②③ 補生漆塊 + 噴霧；噴霧畫在最上層
        spawnFromTrack(trackData, ctx)
        updateBlobs(mist, ctx)
        drawBlobs(mist, mistBuf, mistFloats)
    }

    // ── ① 噴漆拖尾 ──────────────────────────────────────────────────────────

    private fun drawPaintTrail(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = pts.size.coerceAtMost(MAX_TRAIL_POINTS)
        if (n < 3 || n * 2 * BYTES_PER_VERT_PAINT > ctx.ribbonBuf.capacity()) return

        vivid(pts.last().first.color, vividRGB)
        val cr = vividRGB[0]; val cg = vividRGB[1]; val cb = vividRGB[2]

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
            cum[i] = if (i == 0) 0f else {
                val dx = ptX[i] - ptX[i-1]; val dy = ptY[i] - ptY[i-1]
                cum[i-1] + sqrt(dx * dx + dy * dy)
            }
        }

        ctx.ribbonFloats.clear()
        for (i in 0 until n) {
            val x = ptX[i]; val y = ptY[i]
            val (nx, ny) = when {
                i == 0     -> GLHelper.segNormal(x, y, ptX[1], ptY[1])
                i == n - 1 -> GLHelper.segNormal(ptX[n-2], ptY[n-2], x, y)
                else       -> GLHelper.avgNormal(ptX[i-1], ptY[i-1], x, y, ptX[i+1], ptY[i+1])
            }
            val alpha = pts[i].second
            val hw    = TRAIL_HALF_WIDTH * (0.45f + 0.55f * alpha)
            val trail = cum[i]
            ctx.ribbonFloats.put(x - nx*hw).put(y - ny*hw).put(cr).put(cg).put(cb).put(alpha).put(-1f).put(trail)
            ctx.ribbonFloats.put(x + nx*hw).put(y + ny*hw).put(cr).put(cg).put(cb).put(alpha).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(pPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_PAINT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(pColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_PAINT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(pDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_PAINT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(pTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_PAINT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, n * 2)
    }

    // ── ②③ 漆塊 + 噴霧 spawn ──────────────────────────────────────────────

    private fun spawnFromTrack(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)

        for ((trackId, pts) in trackData) {
            if (pts.size < 2) continue
            val (tp,  _) = pts.last()
            val (tp1, _) = pts[pts.size - 2]
            val x  = (tp.center.x  * 2f - 1f) * ctx.quadScaleX
            val y  = (1f - tp.center.y  * 2f) * ctx.quadScaleY
            val x1 = (tp1.center.x * 2f - 1f) * ctx.quadScaleX
            val y1 = (1f - tp1.center.y * 2f) * ctx.quadScaleY
            val dx = x - x1; val dy = y - y1
            val moveLen = sqrt(dx * dx + dy * dy)
            val moveAngle = atan2(dy * vh, dx * vw)
            val color = tp.color

            // 噴霧 overspray：頭部周圍持續細點
            var mistN = MIST_PER_FRAME * ctx.dtScale
            while (mistN > 0f) {
                if (mistN < 1f && Math.random() > mistN) break
                spawnMist(x, y, minDim, color)
                mistN -= 1f
            }

            val last = lastPos[trackId]
            val dist = if (last != null) {
                val ldx = x - last.first; val ldy = y - last.second
                sqrt(ldx * ldx + ldy * ldy)
            } else Float.MAX_VALUE

            if (dist > 0.006f) {
                lastPos[trackId] = x to y
                val moveNorm = moveLen / ctx.dtScale
                // 移動中往兩側甩小漆塊（漆甩出去）
                if (moveNorm > 0.010f && Math.random() > 0.45f) {
                    val side = if (Math.random() > 0.5f) 1f else -1f
                    spawnSplat(x, y, moveAngle + side * 1.4f, minDim, color, big = false)
                }
                // 猛烈位移：往後甩出較大漆塊
                if (moveNorm > 0.018f) {
                    val back = moveAngle + PI_F
                    var k = 0
                    while (k < 2) {
                        spawnSplat(x, y, back + (Math.random().toFloat() - 0.5f) * 1.2f,
                            minDim, color, big = true); k++
                    }
                }
            }
        }
    }

    private fun spawnSplat(x: Float, y: Float, angle: Float, minDim: Float, color: Int, big: Boolean) {
        for (b in splats) {
            if (b.active) continue
            val speed = if (big) minDim * (0.006f + Math.random().toFloat() * 0.010f)
                        else     minDim * (0.004f + Math.random().toFloat() * 0.006f)
            b.active = true
            b.x = x + (Math.random().toFloat() - 0.5f) * 0.02f
            b.y = y + (Math.random().toFloat() - 0.5f) * 0.02f
            b.vx = cos(angle) * speed
            b.vy = sin(angle) * speed
            b.sizePx = if (big) minDim * (0.020f + Math.random().toFloat() * 0.020f)
                       else     minDim * (0.010f + Math.random().toFloat() * 0.010f)
            b.grow  = 0.12f + Math.random().toFloat() * 0.08f      // 噴上後快速擴張
            b.alpha = 1f
            b.decay = if (big) 0.025f + Math.random().toFloat() * 0.02f
                      else     0.04f + Math.random().toFloat() * 0.03f
            b.seed  = Math.random().toFloat() * TWO_PI
            vivid(color, vividRGB, (Math.random().toFloat() - 0.5f) * 0.2f)
            b.r = vividRGB[0]; b.g = vividRGB[1]; b.b = vividRGB[2]
            return
        }
    }

    private fun spawnMist(x: Float, y: Float, minDim: Float, color: Int) {
        for (b in mist) {
            if (b.active) continue
            val angle = Math.random().toFloat() * TWO_PI
            val speed = minDim * (0.002f + Math.random().toFloat() * 0.006f)
            b.active = true
            b.x = x + (Math.random().toFloat() - 0.5f) * 0.04f
            b.y = y + (Math.random().toFloat() - 0.5f) * 0.04f
            b.vx = cos(angle) * speed
            b.vy = sin(angle) * speed
            b.sizePx = minDim * (0.004f + Math.random().toFloat() * 0.008f)
            b.grow  = 0f
            b.alpha = 0.85f
            b.decay = 0.05f + Math.random().toFloat() * 0.05f       // 噴霧短命
            b.seed  = Math.random().toFloat() * TWO_PI
            vivid(color, vividRGB, (Math.random().toFloat() - 0.5f) * 0.2f)
            b.r = vividRGB[0]; b.g = vividRGB[1]; b.b = vividRGB[2]
            return
        }
    }

    private fun updateBlobs(pool: Array<Blob>, ctx: GLRenderContext) {
        val dt = ctx.dtScale
        for (b in pool) {
            if (!b.active) continue
            b.x += b.vx * dt / vwHalf
            b.y += b.vy * dt / vhHalf
            b.vx *= 1f - 0.18f * dt          // 漆碰到面快速停住
            b.vy *= 1f - 0.18f * dt
            if (b.grow != 0f) {
                b.sizePx *= 1f + b.grow * dt
                b.grow *= 1f - 0.25f * dt     // 擴張漸停
            }
            b.alpha -= b.decay * dt
            if (b.alpha <= 0f) b.active = false
        }
    }

    private fun drawBlobs(pool: Array<Blob>, buf: ByteBuffer, floats: FloatBuffer) {
        floats.clear()
        var count = 0
        for (b in pool) {
            if (!b.active) continue
            floats.put(b.x).put(b.y).put(b.r).put(b.g).put(b.b).put(b.alpha.coerceIn(0f, 1f))
                .put(b.sizePx).put(b.seed)
            count++
        }
        if (count == 0) return

        GLES20.glUseProgram(splatProgram)
        GLES20.glEnableVertexAttribArray(sPosLoc)
        GLES20.glEnableVertexAttribArray(sColLoc)
        GLES20.glEnableVertexAttribArray(sSizeLoc)
        GLES20.glEnableVertexAttribArray(sSeedLoc)
        buf.position(0)
        GLES20.glVertexAttribPointer(sPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_BLOB, buf)
        buf.position(8)
        GLES20.glVertexAttribPointer(sColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_BLOB, buf)
        buf.position(24)
        GLES20.glVertexAttribPointer(sSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_BLOB, buf)
        buf.position(28)
        GLES20.glVertexAttribPointer(sSeedLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_BLOB, buf)
        buf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(sPosLoc)
        GLES20.glDisableVertexAttribArray(sColLoc)
        GLES20.glDisableVertexAttribArray(sSizeLoc)
        GLES20.glDisableVertexAttribArray(sSeedLoc)
    }

    /** 取陀螺色 → 拉高飽和與亮度（鮮豔噴漆）。lightJitter 可加微亮度變化。 */
    private fun vivid(c: Int, out: FloatArray, lightJitter: Float = 0f) {
        var r = (c shr 16 and 0xFF) / 255f
        var g = (c shr  8 and 0xFF) / 255f
        var b = (c        and 0xFF) / 255f
        val lum = 0.299f * r + 0.587f * g + 0.114f * b
        val sat = 1.7f
        r = lum + (r - lum) * sat
        g = lum + (g - lum) * sat
        b = lum + (b - lum) * sat
        val m = maxOf(r, g, b)
        if (m > 1e-4f) { val s = (1f / m).coerceAtMost(1.5f); r *= s; g *= s; b *= s }
        val lj = 1f + lightJitter
        out[0] = (r * lj).coerceIn(0f, 1f)
        out[1] = (g * lj).coerceIn(0f, 1f)
        out[2] = (b * lj).coerceIn(0f, 1f)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT_PAINT = 32   // 8 floats × 4 (pos2 col4 dist1 trail1)
        private const val BYTES_PER_BLOB       = 32   // 8 floats × 4 (pos2 col4 size1 seed1)
        private const val MAX_SPLATS           = 36
        private const val MAX_MIST             = 64
        private const val MAX_TRAIL_POINTS     = 256
        private const val MIST_PER_FRAME       = 2.0f
        private const val TRAIL_HALF_WIDTH     = 0.034f
        private const val PI_F                 = Math.PI.toFloat()
        private const val TWO_PI               = (Math.PI * 2).toFloat()
        private const val TIME_WRAP            = 120f

        private val PAINT_VERT = """
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

        // 噴漆帶：實心漆芯 + 邊緣/尾端噪點碎成噴霧顆粒（硬邊顆粒），鮮豔平塗色
        private val PAINT_FRAG = """
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

                // 實心漆芯（尾端漸退，只剩噴點）
                float core = (1.0 - smoothstep(0.48, 0.60, d)) * smoothstep(0.05, 0.35, life);

                // 噴霧顆粒：邊緣與尾端噪點越多
                float grain = max(noise(vec2(vTrailDist * 60.0, vCenterDist * 34.0)),
                                  noise(vec2(vTrailDist * 130.0 + 3.0, vCenterDist * 72.0)) * 0.85);
                float sprayZone = smoothstep(0.42, 1.05, d) + tail * 0.65;
                float speck = step(sprayZone, grain);              // 硬邊噴點
                float edgeCut = 1.0 - smoothstep(1.0, 1.12, d);

                float body = max(core, speck) * edgeCut;
                if (body < 0.5) discard;

                // 鮮豔平塗 + 細微顆粒明暗
                vec3 col = vColor.rgb * (0.86 + 0.14 * grain);
                gl_FragColor = vec4(col, 0.96);
            }""".trimIndent()

        private val SPLAT_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            attribute float aSeed;
            varying vec4 vColor;
            varying float vSeed;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
                vSeed = aSeed;
            }""".trimIndent()

        // 漆塊：不規則有機輪廓（多頻 sin 擾動半徑）→ 墨漬潑濺感；鮮豔平塗
        private val SPLAT_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vSeed;
            void main() {
                vec2 c = gl_PointCoord - vec2(0.5);
                float ang = atan(c.y, c.x);
                float rad = length(c) * 2.0;
                float wob = 0.80 + 0.12 * sin(ang * 3.0 + vSeed)
                                 + 0.08 * sin(ang * 5.0 - vSeed * 1.7)
                                 + 0.05 * sin(ang * 8.0 + vSeed * 0.5);
                if (rad > wob) discard;
                float a = vColor.a * (1.0 - smoothstep(wob - 0.12, wob, rad));
                gl_FragColor = vec4(vColor.rgb, a);
            }""".trimIndent()
    }
}
