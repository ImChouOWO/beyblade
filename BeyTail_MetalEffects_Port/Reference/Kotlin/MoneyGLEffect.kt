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
 * 金錢衝擊 effect — 黃金噴錢衝擊：
 *   - 黃金尾流：金色能量拖尾
 *   - 噴錢：移動時持續往後/兩側噴出翻滾的金幣，撞擊時呈放射狀爆噴一大把
 *   - 金光閃爍：細小金色火光
 *   - 衝擊金環：撞擊瞬間擴張的金色衝擊波環
 *
 * 主色固定黃金色（依需求；不跟陀螺色）。每幀常數皆乘 ctx.dtScale 支援 60fps。
 */
class IronShieldGLEffect : GLEffect() {

    // ── 金色尾流 / 火光 / 金環 program（pos2 col4 dist1） ───────────────────
    private var goldProgram = 0
    private var gPosLoc = -1; private var gColLoc = -1; private var gDistLoc = -1

    // ── 金幣 quad program（pos2 uv2 col4） ─────────────────────────────────
    private var coinProgram = 0
    private var cPosLoc = -1; private var cUvLoc = -1; private var cColLoc = -1

    // ── 金幣（翻滾 + 重力掉落） ────────────────────────────────────────────
    private class Coin {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f          // px/frame
        var angle = 0f; var angVel = 0f   // 平面旋轉
        var flip = 0f; var flipVel = 0f   // 立體翻面（squash x）
        var sizePx = 20f
        var alpha = 0f; var decay = 0.03f
        var r = 1f; var g = 0.82f; var b = 0.12f
    }
    private val coins = Array(MAX_COINS) { Coin() }
    private val coinBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_COINS * 6 * BYTES_PER_COIN).order(ByteOrder.nativeOrder())
    private val coinFloats: FloatBuffer = coinBuf.asFloatBuffer()

    // ── 金光火光（streak） ─────────────────────────────────────────────────
    private class Spark {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f
        var alpha = 0f; var decay = 0.1f
        var halfWPx = 2f
        var r = 1f; var g = 1f; var b = 1f
    }
    private val sparks = Array(MAX_SPARKS) { Spark() }
    private val sparkBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_SPARKS * 6 * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val sparkFloats: FloatBuffer = sparkBuf.asFloatBuffer()

    // ── 衝擊金環 ────────────────────────────────────────────────────────────
    private class Ring {
        var active = false
        var x = 0f; var y = 0f
        var radiusPx = 0f; var maxRadiusPx = 0f
        var alpha = 0f
    }
    private val rings = Array(5) { Ring() }

    private val lastPos = HashMap<Int, Pair<Float, Float>>(8)
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)

    private var vwHalf = 1f
    private var vhHalf = 1f

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        goldProgram = GLHelper.buildProgram(GOLD_VERT, GOLD_FRAG)
        gPosLoc  = GLES20.glGetAttribLocation(goldProgram, "aPosition")
        gColLoc  = GLES20.glGetAttribLocation(goldProgram, "aColor")
        gDistLoc = GLES20.glGetAttribLocation(goldProgram, "aCenterDist")

        coinProgram = GLHelper.buildProgram(COIN_VERT, COIN_FRAG)
        cPosLoc = GLES20.glGetAttribLocation(coinProgram, "aPosition")
        cUvLoc  = GLES20.glGetAttribLocation(coinProgram, "aUV")
        cColLoc = GLES20.glGetAttribLocation(coinProgram, "aColor")
    }

    // ── draw ──────────────────────────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        vwHalf = (ctx.viewWidth * 0.5f).coerceAtLeast(1f)
        vhHalf = (ctx.viewHeight * 0.5f).coerceAtLeast(1f)

        // 金色尾流 + 衝擊金環 + 金光火光（共用 goldProgram）
        GLES20.glUseProgram(goldProgram)
        GLES20.glEnableVertexAttribArray(gPosLoc)
        GLES20.glEnableVertexAttribArray(gColLoc)
        GLES20.glEnableVertexAttribArray(gDistLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 2) drawRibbon(pts, ctx)
        }
        spawnFromTrack(trackData, ctx)
        updateRings(ctx.dtScale); drawRings(ctx)
        updateSparks(ctx); drawSparks()
        GLES20.glDisableVertexAttribArray(gPosLoc)
        GLES20.glDisableVertexAttribArray(gColLoc)
        GLES20.glDisableVertexAttribArray(gDistLoc)

        // 金幣（最上層）
        updateCoins(ctx)
        drawCoins()
    }

    // ── 黃金尾流 ────────────────────────────────────────────────────────────

    private fun drawRibbon(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = pts.size.coerceAtMost(MAX_TRAIL_POINTS)
        if (n < 2 || n * 2 * BYTES_PER_VERT > ctx.ribbonBuf.capacity()) return

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
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
            val hw    = TRAIL_HALF_WIDTH * (0.3f + 0.7f * alpha)
            ctx.ribbonFloats.put(x - nx*hw).put(y - ny*hw).put(GOLD_R).put(GOLD_G).put(GOLD_B).put(alpha).put(-1f)
            ctx.ribbonFloats.put(x + nx*hw).put(y + ny*hw).put(GOLD_R).put(GOLD_G).put(GOLD_B).put(alpha).put(+1f)
        }
        bindGoldAndDraw(n * 2, ctx)
    }

    // ── 噴錢 spawn ──────────────────────────────────────────────────────────

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

            val last = lastPos[trackId]
            val dist = if (last != null) {
                val ldx = x - last.first; val ldy = y - last.second
                sqrt(ldx * ldx + ldy * ldy)
            } else Float.MAX_VALUE

            if (dist > 0.006f) {
                lastPos[trackId] = x to y
                val moveNorm = moveLen / ctx.dtScale

                // 移動中持續往後噴金幣（窄錐、量少、速度收斂 → 範圍小不亂）
                if (moveNorm > 0.008f) {
                    val cnt = 1 + (moveNorm * 70f).toInt().coerceAtMost(2)
                    val speed = minDim * (0.006f + moveNorm * 0.35f)
                    for (k in 0 until cnt) {
                        spawnCoin(x, y, moveAngle + PI_F + (Math.random().toFloat() - 0.5f) * 0.6f,
                            speed * (0.7f + Math.random().toFloat() * 0.4f), minDim)
                    }
                    if (Math.random() > 0.4) spawnSpark(x, y, moveAngle + PI_F, 0.4f, 1)
                }
                // 撞擊：往後窄錐爆噴一小把 + 衝擊金環 + 金光（不再 360° 亂噴）
                if (moveNorm > 0.018f) {
                    val back = moveAngle + PI_F
                    val burst = 3 + (Math.random() * 3).toInt()
                    for (k in 0 until burst) {
                        spawnCoin(x, y, back + (Math.random().toFloat() - 0.5f) * 1.4f,
                            minDim * (0.008f + Math.random().toFloat() * 0.012f), minDim)
                    }
                    spawnRing(x, y, moveNorm, minDim)
                    spawnSpark(x, y, back, 0.7f, 3)
                }
            }
        }
    }

    private fun spawnCoin(x: Float, y: Float, angle: Float, speedPx: Float, minDim: Float) {
        for (cn in coins) {
            if (cn.active) continue
            cn.active = true
            cn.x = x; cn.y = y
            cn.vx = cos(angle) * speedPx
            cn.vy = sin(angle) * speedPx + minDim * 0.006f      // 向上彈一下再掉
            cn.angle = Math.random().toFloat() * TWO_PI
            cn.angVel = (Math.random().toFloat() - 0.5f) * 0.5f
            cn.flip = Math.random().toFloat() * TWO_PI
            cn.flipVel = 0.25f + Math.random().toFloat() * 0.4f  // 翻滾
            cn.sizePx = minDim * (0.020f + Math.random().toFloat() * 0.016f)
            cn.alpha = 1f
            cn.decay = 0.045f + Math.random().toFloat() * 0.035f   // 短命（~0.4–0.8s）→ 不殘留累積
            // 金色為主，少數偏亮（白金）/偏深（古銅）增加層次
            when ((Math.random() * 4).toInt()) {
                0    -> { cn.r = 1f;    cn.g = 0.90f; cn.b = 0.35f }   // 亮金
                3    -> { cn.r = 0.85f; cn.g = 0.60f; cn.b = 0.10f }   // 深銅
                else -> { cn.r = GOLD_R; cn.g = GOLD_G; cn.b = GOLD_B }
            }
            return
        }
    }

    private fun updateCoins(ctx: GLRenderContext) {
        val dt = ctx.dtScale
        for (cn in coins) {
            if (!cn.active) continue
            cn.x += cn.vx * dt / vwHalf
            cn.y += cn.vy * dt / vhHalf
            cn.vy -= GRAVITY * dt                 // 重力掉落
            cn.vx *= 1f - 0.02f * dt
            cn.angle += cn.angVel * dt
            cn.flip  += cn.flipVel * dt
            cn.alpha -= cn.decay * dt
            if (cn.alpha <= 0f) cn.active = false
        }
    }

    private fun drawCoins() {
        coinFloats.clear()
        var quads = 0
        for (cn in coins) {
            if (!cn.active) continue
            val flipS = 0.18f + 0.82f * kotlin.math.abs(cos(cn.flip))   // 翻面 squash（不全為 0）
            val hx = cn.sizePx * 0.5f * flipS
            val hy = cn.sizePx * 0.5f
            val ca = cos(cn.angle); val sa = sin(cn.angle)
            val a = cn.alpha.coerceIn(0f, 1f)

            fun corner(ux: Float, uy: Float): Pair<Float, Float> {
                val lx = ux * hx; val ly = uy * hy
                val rx = lx * ca - ly * sa; val ry = lx * sa + ly * ca
                return (cn.x + rx / vwHalf) to (cn.y + ry / vhHalf)
            }
            val (ax, ay) = corner(-1f, -1f)
            val (bx, by) = corner( 1f, -1f)
            val (dx2, dy2) = corner( 1f,  1f)
            val (ex, ey) = corner(-1f,  1f)
            // tri1 A,B,C ; tri2 A,C,D
            coinFloats.put(ax).put(ay).put(-1f).put(-1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            coinFloats.put(bx).put(by).put( 1f).put(-1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            coinFloats.put(dx2).put(dy2).put( 1f).put( 1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            coinFloats.put(ax).put(ay).put(-1f).put(-1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            coinFloats.put(dx2).put(dy2).put( 1f).put( 1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            coinFloats.put(ex).put(ey).put(-1f).put( 1f).put(cn.r).put(cn.g).put(cn.b).put(a)
            quads++
        }
        if (quads == 0) return

        GLES20.glUseProgram(coinProgram)
        GLES20.glEnableVertexAttribArray(cPosLoc)
        GLES20.glEnableVertexAttribArray(cUvLoc)
        GLES20.glEnableVertexAttribArray(cColLoc)
        coinBuf.position(0)
        GLES20.glVertexAttribPointer(cPosLoc, 2, GLES20.GL_FLOAT, false, BYTES_PER_COIN, coinBuf)
        coinBuf.position(8)
        GLES20.glVertexAttribPointer(cUvLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_COIN, coinBuf)
        coinBuf.position(16)
        GLES20.glVertexAttribPointer(cColLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_COIN, coinBuf)
        coinBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, quads * 6)
        GLES20.glDisableVertexAttribArray(cPosLoc)
        GLES20.glDisableVertexAttribArray(cUvLoc)
        GLES20.glDisableVertexAttribArray(cColLoc)
    }

    // ── 金光火光 ────────────────────────────────────────────────────────────

    private fun spawnSpark(x: Float, y: Float, angle: Float, coneHalf: Float, count: Int) {
        var spawned = 0
        for (s in sparks) {
            if (s.active) continue
            val pAngle  = angle + (Math.random().toFloat() - 0.5f) * 2f * coneHalf
            val speedPx = 8f + Math.random().toFloat() * 20f
            s.active = true
            s.x = x; s.y = y
            s.vx = cos(pAngle) * speedPx
            s.vy = sin(pAngle) * speedPx
            s.alpha = 1f
            s.decay = 0.07f + Math.random().toFloat() * 0.06f
            s.halfWPx = 1.4f + Math.random().toFloat() * 1.8f
            if (Math.random() > 0.4) { s.r = 1f; s.g = 0.95f; s.b = 0.6f } else { s.r = 1f; s.g = 1f; s.b = 1f }
            if (++spawned >= count) return
        }
    }

    private fun updateSparks(ctx: GLRenderContext) {
        val dt = ctx.dtScale
        val fr = 1f - 0.08f * dt
        for (s in sparks) {
            if (!s.active) continue
            s.x += s.vx * dt / vwHalf
            s.y += s.vy * dt / vhHalf
            s.vx *= fr; s.vy *= fr
            s.alpha -= s.decay * dt
            if (s.alpha <= 0f) s.active = false
        }
    }

    private fun drawSparks() {
        sparkFloats.clear()
        var vertCount = 0
        for (s in sparks) {
            if (!s.active) continue
            val speed = sqrt(s.vx * s.vx + s.vy * s.vy).coerceAtLeast(1e-3f)
            val dirX = s.vx / speed; val dirY = s.vy / speed
            val lenPx = speed * 2.6f + 3f
            val ex  = s.x + dirX * lenPx     / vwHalf
            val ey  = s.y + dirY * lenPx     / vhHalf
            val nxN = -dirY  * s.halfWPx     / vwHalf
            val nyN =  dirX  * s.halfWPx     / vhHalf
            val a = s.alpha.coerceIn(0f, 1f)
            fun put(px: Float, py: Float, d: Float, va: Float) {
                sparkFloats.put(px).put(py).put(s.r).put(s.g).put(s.b).put(va).put(d)
            }
            put(s.x - nxN, s.y - nyN, -1f, a)
            put(s.x + nxN, s.y + nyN, +1f, a)
            put(ex  - nxN, ey  - nyN, -1f, a * 0.30f)
            put(s.x + nxN, s.y + nyN, +1f, a)
            put(ex  + nxN, ey  + nyN, +1f, a * 0.30f)
            put(ex  - nxN, ey  - nyN, -1f, a * 0.30f)
            vertCount += 6
        }
        if (vertCount == 0) return
        sparkBuf.position(0)
        GLES20.glVertexAttribPointer(gPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(8)
        GLES20.glVertexAttribPointer(gColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(24)
        GLES20.glVertexAttribPointer(gDistLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
    }

    // ── 衝擊金環 ────────────────────────────────────────────────────────────

    private fun spawnRing(x: Float, y: Float, moveLen: Float, minDim: Float) {
        for (ring in rings) {
            if (ring.active) continue
            ring.active = true
            ring.x = x; ring.y = y
            ring.radiusPx    = minDim * 0.010f
            ring.maxRadiusPx = (minDim * (0.035f + moveLen * 0.4f)).coerceAtMost(minDim * 0.065f)
            ring.alpha = 0.7f
            return
        }
    }

    private fun updateRings(dt: Float) {
        for (ring in rings) {
            if (!ring.active) continue
            ring.radiusPx += (ring.maxRadiusPx - ring.radiusPx) * 0.22f * dt
            ring.alpha    -= 0.06f * dt
            if (ring.alpha <= 0f || ring.maxRadiusPx - ring.radiusPx < 1f) ring.active = false
        }
    }

    private fun drawRings(ctx: GLRenderContext) {
        val minDim = minOf(ctx.viewWidth, ctx.viewHeight).toFloat()
        if (minDim <= 0f) return
        for (ring in rings) {
            if (!ring.active) continue
            drawRadialBand(ring.x, ring.y, ring.radiusPx, minDim * 0.0034f,
                RING_SEGMENTS, ring.alpha.coerceIn(0f, 1f), ctx)
        }
    }

    private fun drawRadialBand(
        cx: Float, cy: Float, radiusPx: Float, halfWidthPx: Float,
        segments: Int, a: Float, ctx: GLRenderContext
    ) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val iPx = (radiusPx - halfWidthPx).coerceAtLeast(0f)
        val oPx = radiusPx + halfWidthPx
        val iRx = iPx / (vw / 2f); val iRy = iPx / (vh / 2f)
        val oRx = oPx / (vw / 2f); val oRy = oPx / (vh / 2f)
        ctx.ribbonFloats.clear()
        for (i in 0..segments) {
            val ang = TWO_PI * i / segments
            val c = cos(ang); val s = sin(ang)
            ctx.ribbonFloats.put(cx + iRx*c).put(cy + iRy*s).put(GOLD_R).put(GOLD_G).put(GOLD_B).put(a).put(-1f)
            ctx.ribbonFloats.put(cx + oRx*c).put(cy + oRy*s).put(GOLD_R).put(GOLD_G).put(GOLD_B).put(a).put(+1f)
        }
        bindGoldAndDraw((segments + 1) * 2, ctx)
    }

    private fun bindGoldAndDraw(vertCount: Int, ctx: GLRenderContext, mode: Int = GLES20.GL_TRIANGLE_STRIP) {
        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(gPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(gColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(gDistLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(mode, 0, vertCount)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT   = 28   // 7 floats × 4 (pos2 col4 dist1)
        private const val BYTES_PER_COIN   = 32   // 8 floats × 4 (pos2 uv2 col4)
        private const val MAX_COINS        = 36
        private const val MAX_SPARKS       = 48
        private const val MAX_TRAIL_POINTS = 256
        private const val RING_SEGMENTS    = 24
        private const val TRAIL_HALF_WIDTH = 0.022f
        private const val GRAVITY          = 0.6f
        private const val TWO_PI           = (Math.PI * 2).toFloat()
        private const val PI_F             = Math.PI.toFloat()

        // 主色：黃金
        private const val GOLD_R = 1f
        private const val GOLD_G = 0.82f
        private const val GOLD_B = 0.12f

        private val GOLD_VERT = """
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

        // 金色能量：飽和金核 + 白金高光，用於尾流 / 火光 / 衝擊環
        private val GOLD_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d    = abs(vCenterDist);
                float body = (1.0 - smoothstep(0.55, 1.0, d)) * 0.55;
                float core = exp(-d * d * 18.0);
                float w    = body + core;
                vec3  col  = (vColor.rgb * body
                            + mix(vColor.rgb, vec3(1.0), 0.75) * core) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }""".trimIndent()

        private val COIN_VERT = """
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

        // 金幣：圓盤金面 + 深色邊圈 + 刻印的 $ 字樣 + 左上高光
        private val COIN_FRAG = """
            precision mediump float;
            varying vec2 vUV;
            varying vec4 vColor;
            void main() {
                float r = length(vUV);
                if (r > 1.0) discard;
                vec3 gold = vColor.rgb;
                vec3 deep = gold * 0.55;
                // 邊圈漸深
                vec3 col = mix(gold, deep, smoothstep(0.70, 0.95, r));
                // 靠邊一圈刻紋（錢幣感，避開中央 $）
                float ring = 1.0 - smoothstep(0.0, 0.05, abs(r - 0.80));
                col = mix(col, deep, ring * 0.5);

                // ── $ 字樣：上下兩段弧組成 S + 中央貫穿直槓，刻印成深色 ──
                const float PI = 3.14159265;
                vec2 g = vUV / 0.42;
                // 上弧（缺口朝右下）
                vec2 pt = g - vec2(0.0, 0.5);
                float dt = abs(length(pt) - 0.5);
                float gt = abs(mod(atan(pt.y, pt.x) - (-0.6) + PI, 2.0 * PI) - PI);
                float topArc = (1.0 - smoothstep(0.11, 0.18, dt)) * step(0.95, gt);
                // 下弧（缺口朝左上）
                vec2 pb = g - vec2(0.0, -0.5);
                float db = abs(length(pb) - 0.5);
                float gb = abs(mod(atan(pb.y, pb.x) - (2.4) + PI, 2.0 * PI) - PI);
                float botArc = (1.0 - smoothstep(0.11, 0.18, db)) * step(0.95, gb);
                // 中央直槓（貫穿 $）
                float bar = (1.0 - smoothstep(0.08, 0.13, abs(g.x)))
                          * (1.0 - smoothstep(1.08, 1.24, abs(g.y)));
                float dollar = clamp(topArc + botArc + bar, 0.0, 1.0);
                col = mix(col, deep * 0.5, dollar);

                // 左上高光（金屬反光，$ 處不打光以保清晰）
                float hl = smoothstep(0.62, 0.0, length(vUV - vec2(-0.32, 0.32)));
                col = mix(col, vec3(1.0), hl * 0.5 * (1.0 - dollar));
                float a = vColor.a * (1.0 - smoothstep(0.94, 1.0, r));
                gl_FragColor = vec4(col, a);
            }""".trimIndent()
    }
}
