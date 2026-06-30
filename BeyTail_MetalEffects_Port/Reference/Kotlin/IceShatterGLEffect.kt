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
 * 狂暴冰裂 effect — raging ice shatter (ported from the canvas prototype):
 *   - Fracture trail: solid beyblade-colored ice seam with white-hot crack core,
 *     edges jitter randomly every frame (凍裂縫的顫動)
 *   - Big irregular polygon ice shards (3–5 random vertices, chunks vs debris)
 *     erupting out of the trail body itself — perpendicular blasts with strong
 *     gravity, fast spin, ~7-frame life
 *
 * Single shader program for everything.
 */
class IceShatterGLEffect : GLEffect() {

    private var program  = 0
    private var posLoc   = -1
    private var colorLoc = -1
    private var distLoc  = -1

    // 冰刃拖尾 program（銳利刃口 + 滑過鏡面流光）
    private var bladeProgram = 0
    private var bPosLoc   = -1
    private var bColLoc   = -1
    private var bDistLoc  = -1
    private var bTrailLoc = -1
    private var bTimeLoc  = -1

    // 冰霜 / 白霧 point program（柔光點精靈）
    private var fogProgram = 0
    private var fPosLoc  = -1
    private var fColLoc  = -1
    private var fSizeLoc = -1

    // ── Irregular polygon ice shards (gravity + spin) ─────────────────────
    private class Shard {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f        // px/frame
        var angle = 0f; var spin = 0f
        var vertexCount = 3
        val ox = FloatArray(5)          // polygon vertex offsets (px, unrotated)
        val oy = FloatArray(5)
        var alpha = 0f; var decay = 0.14f
        var r = 1f; var g = 1f; var b = 1f
    }
    private val shards = Array(MAX_SHARDS) { Shard() }
    private val shardBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_SHARDS * 9 * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val shardFloats: FloatBuffer = shardBuf.asFloatBuffer()

