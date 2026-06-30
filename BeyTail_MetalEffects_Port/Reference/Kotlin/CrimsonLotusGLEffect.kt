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
 * 紅蓮破滅 effect — aggressive crimson-lotus fire:
 *   - Living fire tongues: twin serpentine ribbons that writhe left-right along
 *     the trail and roll over time (phase-offset → spiral tumbling), rendered
 *     with a scrolling-noise fire shader (white-gold core → orange → deep crimson)
 *   - Fireballs: irregular polygons blasted outward on hard moves, violently
 *     expanding while they burn out (white-hot centre, crimson rim)
 *   - Heat haze: when a fireball evaporates it leaves a barely-visible warm
 *     shimmer blob that grows slowly and fades out over ~1.5s
 *
 * 顏色以陀螺中心偵測色為基底（與其他特效一致）：白熱核心 → 飽和本體色 → 深色邊緣。
 * 所有每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class CrimsonLotusGLEffect : GLEffect() {

    // ── 火舌 ribbon program（noise 火焰 shader） ──────────────────────────
    private var fireProgram = 0
    private var fPosLoc = -1; private var fColLoc = -1
    private var fDistLoc = -1; private var fTrailLoc = -1
    private var fTimeLoc = -1

    // ── 火球 polygon program ──────────────────────────────────────────────
    private var polyProgram = 0
    private var pPosLoc = -1; private var pColLoc = -1; private var pDistLoc = -1

    // ── 熱浪 point program ────────────────────────────────────────────────
    private var hazeProgram = 0
    private var hPosLoc = -1; private var hColLoc = -1; private var hSizeLoc = -1

    // ── 火球（不規則多邊形，劇烈擴張） ────────────────────────────────────
    private class Fireball {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f        // px/frame
        var grow = 1f                   // 每幀尺寸倍率基準（×dtScale 調整）
        var scale = 1f
        var alpha = 0f; var decay = 0.09f
        var vertexCount = 5
        val ox = FloatArray(6)          // 多邊形頂點偏移（px，未縮放）
        val oy = FloatArray(6)
        var r = 1f; var g = 0.4f; var b = 0.1f
    }
    private val fireballs = Array(MAX_FIREBALLS) { Fireball() }
    private val polyBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_FIREBALLS * 18 * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val polyFloats: FloatBuffer = polyBuf.asFloatBuffer()

    // ── 餘燼火星（沿尾跡飄升的燃燒微粒） ──────────────────────────────────
    private class Ember {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f        // px/frame
        var sizePx = 3f
        var alpha = 0f; var decay = 0.06f
        var r = 1f; var g = 0.5f; var b = 0.1f
    }
    private val embers = Array(MAX_EMBERS) { Ember() }
    private val emberBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_EMBERS * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val emberFloats: FloatBuffer = emberBuf.asFloatBuffer()

    // ── 熱空氣折射殘影（極淡、緩慢淡出） ──────────────────────────────────
    private class Haze {
        var active = false
        var x = 0f; var y = 0f
        var sizePx = 30f
        var alpha = 0f
    }
    private val hazes = Array(MAX_HAZE) { Haze() }
    private val hazeBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_HAZE * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val hazeFloats: FloatBuffer = hazeBuf.asFloatBuffer()

    private val lastPos = HashMap<Int, Pair<Float, Float>>(8)
    private var time = 0f

    // 重採樣中心線（火舌蛇形需要平滑曲線）
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val rX  = FloatArray(MAX_RESAMPLE)
    private val rY  = FloatArray(MAX_RESAMPLE)
    private val rA  = FloatArray(MAX_RESAMPLE)
    private val cum = FloatArray(MAX_RESAMPLE)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        fireProgram = GLHelper.buildProgram(FIRE_VERT, FIRE_FRAG)
        fPosLoc   = GLES20.glGetAttribLocation(fireProgram, "aPosition")
        fColLoc   = GLES20.glGetAttribLocation(fireProgram, "aColor")
        fDistLoc  = GLES20.glGetAttribLocation(fireProgram, "aCenterDist")
        fTrailLoc = GLES20.glGetAttribLocation(fireProgram, "aTrailDist")
        fTimeLoc  = GLES20.glGetUniformLocation(fireProgram, "uTime")

        polyProgram = GLHelper.buildProgram(POLY_VERT, POLY_FRAG)
        pPosLoc  = GLES20.glGetAttribLocation(polyProgram, "aPosition")
        pColLoc  = GLES20.glGetAttribLocation(polyProgram, "aColor")
        pDistLoc = GLES20.glGetAttribLocation(polyProgram, "aCenterDist")

        hazeProgram = GLHelper.buildProgram(HAZE_VERT, HAZE_FRAG)
        hPosLoc  = GLES20.glGetAttribLocation(hazeProgram, "aPosition")
        hColLoc  = GLES20.glGetAttribLocation(hazeProgram, "aColor")
        hSizeLoc = GLES20.glGetAttribLocation(hazeProgram, "aSize")
    }

    // ── draw ──────────────────────────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        time += (1f / 30f) * ctx.dtScale
        if (time > TIME_WRAP) time -= TIME_WRAP

        // 熱浪墊底（在火焰下層才像空氣折射殘留）
        updateHaze(ctx.dtScale)
        drawHaze(ctx)

        GLES20.glUseProgram(fireProgram)
        GLES20.glUniform1f(fTimeLoc, time)
        GLES20.glEnableVertexAttribArray(fPosLoc)
        GLES20.glEnableVertexAttribArray(fColLoc)
        GLES20.glEnableVertexAttribArray(fDistLoc)
        GLES20.glEnableVertexAttribArray(fTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 3) drawFireTongues(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(fPosLoc)
        GLES20.glDisableVertexAttribArray(fColLoc)
        GLES20.glDisableVertexAttribArray(fDistLoc)
        GLES20.glDisableVertexAttribArray(fTrailLoc)

        spawnFromTrack(trackData, ctx)
        updateFireballs(ctx)
        drawFireballs(ctx)
        updateEmbers(ctx)
        drawEmbers(ctx)
    }

    // ── 活火舌：蛇形扭動 + 雙股翻滾 ───────────────────────────────────────

    private fun drawFireTongues(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = min(pts.size, MAX_TRAIL_POINTS)
        if (n < 3) return

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
        }
        // ×3 重採樣讓蛇形曲線平滑
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
        if (m * 2 * BYTES_PER_VERT_FIRE > ctx.ribbonBuf.capacity()) return

        // 陀螺中心色 = 火焰基底色
        val c  = pts.last().first.color
        val cr = (c shr 16 and 0xFF) / 255f
        val cg = (c shr  8 and 0xFF) / 255f
        val cb = (c        and 0xFF) / 255f

        // 兩股火舌：相位差 π → 互相纏繞翻滾
        for (strand in 0 until 2) {
            val phase  = strand * PI_F
            val wMult  = if (strand == 0) 1f else 0.62f
            val aMult  = if (strand == 0) 1f else 0.7f

            ctx.ribbonFloats.clear()
            for (j in 0 until m) {
                val x = rX[j]; val y = rY[j]
                val (nx, ny) = when {
                    j == 0     -> GLHelper.segNormal(x, y, rX[1], rY[1])
                    j == m - 1 -> GLHelper.segNormal(rX[j-1], rY[j-1], x, y)
                    else       -> GLHelper.avgNormal(rX[j-1], rY[j-1], x, y, rX[j+1], rY[j+1])
                }
                val u    = j.toFloat() / (m - 1)           // 0 = 尾, 1 = 頭
                val life = rA[j]
                // 蛇形扭動：頭端緊貼陀螺（振幅 ×(1-u)），尾端自由甩動，隨時間翻滾
                val wave = sin(u * TWIST_FREQ * 2f * PI_F + phase - time * WRIGGLE_SPEED)
                val off  = wave * SERPENT_AMP * (1f - u)
                val hw   = TONGUE_HALF_WIDTH * wMult * (0.30f + 0.70f * life)
                val cx   = x + nx * off
                val cy   = y + ny * off
                val a    = life * aMult
                val trail = totalLen - cum[j]
                ctx.ribbonFloats.put(cx - nx*hw).put(cy - ny*hw).put(cr).put(cg).put(cb).put(a).put(-1f).put(trail)
                ctx.ribbonFloats.put(cx + nx*hw).put(cy + ny*hw).put(cr).put(cg).put(cb).put(a).put(+1f).put(trail)
            }

            ctx.ribbonBuf.position(0)
            GLES20.glVertexAttribPointer(fPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FIRE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(8)
            GLES20.glVertexAttribPointer(fColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FIRE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(24)
            GLES20.glVertexAttribPointer(fDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FIRE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(28)
            GLES20.glVertexAttribPointer(fTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FIRE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(0)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, m * 2)
        }
    }

    // ── Spawning ──────────────────────────────────────────────────────────

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

            val last = lastPos[trackId]
            val dist = if (last != null) {
                val ldx = x - last.first; val ldy = y - last.second
                sqrt(ldx * ldx + ldy * ldy)
            } else Float.MAX_VALUE

            // 尾部餘燼：沿軌跡偏尾段持續飄出燃燒火星（不受 dist 節流，燒不停）
            if (pts.size >= 4 && Math.random() < 0.55f * ctx.dtScale) {
                val idx = (Math.random() * pts.size * 0.6).toInt().coerceAtMost(pts.size - 1)
                val etp = pts[idx].first
                spawnEmber(
                    (etp.center.x * 2f - 1f) * ctx.quadScaleX,
                    (1f - etp.center.y * 2f) * ctx.quadScaleY,
                    tp.color)
            }

            if (dist > 0.006f) {
                lastPos[trackId] = x to y
                val moveNorm = moveLen / ctx.dtScale

                // 移動中持續迸出小火球
                if (moveNorm > 0.010f && Math.random() > 0.4) {
                    spawnFireball(x, y, minDim, big = false, tp.color)
                }
                // 猛烈衝撞：大火球爆發
                if (moveNorm > 0.016f) {
                    var c = 0
                    while (c < 3) { spawnFireball(x, y, minDim, big = true, tp.color); c++ }
                }
            }
        }
    }

    private fun spawnFireball(x: Float, y: Float, minDim: Float, big: Boolean, color: Int) {
        for (fb in fireballs) {
            if (fb.active) continue
            val angle = Math.random().toFloat() * TWO_PI
            val speed = if (big) 8f + Math.random().toFloat() * 8f
                        else     4f + Math.random().toFloat() * 5f
            fb.active = true
            fb.x = x + (Math.random().toFloat() - 0.5f) * 0.015f
            fb.y = y + (Math.random().toFloat() - 0.5f) * 0.015f
            fb.vx = cos(angle) * speed
            fb.vy = sin(angle) * speed
            fb.scale = 1f
            fb.grow  = if (big) 0.17f else 0.12f          // 劇烈擴張（每幀比例，×dt）
            fb.alpha = 1f
            fb.decay = 0.08f + Math.random().toFloat() * 0.04f

            // 不規則多邊形（4~6 頂點，半徑亂數 → 鋸齒張力）
            val basePx = if (big) minDim * (0.012f + Math.random().toFloat() * 0.008f)
                         else     minDim * (0.006f + Math.random().toFloat() * 0.004f)
            fb.vertexCount = 4 + (Math.random() * 3).toInt().coerceAtMost(2)
            for (k in 0 until fb.vertexCount) {
                val a = TWO_PI * k / fb.vertexCount
                val r = basePx * (0.5f + Math.random().toFloat() * 0.8f)
                fb.ox[k] = cos(a) * r
                fb.oy[k] = sin(a) * r
            }
            // 三段亮度之一（基底 = 陀螺色）：深 / 飽和本體 / 提亮
            val cr = (color shr 16 and 0xFF) / 255f
            val cg = (color shr  8 and 0xFF) / 255f
            val cb = (color        and 0xFF) / 255f
            when ((Math.random() * 3).toInt()) {
                0    -> { fb.r = cr * 0.60f;          fb.g = cg * 0.60f;          fb.b = cb * 0.60f }
                1    -> { fb.r = cr;                   fb.g = cg;                   fb.b = cb }
                else -> { fb.r = cr * 0.5f + 0.5f;     fb.g = cg * 0.5f + 0.5f;     fb.b = cb * 0.5f + 0.5f }
            }
            return
        }
    }

    // ── 火球 ──────────────────────────────────────────────────────────────

    private fun updateFireballs(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (fb in fireballs) {
            if (!fb.active) continue
            fb.x += fb.vx * dt / (vw * 0.5f)
            fb.y += fb.vy * dt / (vh * 0.5f)
            fb.vx *= 1f - 0.06f * dt
            fb.vy *= 1f - 0.06f * dt
            fb.scale *= 1f + fb.grow * dt                  // 邊燒邊劇烈撐大
            fb.alpha -= fb.decay * dt
            if (fb.alpha <= 0f) {
                fb.active = false
                // 火光蒸發 → 原地留下熱空氣殘影
                spawnHaze(fb.x, fb.y, minOf(vw, vh))
            }
        }
    }

    private fun drawFireballs(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return

        polyFloats.clear()
        var vertCount = 0
        for (fb in fireballs) {
            if (!fb.active) continue
            val a = fb.alpha.coerceIn(0f, 1f)
            // 火焰閃爍：每幀微抖頂點縮放
            val flicker = 1f + (Math.random().toFloat() - 0.5f) * 0.12f
            val s = fb.scale * flicker

            // 三角扇展開成 GL_TRIANGLES（中心白熱 d=0，邊緣 d=1）
            for (k in 0 until fb.vertexCount) {
                val k2 = (k + 1) % fb.vertexCount
                polyFloats.put(fb.x).put(fb.y).put(fb.r).put(fb.g).put(fb.b).put(a).put(0f)
                polyFloats.put(fb.x + fb.ox[k]  * s / (vw * 0.5f)).put(fb.y + fb.oy[k]  * s / (vh * 0.5f))
                    .put(fb.r).put(fb.g).put(fb.b).put(a).put(1f)
                polyFloats.put(fb.x + fb.ox[k2] * s / (vw * 0.5f)).put(fb.y + fb.oy[k2] * s / (vh * 0.5f))
                    .put(fb.r).put(fb.g).put(fb.b).put(a).put(1f)
                vertCount += 3
            }
        }
        if (vertCount == 0) return

        GLES20.glUseProgram(polyProgram)
        GLES20.glEnableVertexAttribArray(pPosLoc)
        GLES20.glEnableVertexAttribArray(pColLoc)
        GLES20.glEnableVertexAttribArray(pDistLoc)
        polyBuf.position(0)
        GLES20.glVertexAttribPointer(pPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, polyBuf)
        polyBuf.position(8)
        GLES20.glVertexAttribPointer(pColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, polyBuf)
        polyBuf.position(24)
        GLES20.glVertexAttribPointer(pDistLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, polyBuf)
        polyBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
        GLES20.glDisableVertexAttribArray(pPosLoc)
        GLES20.glDisableVertexAttribArray(pColLoc)
        GLES20.glDisableVertexAttribArray(pDistLoc)
    }

    // ── 餘燼火星 ──────────────────────────────────────────────────────────

    private fun spawnEmber(x: Float, y: Float, color: Int) {
        for (em in embers) {
            if (em.active) continue
            em.active = true
            em.x = x + (Math.random().toFloat() - 0.5f) * 0.02f
            em.y = y + (Math.random().toFloat() - 0.5f) * 0.02f
            em.vx = (Math.random().toFloat() - 0.5f) * 3f
            em.vy = 1.5f + Math.random().toFloat() * 2.5f          // 熱氣帶著上飄
            em.sizePx = 2f + Math.random().toFloat() * 2.5f
            em.alpha  = 0.95f
            em.decay  = 0.045f + Math.random().toFloat() * 0.04f
            val cr = (color shr 16 and 0xFF) / 255f
            val cg = (color shr  8 and 0xFF) / 255f
            val cb = (color        and 0xFF) / 255f
            when ((Math.random() * 5).toInt()) {
                0, 1 -> { em.r = cr;                 em.g = cg;                 em.b = cb }              // 本體色
                2, 3 -> { em.r = cr * 0.4f + 0.6f;   em.g = cg * 0.4f + 0.6f;   em.b = cb * 0.4f + 0.6f } // 白熱
                else -> { em.r = cr * 0.7f;          em.g = cg * 0.7f;          em.b = cb * 0.7f }        // 暗燼
            }
            return
        }
    }

    private fun updateEmbers(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (em in embers) {
            if (!em.active) continue
            em.x += em.vx * dt / (vw * 0.5f)
            em.y += em.vy * dt / (vh * 0.5f)
            em.vx *= 1f - 0.03f * dt
            em.alpha -= em.decay * dt
            if (em.alpha <= 0f) em.active = false
        }
    }

    private fun drawEmbers(ctx: GLRenderContext) {
        emberFloats.clear()
        var count = 0
        for (em in embers) {
            if (!em.active) continue
            // 火星閃爍
            val a = (em.alpha * (0.6f + Math.random().toFloat() * 0.4f)).coerceIn(0f, 1f)
            emberFloats.put(em.x).put(em.y).put(em.r).put(em.g).put(em.b).put(a).put(em.sizePx)
            count++
        }
        if (count == 0) return

        GLES20.glUseProgram(hazeProgram)
        GLES20.glEnableVertexAttribArray(hPosLoc)
        GLES20.glEnableVertexAttribArray(hColLoc)
        GLES20.glEnableVertexAttribArray(hSizeLoc)
        emberBuf.position(0)
        GLES20.glVertexAttribPointer(hPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, emberBuf)
        emberBuf.position(8)
        GLES20.glVertexAttribPointer(hColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, emberBuf)
        emberBuf.position(24)
        GLES20.glVertexAttribPointer(hSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, emberBuf)
        emberBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(hPosLoc)
        GLES20.glDisableVertexAttribArray(hColLoc)
        GLES20.glDisableVertexAttribArray(hSizeLoc)
    }

    // ── 熱空氣折射殘影 ────────────────────────────────────────────────────

    private fun spawnHaze(x: Float, y: Float, minDim: Float) {
        for (hz in hazes) {
            if (hz.active) continue
            hz.active = true
            hz.x = x; hz.y = y
            hz.sizePx = minDim * (0.035f + Math.random().toFloat() * 0.025f)
            hz.alpha  = 0.10f                              // 極高透明度
            return
        }
    }

    private fun updateHaze(dt: Float) {
        for (hz in hazes) {
            if (!hz.active) continue
            hz.sizePx *= 1f + 0.010f * dt                  // 緩慢膨脹上升感
            hz.alpha  -= 0.0022f * dt                      // 緩慢淡出（~1.5 秒）
            if (hz.alpha <= 0f) hz.active = false
        }
    }

    private fun drawHaze(ctx: GLRenderContext) {
        hazeFloats.clear()
        var count = 0
        for (hz in hazes) {
            if (!hz.active) continue
            hazeFloats.put(hz.x).put(hz.y)
                .put(1f).put(0.96f).put(0.90f)             // 暖白 — 熱浪微光
                .put(hz.alpha.coerceIn(0f, 1f)).put(hz.sizePx)
            count++
        }
        if (count == 0) return

        GLES20.glUseProgram(hazeProgram)
        GLES20.glEnableVertexAttribArray(hPosLoc)
        GLES20.glEnableVertexAttribArray(hColLoc)
        GLES20.glEnableVertexAttribArray(hSizeLoc)
        hazeBuf.position(0)
        GLES20.glVertexAttribPointer(hPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, hazeBuf)
        hazeBuf.position(8)
        GLES20.glVertexAttribPointer(hColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, hazeBuf)
        hazeBuf.position(24)
        GLES20.glVertexAttribPointer(hSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, hazeBuf)
        hazeBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(hPosLoc)
        GLES20.glDisableVertexAttribArray(hColLoc)
        GLES20.glDisableVertexAttribArray(hSizeLoc)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT      = 28   // 7 floats × 4
        private const val BYTES_PER_VERT_FIRE = 32   // 8 floats × 4
        private const val MAX_FIREBALLS       = 16
        private const val MAX_HAZE            = 20
        private const val MAX_TRAIL_POINTS    = 256
        private const val MAX_RESAMPLE        = 64
        private const val MAX_EMBERS          = 24
        private const val TONGUE_HALF_WIDTH   = 0.034f  // 加寬 — 火舌更搶眼
        private const val SERPENT_AMP         = 0.024f  // 蛇形擺動振幅（NDC）
        private const val TWIST_FREQ          = 2.4f    // 沿軌跡的扭動波數
        private const val WRIGGLE_SPEED       = 8.5f    // 翻滾速度（rad/s）
        private const val PI_F                = Math.PI.toFloat()
        private const val TWO_PI              = (Math.PI * 2).toFloat()
        private const val TIME_WRAP           = 120f

        private val FIRE_VERT = """
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

        // 火焰：雜訊沿軌跡向後捲動（火舌舔動），邊緣被撕成火苗狀；
        // 調色固定：白金核心 → 烈橙 → 深紅蓮，外緣燒蝕成透明
        private val FIRE_FRAG = """
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
                float tail = 1.0 - life;                 // 越靠尾部越大

                // 火紋向後捲動 → 火舌舔動感
                vec2  uv   = vec2(vTrailDist * 16.0 - uTime * 8.0, vCenterDist * 1.6);
                float n1   = noise(uv);
                float n2   = noise(uv * 2.6 + 7.3);
                float turb = n1 * 0.6 + n2 * 0.4;

                // 邊緣撕成火苗 — 撕裂幅度往尾部加劇（尾巴狂舞）
                float cut  = 0.62 + (turb - 0.5) * (0.55 + 0.55 * tail);
                float body = 1.0 - smoothstep(cut - 0.25, cut + 0.08, d);

                // 尾部「燒蝕」：雜訊把尾巴咬成一束束分離的火舌，
                // 被咬掉的邊緣留下暗紅餘燼，不是平淡變透明
                float burn = smoothstep(life * 1.15, life * 1.15 + 0.22, n1);
                body *= 1.0 - burn * 0.85;
                if (body <= 0.004) discard;

                // 熱度：中心最熱，由湍流與存活度調制
                float heat = (1.0 - d * d) * (0.60 + 0.55 * turb) * (0.30 + 0.70 * life);

                // 熱度梯度（基底 = 陀螺色）：深色邊緣 → 飽和本體 → 白熱核心
                vec3 base = vColor.rgb;
                vec3 col  = mix(base * 0.40, base, smoothstep(0.18, 0.58, heat));
                col       = mix(col, mix(base, vec3(1.0), 0.72),
                                smoothstep(0.66, 0.93, heat));
                // 燒蝕邊界泛飽和餘燼光
                col       = mix(col, base, burn * 0.6);

                // 基礎不透明度提高，火舌更搶眼
                float a = body * (0.40 + 0.60 * life) * (0.70 + 0.30 * turb);
                gl_FragColor = vec4(col, min(a, 1.0));
            }""".trimIndent()

        private val POLY_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aCenterDist;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
                vCenterDist = aCenterDist;
            }""".trimIndent()

        // 火球：白熱核心 → 本體色 → 邊緣燒蝕（核心 = 本體色提亮 70%）
        private val POLY_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d = abs(vCenterDist);
                vec3 hot = mix(vColor.rgb, vec3(1.0), 0.70);
                vec3 col = mix(hot, vColor.rgb, smoothstep(0.12, 0.72, d));
                float a  = vColor.a * (1.0 - smoothstep(0.55, 1.0, d));
                gl_FragColor = vec4(col, a);
            }""".trimIndent()

        private val HAZE_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }""".trimIndent()

        // 熱浪：極淡高斯光斑 — 像空氣被烤出的折射殘影
        private val HAZE_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.5);
                gl_FragColor = vec4(vColor.rgb, a);
            }""".trimIndent()
    }
}
