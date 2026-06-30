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
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 爆刃亂舞 effect — cold steel slash (ported from the 冷冽斬擊 canvas prototype):
 *   - The whole trail is ONE willow-leaf blade: short, pointed at both ends,
 *     fat belly; gradient along its length (transparent tail → colored body →
 *     white-hot head) + razor-thin white center line
 *   - Metal grinding sparks: silver-white / pale-gold velocity streaks
 *   - Slash cracks: brief thin lines parallel to the cut (破空痕, ~4 frames)
 *
 * Single shader program, deliberately minimal.
 */
class BladeGLEffect : GLEffect() {

    private var program  = 0
    private var posLoc   = -1
    private var colorLoc = -1
    private var distLoc  = -1

    // ── Metal sparks (position in NDC, velocity in px/frame) ──────────────
    private class Spark {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f
        var alpha = 0f
        var r = 1f; var g = 1f; var b = 1f
    }
    private val sparks = Array(MAX_SPARKS) { Spark() }
    private val sparkBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MAX_SPARKS * 6 * BYTES_PER_VERT).order(ByteOrder.nativeOrder())
    private val sparkFloats: FloatBuffer = sparkBuf.asFloatBuffer()

    // ── Slash cracks: thin lines parallel to the cut, gone in ~4 frames ───
    private class Crack {
        var active = false
        var x1 = 0f; var y1 = 0f
        var x2 = 0f; var y2 = 0f
        var alpha = 0f
    }
    private val cracks = Array(MAX_CRACKS) { Crack() }

    // ── Blade glints: cross-shaped metal flashes popping along the blade ──
    private class Glint {
        var active = false
        var x = 0f; var y = 0f
        var angle = 0f
        var sizePx = 0f
        var progress = 0f               // 0→1, alpha follows sin(π·progress)
    }
    private val glints = Array(MAX_GLINTS) { Glint() }

    // ── Sword-qi waves: crescent slash projectiles flying off the swing ───
    private class Wave {
        var active = false
        var x = 0f; var y = 0f          // arc center (NDC)
        var angle = 0f                  // flight direction (screen space)
        var vx = 0f; var vy = 0f        // px/frame
        var radiusPx = 0f
        var alpha = 0f
        var r = 1f; var g = 1f; var b = 1f
    }
    private val waves = Array(MAX_WAVES) { Wave() }

    private val lastPos = HashMap<Int, Pair<Float, Float>>(8)

    // Reusable scratch arrays for blade geometry
    private val ptX = FloatArray(MAX_TRAIL_POINTS)
    private val ptY = FloatArray(MAX_TRAIL_POINTS)
    // Resampled centerline (×3 density, smooth helix) + per-point alpha
    private val rX = FloatArray(MAX_RESAMPLE)
    private val rY = FloatArray(MAX_RESAMPLE)
    private val rA = FloatArray(MAX_RESAMPLE)
    private val hsvScratch = FloatArray(3)

    // ── GL init ───────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        program  = GLHelper.buildProgram(BLADE_VERT, BLADE_FRAG)
        posLoc   = GLES20.glGetAttribLocation(program, "aPosition")
        colorLoc = GLES20.glGetAttribLocation(program, "aColor")
        distLoc  = GLES20.glGetAttribLocation(program, "aCenterDist")
    }

    // ── draw ──────────────────────────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        GLES20.glUseProgram(program)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glEnableVertexAttribArray(colorLoc)
        GLES20.glEnableVertexAttribArray(distLoc)

        spawnFromTrack(trackData, ctx)
        for ((_, pts) in trackData) {
            if (pts.size >= 3) drawBlade(pts, ctx)
        }
        updateCracks(ctx.dtScale)
        drawCracks(ctx)
        updateSparks(ctx)
        drawSparks(ctx)
        updateWaves(ctx)
        drawWaves(ctx)
        updateGlints(ctx.dtScale)
        drawGlints(ctx)

        GLES20.glDisableVertexAttribArray(posLoc)
        GLES20.glDisableVertexAttribArray(colorLoc)
        GLES20.glDisableVertexAttribArray(distLoc)
    }

    // ── Double-helix blade trail ──────────────────────────────────────────
    // Two thin blades weave around the centerline in a crossing helix (phase
    // offset π). Colors: saturated beyblade color + a hue-shifted neighbour,
    // both blending into a white blade edge over the front 25%.

    private fun drawBlade(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = min(pts.size, MAX_TRAIL_POINTS)
        if (n < 3) return

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
        }

        // resample ×3 so the helix curves smoothly between sparse trail points
        val m = (n * 3).coerceAtMost(MAX_RESAMPLE)
        for (j in 0 until m) {
            val f  = j.toFloat() / (m - 1) * (n - 1)
            val i0 = f.toInt().coerceAtMost(n - 2)
            val fr = f - i0
            rX[j] = ptX[i0] + (ptX[i0+1] - ptX[i0]) * fr
            rY[j] = ptY[i0] + (ptY[i0+1] - ptY[i0]) * fr
            rA[j] = pts[i0].second + (pts[i0+1].second - pts[i0].second) * fr
        }
        if (m * 2 * BYTES_PER_VERT > ctx.ribbonBuf.capacity()) return

        // two stacked near-neighbour colors, fully saturated
        val base = saturate(pts.last().first.color)
        val twin = hueShift(base, 38f)

        for (strand in 0 until 2) {
            val c  = if (strand == 0) base else twin
            val cr = (c shr 16 and 0xFF) / 255f
            val cg = (c shr  8 and 0xFF) / 255f
            val cb = (c        and 0xFF) / 255f
            val phase0 = strand * PI_F                     // strands cross each other

            ctx.ribbonFloats.clear()
            for (j in 0 until m) {
                val x = rX[j]; val y = rY[j]
                val (nx, ny) = when {
                    j == 0     -> GLHelper.segNormal(x, y, rX[1], rY[1])
                    j == m - 1 -> GLHelper.segNormal(rX[j-1], rY[j-1], x, y)
                    else       -> GLHelper.avgNormal(rX[j-1], rY[j-1], x, y, rX[j+1], rY[j+1])
                }

                val u   = j.toFloat() / (m - 1)            // 0 = tail, 1 = head
                val env = sin(PI_F * u)                    // blade envelope, pointed ends
                // helix offset around the centerline
                val off = sin(u * HELIX_TURNS * 2f * PI_F + phase0) * HELIX_AMP * env
                val cx  = x + nx * off
                val cy  = y + ny * off
                val hw  = STRAND_HALF_WIDTH * env

                // prototype gradient: 0 → 0.5 @0.3 → 0.95 @0.8 → 1.0 (head)
                val aT = when {
                    u < 0.3f -> u / 0.3f * 0.5f
                    u < 0.8f -> 0.5f + (u - 0.3f) / 0.5f * 0.45f
                    else     -> 0.95f + (u - 0.8f) / 0.2f * 0.05f
                }
                val a = aT * sqrt(rA[j])                   // engine fade on top

                // saturated body → white blade edge over the front 25%
                val wMix = ((u - 0.75f) / 0.25f).coerceIn(0f, 1f)
                val r = cr + (1f - cr) * wMix
                val g = cg + (1f - cg) * wMix
                val b = cb + (1f - cb) * wMix

                ctx.ribbonFloats.put(cx - nx*hw).put(cy - ny*hw).put(r).put(g).put(b).put(a).put(-1f)
                ctx.ribbonFloats.put(cx + nx*hw).put(cy + ny*hw).put(r).put(g).put(b).put(a).put(+1f)
            }

            ctx.ribbonBuf.position(0)
            GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(8)
            GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(24)
            GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(0)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, m * 2)
        }
    }

    /** Full saturation + brightness on the detected color (keeps the hue). */
    private fun saturate(color: Int): Int {
        android.graphics.Color.colorToHSV(color, hsvScratch)
        hsvScratch[1] = hsvScratch[1].coerceAtLeast(0.85f)
        hsvScratch[2] = 1f
        return android.graphics.Color.HSVToColor(hsvScratch)
    }

    /** Neighbouring hue for the second strand. */
    private fun hueShift(color: Int, deg: Float): Int {
        android.graphics.Color.colorToHSV(color, hsvScratch)
        hsvScratch[0] = (hsvScratch[0] + deg + 360f) % 360f
        return android.graphics.Color.HSVToColor(hsvScratch)
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

            if (dist > 0.005f) {
                lastPos[trackId] = x to y
                // normalize speed to the 30fps baseline (points are denser at 60fps)
                val moveNorm = moveLen / ctx.dtScale
                // metal shavings + glints peeling off the blade body while moving
                if (moveNorm > 0.009f) {
                    emitFromBody(pts, minDim, ctx)
                }
                // only on fast slashes (prototype: speed > 10)
                if (moveNorm > 0.013f) {
                    // velocity in px-per-30fps-frame for spark inheritance
                    val vxPx = dx * vw * 0.5f / ctx.dtScale
                    val vyPx = dy * vh * 0.5f / ctx.dtScale
                    if (Math.random() > 0.3) spawnSpark(x, y, vxPx, vyPx)
                    if (Math.random() > 0.5) spawnSpark(x, y, vxPx, vyPx)
                    if (Math.random() > 0.4) spawnCrack(x1, y1, x, y, minDim, ctx)
                    // sword-qi wave launched along the swing, occasionally
                    if (Math.random() > 0.55) {
                        val moveAngle = kotlin.math.atan2(dy * vh, dx * vw)
                        spawnWave(x, y, moveAngle, moveNorm, minDim, tp.color)
                    }
                }
            }
        }
    }

    /** Shavings sprayed sideways off a random point of the blade body + a glint. */
    private fun emitFromBody(pts: List<Pair<TrailPoint, Float>>, minDim: Float, ctx: GLRenderContext) {
        val n = pts.size
        if (n < 3) return
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()

        val idx = 1 + (Math.random() * (n - 2)).toInt().coerceAtMost(n - 3)
        val tp  = pts[idx].first
        val tpP = pts[idx - 1].first; val tpN = pts[idx + 1].first
        val bx = (tp.center.x * 2f - 1f) * ctx.quadScaleX
        val by = (1f - tp.center.y * 2f) * ctx.quadScaleY
        // local blade direction in px space → perpendicular spray
        val dxP = (tpN.center.x - tpP.center.x) * ctx.quadScaleX * vw
        val dyP = -(tpN.center.y - tpP.center.y) * ctx.quadScaleY * vh
        val len = sqrt(dxP * dxP + dyP * dyP).coerceAtLeast(1e-3f)
        val pxN = -dyP / len; val pyN = dxP / len

        var count = if (Math.random() > 0.5) 2 else 1
        while (count-- > 0) {
            val side  = if (Math.random() > 0.5) 1f else -1f
            val burst = Math.random().toFloat() * 5f + 3f
            spawnSparkRaw(
                bx, by,
                pxN * side * burst - dxP / len * (Math.random().toFloat() * 2.5f)
                    + (Math.random().toFloat() - 0.5f) * 3f,
                pyN * side * burst - dyP / len * (Math.random().toFloat() * 2.5f)
                    + (Math.random().toFloat() - 0.5f) * 3f)
        }
        if (Math.random() > 0.45) spawnGlint(bx, by, minDim)
    }

    private fun spawnGlint(x: Float, y: Float, minDim: Float) {
        for (g in glints) {
            if (g.active) continue
            g.active = true
            g.x = x + (Math.random().toFloat() - 0.5f) * 0.015f
            g.y = y + (Math.random().toFloat() - 0.5f) * 0.015f
            g.angle    = Math.random().toFloat() * PI_F
            g.sizePx   = minDim * (0.008f + Math.random().toFloat() * 0.008f)
            g.progress = 0f
            return
        }
    }

    private fun spawnSparkRaw(x: Float, y: Float, vx: Float, vy: Float) {
        for (s in sparks) {
            if (s.active) continue
            s.active = true
            s.x = x; s.y = y
            s.vx = vx; s.vy = vy
            s.alpha = 1f
            if (Math.random() > 0.4) {
                s.r = 0.88f; s.g = 0.95f; s.b = 1.00f      // silver white
            } else {
                s.r = 1.00f; s.g = 0.94f; s.b = 0.54f      // pale gold
            }
            return
        }
    }

    /** Prototype head spark: inherit the slash velocity + random scatter (v·0.4 ± 5). */
    private fun spawnSpark(x: Float, y: Float, vxPx: Float, vyPx: Float) {
        spawnSparkRaw(
            x, y,
            vxPx * 0.4f + (Math.random().toFloat() - 0.5f) * 10f,
            vyPx * 0.4f + (Math.random().toFloat() - 0.5f) * 10f)
    }

    private fun spawnCrack(x1: Float, y1: Float, x2: Float, y2: Float, minDim: Float, ctx: GLRenderContext) {
        for (cr in cracks) {
            if (cr.active) continue
            val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
            // parallel offset to the side of the cut (prototype: ±16px)
            val dxP = (x2 - x1) * vw; val dyP = (y2 - y1) * vh
            val len = sqrt(dxP * dxP + dyP * dyP).coerceAtLeast(1e-3f)
            val offPx = (Math.random().toFloat() - 0.5f) * minDim * 0.030f
            val ox = -dyP / len * offPx / (vw / 2f)
            val oy =  dxP / len * offPx / (vh / 2f)
            // stretch the line a little past the segment
            val ex = (x2 - x1) * 0.8f; val ey = (y2 - y1) * 0.8f
            cr.active = true
            cr.x1 = x1 + ox - ex; cr.y1 = y1 + oy - ey
            cr.x2 = x2 + ox + ex; cr.y2 = y2 + oy + ey
            cr.alpha = 0.9f
            return
        }
    }

    // ── Slash cracks ──────────────────────────────────────────────────────

    private fun updateCracks(dt: Float) {
        for (cr in cracks) {
            if (!cr.active) continue
            cr.alpha -= 0.25f * dt                         // ~4-frame life @30fps
            if (cr.alpha <= 0f) cr.active = false
        }
    }

    private fun drawCracks(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val halfWPx = 1.2f

        ctx.ribbonFloats.clear()
        var vertCount = 0
        for (cr in cracks) {
            if (!cr.active) continue
            val dxP = (cr.x2 - cr.x1) * vw; val dyP = (cr.y2 - cr.y1) * vh
            val len = sqrt(dxP * dxP + dyP * dyP).coerceAtLeast(1e-3f)
            val nx = -dyP / len * halfWPx / (vw / 2f)
            val ny =  dxP / len * halfWPx / (vh / 2f)
            val a = cr.alpha.coerceIn(0f, 1f) * 0.6f

            fun put(qx: Float, qy: Float, d: Float) {
                ctx.ribbonFloats.put(qx).put(qy).put(0.73f).put(0.90f).put(0.99f).put(a).put(d)
            }
            put(cr.x1 - nx, cr.y1 - ny, -1f)
            put(cr.x1 + nx, cr.y1 + ny, +1f)
            put(cr.x2 - nx, cr.y2 - ny, -1f)
            put(cr.x1 + nx, cr.y1 + ny, +1f)
            put(cr.x2 + nx, cr.y2 + ny, +1f)
            put(cr.x2 - nx, cr.y2 - ny, -1f)
            vertCount += 6
        }
        if (vertCount == 0) return

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
    }

    // ── Metal sparks ──────────────────────────────────────────────────────

    private fun updateSparks(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        val fr = 1f - 0.08f * dt
        for (s in sparks) {
            if (!s.active) continue
            s.x += s.vx * dt / (vw * 0.5f)
            s.y += s.vy * dt / (vh * 0.5f)
            s.vx *= fr; s.vy *= fr
            s.alpha -= 0.12f * dt
            if (s.alpha <= 0f) s.active = false
        }
    }

    private fun drawSparks(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val halfWPx = 1.6f

        sparkFloats.clear()
        var vertCount = 0
        for (s in sparks) {
            if (!s.active) continue
            val speed = sqrt(s.vx * s.vx + s.vy * s.vy).coerceAtLeast(1e-3f)
            val dirX = s.vx / speed; val dirY = s.vy / speed
            // streak length follows velocity (prototype: pos → pos + v·1.5)
            val lenPx = speed * 1.5f + 4f

            val ex  = s.x + dirX * lenPx / (vw * 0.5f)
            val ey  = s.y + dirY * lenPx / (vh * 0.5f)
            val nxN = -dirY * halfWPx    / (vw * 0.5f)
            val nyN =  dirX * halfWPx    / (vh * 0.5f)

            val a = s.alpha.coerceIn(0f, 1f)
            fun put(px: Float, py: Float, d: Float, va: Float) {
                sparkFloats.put(px).put(py).put(s.r).put(s.g).put(s.b).put(va).put(d)
            }
            put(s.x - nxN, s.y - nyN, -1f, a)
            put(s.x + nxN, s.y + nyN, +1f, a)
            put(ex  - nxN, ey  - nyN, -1f, a * 0.25f)
            put(s.x + nxN, s.y + nyN, +1f, a)
            put(ex  + nxN, ey  + nyN, +1f, a * 0.25f)
            put(ex  - nxN, ey  - nyN, -1f, a * 0.25f)
            vertCount += 6
        }
        if (vertCount == 0) return

        sparkBuf.position(0)
        GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(8)
        GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(24)
        GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, sparkBuf)
        sparkBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
    }

    // ── Sword-qi waves ────────────────────────────────────────────────────

    private fun spawnWave(x: Float, y: Float, moveAngle: Float, moveLen: Float, minDim: Float, color: Int) {
        for (w in waves) {
            if (w.active) continue
            val speedPx = 10f + Math.random().toFloat() * 6f + moveLen * minDim * 0.15f
            w.active = true
            w.x = x; w.y = y
            w.angle = moveAngle + (Math.random().toFloat() - 0.5f) * 0.4f
            w.vx = kotlin.math.cos(w.angle) * speedPx
            w.vy = sin(w.angle) * speedPx
            w.radiusPx = minDim * (0.035f + Math.random().toFloat() * 0.020f)
            w.alpha = 0.95f
            val c  = saturate(color)
            val cr = (c shr 16 and 0xFF) / 255f
            val cg = (c shr  8 and 0xFF) / 255f
            val cb = (c        and 0xFF) / 255f
            w.r = cr * 0.75f + 0.25f; w.g = cg * 0.75f + 0.25f; w.b = cb * 0.75f + 0.25f
            return
        }
    }

    private fun updateWaves(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val dt = ctx.dtScale
        for (w in waves) {
            if (!w.active) continue
            w.x += w.vx * dt / (vw * 0.5f)
            w.y += w.vy * dt / (vh * 0.5f)
            w.radiusPx *= 1f + 0.03f * dt                  // grows slightly in flight
            w.alpha -= 0.10f * dt                          // ~10-frame flight @30fps
            if (w.alpha <= 0f) w.active = false
        }
    }

    private fun drawWaves(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val minDim = minOf(vw, vh)
        val maxW = minDim * 0.0080f

        for (w in waves) {
            if (!w.active) continue
            val a = w.alpha.coerceIn(0f, 1f)

            ctx.ribbonFloats.clear()
            for (i in 0..WAVE_SEGMENTS) {
                val t   = i.toFloat() / WAVE_SEGMENTS
                val ang = w.angle - WAVE_HALF_SPAN + t * 2f * WAVE_HALF_SPAN
                val wPx = maxW * sin(PI_F * t)             // pointed crescent tips
                val iPx = (w.radiusPx - wPx).coerceAtLeast(0f)
                val oPx = w.radiusPx + wPx
                val cA = kotlin.math.cos(ang); val sA = sin(ang)
                ctx.ribbonFloats.put(w.x + cA * iPx / (vw/2f)).put(w.y + sA * iPx / (vh/2f))
                    .put(w.r).put(w.g).put(w.b).put(a).put(-1f)
                ctx.ribbonFloats.put(w.x + cA * oPx / (vw/2f)).put(w.y + sA * oPx / (vh/2f))
                    .put(w.r).put(w.g).put(w.b).put(a).put(+1f)
            }
            ctx.ribbonBuf.position(0)
            GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(8)
            GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(24)
            GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
            ctx.ribbonBuf.position(0)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, (WAVE_SEGMENTS + 1) * 2)
        }
    }

    // ── Blade glints (cross-shaped metal flashes) ─────────────────────────

    private fun updateGlints(dt: Float) {
        for (g in glints) {
            if (!g.active) continue
            g.progress += 0.16f * dt                       // ~6-frame pop @30fps
            if (g.progress >= 1f) g.active = false
        }
    }

    private fun drawGlints(ctx: GLRenderContext) {
        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        if (vw <= 0f || vh <= 0f) return

        ctx.ribbonFloats.clear()
        var vertCount = 0
        for (g in glints) {
            if (!g.active) continue
            val a = sin(PI_F * g.progress)                 // pop in, pop out
            val armW = g.sizePx * 0.16f

            // two crossed arms (X), each a thin quad with a white core line
            for (arm in 0 until 2) {
                val ang  = g.angle + arm * HALF_PI
                val dirX = kotlin.math.cos(ang); val dirY = sin(ang)
                val lx = dirX * g.sizePx / (vw / 2f); val ly = dirY * g.sizePx / (vh / 2f)
                val nx = -dirY * armW    / (vw / 2f); val ny = dirX * armW    / (vh / 2f)

                fun put(qx: Float, qy: Float, d: Float) {
                    ctx.ribbonFloats.put(qx).put(qy).put(0.95f).put(0.98f).put(1f).put(a).put(d)
                }
                put(g.x - lx, g.y - ly,  0f)
                put(g.x + nx, g.y + ny, +1f)
                put(g.x - nx, g.y - ny, -1f)
                put(g.x + nx, g.y + ny, +1f)
                put(g.x + lx, g.y + ly,  0f)
                put(g.x - nx, g.y - ny, -1f)
                vertCount += 6
            }
        }
        if (vertCount == 0) return

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(distLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertCount)
    }

    // ── Shaders & constants ───────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT   = 28   // 7 floats × 4
        private const val MAX_SPARKS       = 28
        private const val MAX_CRACKS       = 4
        private const val MAX_GLINTS       = 10
        private const val MAX_WAVES        = 4
        private const val WAVE_SEGMENTS    = 12
        private val WAVE_HALF_SPAN         = (Math.PI / 3.2).toFloat()   // ~±56° crescent
        private const val MAX_TRAIL_POINTS = 256
        private const val MAX_RESAMPLE     = 64      // ×3 resampled centerline cap
        private const val HELIX_TURNS      = 2.2f    // crossings along the blade
        private const val HELIX_AMP        = 0.016f  // weave offset from centerline
        private const val STRAND_HALF_WIDTH = 0.012f // each strand's belly half-width
        private const val PI_F             = Math.PI.toFloat()
        private const val HALF_PI          = (Math.PI / 2).toFloat()

        private val BLADE_VERT = """
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

        // Solid blade body + razor-thin white center line (the cutting edge).
        private val BLADE_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float d    = abs(vCenterDist);
                float body = 1.0 - smoothstep(0.65, 1.0, d);
                float core = exp(-d * d * 26.0);
                float w    = body * 0.90 + core * 0.55;
                vec3  col  = (vColor.rgb * body * 0.90
                            + vec3(1.0) * core * 0.55) / max(w, 0.001);
                gl_FragColor = vec4(col, vColor.a * min(w, 1.0));
            }""".trimIndent()
    }
}