    // ── 冰霜殘留（沿軌跡結霜的細小冰晶，緩慢淡掉 + 閃爍） ──────────────────
    private class Frost {
        var active = false
        var x = 0f; var y = 0f
        var sizePx = 4f
        var alpha = 0f; var decay = 0.02f
        var r = 1f; var g = 1f; var b = 1f
    }
    private val frosts = Array(MAX_FROST) { Frost() }
    private val frostBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_FROST * BYTES_PER_PT).order(ByteOrder.nativeOrder())
    private val frostFloats: FloatBuffer = frostBuf.asFloatBuffer()

    // ── 中心白霧（陀螺核心冒出的寒氣，膨脹後消散） ─────────────────────────
    private class Fog {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f        // px/frame
        var sizePx = 30f
        var alpha = 0f
    }
    private val fogs = Array(MAX_FOG) { Fog() }
    private val fogBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_FOG * BYTES_PER_PT).order(ByteOrder.nativeOrder())
    private val fogFloats: FloatBuffer = fogBuf.asFloatBuffer()

    private val lastPos = HashMap<Int, Pair<Float, Float>>(8)

    private var time = 0f

    // Reusable scratch arrays for ribbon geometry
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    private val cum = FloatArray(MAX_TRAIL_POINTS)   // 沿軌跡累積長度（鏡面流光座標）
    // Reusable scratch for shard polygon vertices (no per-frame allocation)
    private val scratchV  = FloatArray(2)
    private val scratchV0 = FloatArray(2)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        program  = GLHelper.buildProgram(ICE_VERT, ICE_FRAG)
        posLoc   = GLES20.glGetAttribLocation(program, "aPosition")
        colorLoc = GLES20.glGetAttribLocation(program, "aColor")
        distLoc  = GLES20.glGetAttribLocation(program, "aCenterDist")

        bladeProgram = GLHelper.buildProgram(BLADE_VERT, BLADE_FRAG)
        bPosLoc   = GLES20.glGetAttribLocation(bladeProgram, "aPosition")
        bColLoc   = GLES20.glGetAttribLocation(bladeProgram, "aColor")
        bDistLoc  = GLES20.glGetAttribLocation(bladeProgram, "aCenterDist")
        bTrailLoc = GLES20.glGetAttribLocation(bladeProgram, "aTrailDist")
        bTimeLoc  = GLES20.glGetUniformLocation(bladeProgram, "uTime")

        fogProgram = GLHelper.buildProgram(FOG_VERT, FOG_FRAG)
        fPosLoc  = GLES20.glGetAttribLocation(fogProgram, "aPosition")
        fColLoc  = GLES20.glGetAttribLocation(fogProgram, "aColor")
        fSizeLoc = GLES20.glGetAttribLocation(fogProgram, "aSize")
    }

    // ── draw ──────────────────────────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        time += (1f / 30f) * ctx.dtScale
        if (time > TIME_WRAP) time -= TIME_WRAP

        // 冰刃拖尾（銳利刃口 + 滑過鏡面流光）
        GLES20.glUseProgram(bladeProgram)
        GLES20.glUniform1f(bTimeLoc, time)
        GLES20.glEnableVertexAttribArray(bPosLoc)
        GLES20.glEnableVertexAttribArray(bColLoc)
        GLES20.glEnableVertexAttribArray(bDistLoc)
        GLES20.glEnableVertexAttribArray(bTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 2) drawRibbon(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(bPosLoc)
        GLES20.glDisableVertexAttribArray(bColLoc)
        GLES20.glDisableVertexAttribArray(bDistLoc)
        GLES20.glDisableVertexAttribArray(bTrailLoc)

        // 碎片暴衝（沿用原 program）
        GLES20.glUseProgram(program)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glEnableVertexAttribArray(colorLoc)
        GLES20.glEnableVertexAttribArray(distLoc)
        spawnFromTrack(trackData, ctx)
        updateShards(ctx)
        drawShards(ctx)
        GLES20.glDisableVertexAttribArray(posLoc)
        GLES20.glDisableVertexAttribArray(colorLoc)
        GLES20.glDisableVertexAttribArray(distLoc)

        // 冰霜殘留（軌跡上結霜、緩慢淡掉）＋ 中心白霧消散
        spawnFrostAndFog(trackData, ctx)
        updateFrost(ctx); updateFog(ctx)
        drawPoints(frosts, frostBuf, frostFloats, twinkle = true)
        drawPoints(fogs, fogBuf, fogFloats, twinkle = false)
    }

    // ── 冰霜 + 白霧：spawn / update / draw ──────────────────────────────────

    private fun spawnFrostAndFog(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)
        for ((_, pts) in trackData) {
            if (pts.isEmpty()) continue
            val color = pts.last().first.color
            // ① 冰霜：沿軌跡灑出細小冰晶（持續結霜，慢慢淡掉）
            if (pts.size >= 3) {
                var spawns = FROST_PER_FRAME * ctx.dtScale
                while (spawns > 0f) {
                    if (spawns < 1f && Math.random() > spawns) break
                    val idx = (Math.random() * pts.size).toInt().coerceAtMost(pts.size - 1)
                    val tp = pts[idx].first
                    spawnFrost(
                        (tp.center.x * 2f - 1f) * ctx.quadScaleX,
                        (1f - tp.center.y * 2f) * ctx.quadScaleY,
                        minDim, color)
                    spawns -= 1f
                }
            }
            // ② 中心白霧：陀螺核心持續冒寒氣
            if (Math.random() < FOG_RATE * ctx.dtScale) {
                val tp = pts.last().first
                spawnFog(
                    (tp.center.x * 2f - 1f) * ctx.quadScaleX,
                    (1f - tp.center.y * 2f) * ctx.quadScaleY,
                    minDim)
            }
        }
    }

    private fun spawnFrost(x: Float, y: Float, minDim: Float, color: Int) {
        for (fr in frosts) {
            if (fr.active) continue
            fr.active = true
            fr.x = x + (Math.random().toFloat() - 0.5f) * 0.05f
            fr.y = y + (Math.random().toFloat() - 0.5f) * 0.05f
            fr.sizePx = minDim * (0.004f + Math.random().toFloat() * 0.006f)
            fr.alpha  = 0.7f + Math.random().toFloat() * 0.3f
            fr.decay  = 0.012f + Math.random().toFloat() * 0.012f      // 慢慢淡掉（結霜感）
            // 淡冰藍混陀螺色，少數純白晶亮
            if (Math.random() > 0.3) {
                fr.r = ICE_R * 0.6f + (color shr 16 and 0xFF) / 255f * 0.4f
                fr.g = ICE_G * 0.6f + (color shr  8 and 0xFF) / 255f * 0.4f
                fr.b = 1f
            } else {
                fr.r = 1f; fr.g = 1f; fr.b = 1f
            }
            return
        }
    }

    private fun spawnFog(x: Float, y: Float, minDim: Float) {
        for (fg in fogs) {
            if (fg.active) continue
            fg.active = true
            fg.x = x + (Math.random().toFloat() - 0.5f) * 0.03f
            fg.y = y + (Math.random().toFloat() - 0.5f) * 0.03f
            fg.vx = (Math.random().toFloat() - 0.5f) * 1.0f
            fg.vy = 0.6f + Math.random().toFloat() * 1.0f             // 寒氣緩緩上飄
            fg.sizePx = minDim * (0.05f + Math.random().toFloat() * 0.04f)
            fg.alpha  = 0.16f                                          // 極淡寒霧
            return
        }
    }

    private fun updateFrost(ctx: GLRenderContext) {
        val dt = ctx.dtScale
        for (fr in frosts) {
            if (!fr.active) continue
            fr.alpha -= fr.decay * dt
            if (fr.alpha <= 0f) fr.active = false
        }
    }

    private fun updateFog(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (fg in fogs) {
            if (!fg.active) continue
            fg.x += fg.vx * dt / (vw * 0.5f)
            fg.y += fg.vy * dt / (vh * 0.5f)
            fg.sizePx *= 1f + 0.016f * dt                              // 膨脹消散
            fg.alpha  -= 0.0045f * dt
            if (fg.alpha <= 0f) fg.active = false
        }
    }

    private fun drawPoints(
        frostPool: Array<Frost>, buf: ByteBuffer, floats: FloatBuffer, twinkle: Boolean
    ) {
        floats.clear()
        var count = 0
        for (fr in frostPool) {
            if (!fr.active) continue
            val a = if (twinkle) (fr.alpha * (0.55f + Math.random().toFloat() * 0.45f)) else fr.alpha
            floats.put(fr.x).put(fr.y).put(fr.r).put(fr.g).put(fr.b).put(a.coerceIn(0f, 1f)).put(fr.sizePx)
            count++
        }
        if (count == 0) return
        bindPointsAndDraw(buf, count)
    }

    @JvmName("drawFogPoints")
    private fun drawPoints(fogPool: Array<Fog>, buf: ByteBuffer, floats: FloatBuffer, twinkle: Boolean) {
        floats.clear()
        var count = 0
        for (fg in fogPool) {
            if (!fg.active) continue
            floats.put(fg.x).put(fg.y).put(1f).put(1f).put(1f).put(fg.alpha.coerceIn(0f, 1f)).put(fg.sizePx)
            count++
        }
        if (count == 0) return
        bindPointsAndDraw(buf, count)
    }

    private fun bindPointsAndDraw(buf: ByteBuffer, count: Int) {
        GLES20.glUseProgram(fogProgram)
        GLES20.glEnableVertexAttribArray(fPosLoc)
        GLES20.glEnableVertexAttribArray(fColLoc)
        GLES20.glEnableVertexAttribArray(fSizeLoc)
        buf.position(0)
        GLES20.glVertexAttribPointer(fPosLoc,  2, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(8)
        GLES20.glVertexAttribPointer(fColLoc,  4, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(24)
        GLES20.glVertexAttribPointer(fSizeLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_PT, buf)
        buf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(fPosLoc)
        GLES20.glDisableVertexAttribArray(fColLoc)
        GLES20.glDisableVertexAttribArray(fSizeLoc)
    }

    // ── Fracture trail ────────────────────────────────────────────────────
    // Beyblade-colored solid ice seam; edge widths jitter every frame so the
    // border crackles like a fracture line (prototype's randomJagged).

    private fun drawRibbon(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = pts.size.coerceAtMost(MAX_TRAIL_POINTS)
        if (n < 2 || n * 2 * BYTES_PER_VERT_BLADE > ctx.ribbonBuf.capacity()) return

        val c  = pts.last().first.color
        val cr = (c shr 16 and 0xFF) / 255f
        val cg = (c shr  8 and 0xFF) / 255f
        val cb = (c        and 0xFF) / 255f

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
            // 刀刃輪廓：頭寬尾尖（冰刀切痕），邊緣俐落；只留極微顫動避免太死板
            val hw  = TRAIL_HALF_WIDTH * (0.22f + 0.78f * alpha)
            val jag = (1f - alpha) * 0.18f
            val hwL = hw * (1f + (Math.random().toFloat() - 0.5f) * jag)
            val hwR = hw * (1f + (Math.random().toFloat() - 0.5f) * jag)
            val trail = cum[i]
            ctx.ribbonFloats.put(x - nx*hwL).put(y - ny*hwL).put(cr).put(cg).put(cb).put(alpha).put(-1f).put(trail)
            ctx.ribbonFloats.put(x + nx*hwR).put(y + ny*hwR).put(cr).put(cg).put(cb).put(alpha).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(bPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BLADE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(bColLoc,   4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BLADE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(bDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BLADE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(bTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_BLADE, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, n * 2)
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

            if (dist > 0.006f) {
                lastPos[trackId] = x to y
                // normalize speed to the 30fps baseline (points are denser at 60fps)
                val moveNorm = moveLen / ctx.dtScale

                // shards erupt out of the trail body
                // (prototype: more likely the faster it moves)
                if (moveNorm > 0.007f) {
                    val chance = if (moveNorm > 0.016f) 1.0f else 0.75f
                    if (Math.random().toFloat() < chance) {
                        spawnShardsFromTrail(pts, moveNorm, minDim, tp.color, ctx)
                    }
                }
            }
        }
    }

    /** Blast 4 irregular shards out of a random point on the trail body. */
    private fun spawnShardsFromTrail(
        pts: List<Pair<TrailPoint, Float>>, moveLen: Float, minDim: Float,
        color: Int, ctx: GLRenderContext
    ) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        val n = pts.size

        // random eruption point anywhere along the trail
        val idx = (Math.random() * (n - 1)).toInt().coerceIn(0, n - 2)
        val tp0 = pts[idx].first; val tp2 = pts[idx + 1].first
        val ex = (tp0.center.x * 2f - 1f) * ctx.quadScaleX
        val ey = (1f - tp0.center.y * 2f) * ctx.quadScaleY
        val tx = (tp2.center.x * 2f - 1f) * ctx.quadScaleX
        val ty = (1f - tp2.center.y * 2f) * ctx.quadScaleY
        // screen-space direction of the trail at that point
        val segAngle = atan2((ty - ey) * vh, (tx - ex) * vw)

        val cr = (color shr 16 and 0xFF) / 255f
        val cg = (color shr  8 and 0xFF) / 255f

        val speedPx = moveLen * minDim * 0.5f
        var spawned = 0
        for (s in shards) {
            if (s.active) continue
            // burst perpendicular out of the cut, random side, with jitter
            val side  = if (Math.random() > 0.5) 1f else -1f
            val pAngle = segAngle + side * HALF_PI + (Math.random().toFloat() - 0.5f) * 0.8f
            val expSpeed = Math.random().toFloat() * 6f + speedPx * 0.4f
            s.active = true
            s.x = ex; s.y = ey
            s.vx = cos(pAngle) * expSpeed
            s.vy = sin(pAngle) * expSpeed + 1.2f           // slight upward kick
            s.angle = Math.random().toFloat() * TWO_PI
            s.spin  = (Math.random().toFloat() - 0.5f) * 1.2f
            s.alpha = 1f
            s.decay = 0.12f + Math.random().toFloat() * 0.05f

            // bimodal size: big chunks vs fine debris (biased toward chunks)
            val isBig = Math.random() > 0.4
            val basePx = if (isBig) minDim * (0.013f + Math.random().toFloat() * 0.008f)
                         else       minDim * (0.005f + Math.random().toFloat() * 0.003f)
            s.vertexCount = 3 + (Math.random() * 3).toInt().coerceAtMost(2)   // 3–5
            for (j in 0 until s.vertexCount) {
                val ang = TWO_PI * j / s.vertexCount
                val rad = basePx * (Math.random().toFloat() * 0.9f + 0.3f)
                s.ox[j] = cos(ang) * rad
                s.oy[j] = sin(ang) * rad
            }
            if (Math.random() > 0.3) {
                // pale ice tinted by the beyblade color
                s.r = (ICE_R * 0.7f + cr * 0.3f); s.g = (ICE_G * 0.7f + cg * 0.3f); s.b = 1f
            } else {
                s.r = 1f; s.g = 1f; s.b = 1f
            }
            if (++spawned >= 6) return
        }
    }

    // ── Polygon ice shards ────────────────────────────────────────────────

    private fun updateShards(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (s in shards) {
            if (!s.active) continue
            s.x += s.vx * dt / (vw * 0.5f)
            s.y += s.vy * dt / (vh * 0.5f)
            s.vy -= 0.65f * dt              // strong gravity (NDC y is up)
            s.angle += s.spin * dt
            s.alpha -= s.decay * dt
            if (s.alpha <= 0f) s.active = false
        }
    }

    private fun drawShards(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return

        shardFloats.clear()
        var vertCount = 0
        val v = scratchV; val v0 = scratchV0
        for (s in shards) {
            if (!s.active) continue
            val cA = cos(s.angle); val sA = sin(s.angle)
            val a = s.alpha.coerceIn(0f, 1f)

            // rotated polygon vertices, px offsets converted per-axis to NDC
            fun vert(j: Int, out: FloatArray) {
                val rx = s.ox[j] * cA - s.oy[j] * sA
                val ry = s.ox[j] * sA + s.oy[j] * cA
                out[0] = s.x + rx / (vw / 2f)
                out[1] = s.y + ry / (vh / 2f)
            }
            vert(0, v0)
            // fan triangulation from vertex 0
            for (j in 1 until s.vertexCount - 1) {
                shardFloats.put(v0[0]).put(v0[1]).put(s.r).put(s.g).put(s.b).put(a).put(SHARD_DIST)
                vert(j, v)
                shardFloats.put(v[0]).put(v[1]).put(s.r).put(s.g).put(s.b).put(a).put(SHARD_DIST)
                vert(j + 1, v)
                shardFloats.put(v[0]).put(v[1]).put(s.r).put(s.g).put(s.b).put(a).put(SHARD_DIST)
                vertCount += 3
            }
        }
        if (vertCount == 0) return

        shardBuf.position(0)
        GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, shardBuf)
        shardBuf.position(8)
        GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, shardBuf)
        shardBuf.position(24)
        GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, shardBuf)
        shardBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT       = 28   // 7 floats × 4
        private const val BYTES_PER_VERT_BLADE = 32   // 8 floats × 4 (pos2 col4 dist1 trail1)
        private const val BYTES_PER_PT         = 28   // 7 floats × 4 (pos2 col4 size1)
        private const val TIME_WRAP            = 120f
        private const val MAX_SHARDS       = 64
        private const val MAX_FROST        = 56
        private const val MAX_FOG          = 16
        private const val FROST_PER_FRAME  = 1.6f
        private const val FOG_RATE         = 0.7f
        private const val MAX_TRAIL_POINTS = 256
        private const val TRAIL_HALF_WIDTH = 0.028f
        // flat bright zone of the shader — solid icy chunk without hot center
        private const val SHARD_DIST       = 0.25f
        private const val TWO_PI           = (Math.PI * 2).toFloat()
        private const val HALF_PI          = (Math.PI / 2).toFloat()

        // pale glacier blue (shard tint)
        private const val ICE_R = 0.73f
        private const val ICE_G = 0.90f

        private val ICE_VERT = """
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

        // Solid ice seam: opaque colored sheet + frost rims + white-hot crack core
        // (prototype: deep solid base 0.7 alpha + white core line at full alpha).
        // Same program drives the trail and the polygon shards.
        private val ICE_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d     = abs(vCenterDist);
                float sheet = (1.0 - smoothstep(0.72, 1.00, d)) * 0.55;
                float rim   = smoothstep(0.55, 0.80, d) * (1.0 - smoothstep(0.90, 1.00, d)) * 0.85;
                float core  = exp(-d * d * 20.0) * 0.90;
                float w     = sheet + rim + core;
                vec3  col   = (vColor.rgb * sheet
                             + mix(vColor.rgb, vec3(1.0), 0.55) * rim
                             + mix(vColor.rgb, vec3(1.0), 0.90) * core) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }""".trimIndent()

        private val BLADE_VERT = """
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

        // 冰刃拖尾：銳利白藍刃口核心 + 俐落刀身 + 刃緣高光 + 沿刀身滑動的鏡面流光，
        // 尾端漸淡（冰刀劃過後的切痕乾淨消散）。
        private val BLADE_FRAG = """
            precision highp float;
            varying vec4 vColor;
            varying float vCenterDist;
            varying float vTrailDist;
            uniform float uTime;
            void main() {
                float d    = abs(vCenterDist);
                float life = vColor.a;

                // 刃口：細而銳的白藍切線
                float core = exp(-d * d * 26.0);
                // 刀身：平滑冰面，邊緣俐落收掉
                float body = 1.0 - smoothstep(0.55, 1.0, d);
                // 刃緣高光（兩側反光細線）
                float edge = smoothstep(0.78, 0.93, d) * (1.0 - smoothstep(0.93, 1.0, d));
                // 滑過鏡面流光：沿刀身流動的亮帶（冰刀反光在滑動）
                float sweep = sin(vTrailDist * 26.0 - uTime * 7.0);
                float gloss = smoothstep(0.55, 1.0, sweep) * body * (0.4 + 0.6 * life);

                float w = body * 0.5 + core * 0.95 + edge * 0.6 + gloss * 0.55;
                if (w <= 0.004) discard;

                vec3 base = vColor.rgb;
                vec3 col  = base * (body * 0.5)
                          + mix(base, vec3(1.0), 0.92) * core
                          + mix(base, vec3(1.0), 0.70) * edge
                          + vec3(1.0) * gloss * 0.55;
                col /= max(w, 0.001);

                float a = w * (0.25 + 0.75 * life);
                gl_FragColor = vec4(col, min(a, 1.0));
            }""".trimIndent()

        private val FOG_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position  = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }""".trimIndent()

        // 柔光點：冰霜晶亮（小、實心一點）與白霧（大、極柔）共用高斯衰減
        private val FOG_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2  coord = gl_PointCoord - vec2(0.5);
                float r2 = dot(coord, coord) * 4.0;
                if (r2 > 1.0) discard;
                float a = vColor.a * exp(-r2 * 2.4);
                gl_FragColor = vec4(vColor.rgb, a);
            }""".trimIndent()
    }
}
