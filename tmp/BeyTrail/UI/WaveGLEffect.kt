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
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 滔天浪潮Wave effect GL rendering:
 *   - Fluid ribbon: procedural-noise water in the beyblade's color — dark
 *     under-currents, turbulence and crest sheen scrolled along the trail over
 *     time (water rolls forward), with ragged noise-torn edges
 *   - Side-spray + micro-bubble particles (circular gl_PointCoord)
 *   - Expanding ripple rings on fast movement
 */
class WaveGLEffect : GLEffect() {

    // ── GL programs ─────────────────────────────────────────────────────
    // fluid ribbon (noise shader, 8-float verts with trail distance)
    private var fluidProgram   = 0
    private var fluidPosLoc    = -1
    private var fluidColorLoc  = -1
    private var fluidDistLoc   = -1
    private var fluidTrailLoc  = -1
    private var fluidTimeLoc   = -1

    // simple soft band (used by ripple rings)
    private var waveProgram       = 0
    private var wavePosLoc        = -1
    private var waveColorLoc      = -1
    private var waveCenterDistLoc = -1

    private var particleProgram = 0
    private var partPosLoc      = -1
    private var partColorLoc    = -1
    private var partSizeLoc     = -1

    private var time = 0f

    // Reusable scratch arrays for fluid ribbon geometry
    private val ptX    = FloatArray(MAX_TRAIL_POINTS)
    private val ptY    = FloatArray(MAX_TRAIL_POINTS)
    private val cumLen = FloatArray(MAX_TRAIL_POINTS)

    // ── Particle pool ────────────────────────────────────────────────────
    private class Particle {
        var active = false
        var x = 0f; var y = 0f
        var vx = 0f; var vy = 0f
        var alpha = 0f; var sizePx = 0f
        var isBlue = false
    }
    private val particles = Array(50) { Particle() }
    private val lastPos   = HashMap<Int, Pair<Float, Float>>(8)

    // Owned particle buffer (separate from shared ribbonBuf)
    private val particleBuf:    ByteBuffer   = ByteBuffer.allocateDirect(1400).order(ByteOrder.nativeOrder())
    private val particleFloats: FloatBuffer  = particleBuf.asFloatBuffer()

    // ── Ripple pool ──────────────────────────────────────────────────────
    private class Ripple {
        var active = false
        var x = 0f; var y = 0f
        var radiusPx = 0f
        var alpha = 0f
    }
    private val ripples = Array(6) { Ripple() }

    // ── GL init ──────────────────────────────────────────────────────────

    override fun onGLReady(ctx: GLRenderContext) {
        fluidProgram  = GLHelper.buildProgram(FLUID_VERT, FLUID_FRAG)
        fluidPosLoc   = GLES20.glGetAttribLocation(fluidProgram, "aPosition")
        fluidColorLoc = GLES20.glGetAttribLocation(fluidProgram, "aColor")
        fluidDistLoc  = GLES20.glGetAttribLocation(fluidProgram, "aCenterDist")
        fluidTrailLoc = GLES20.glGetAttribLocation(fluidProgram, "aTrailDist")
        fluidTimeLoc  = GLES20.glGetUniformLocation(fluidProgram, "uTime")
        waveProgram       = GLHelper.buildProgram(WAVE_TRAIL_VERT, WAVE_TRAIL_FRAG)
        wavePosLoc        = GLES20.glGetAttribLocation(waveProgram, "aPosition")
        waveColorLoc      = GLES20.glGetAttribLocation(waveProgram, "aColor")
        waveCenterDistLoc = GLES20.glGetAttribLocation(waveProgram, "aCenterDist")
        particleProgram   = GLHelper.buildProgram(PARTICLE_VERT, PARTICLE_FRAG)
        partPosLoc        = GLES20.glGetAttribLocation(particleProgram, "aPosition")
        partColorLoc      = GLES20.glGetAttribLocation(particleProgram, "aColor")
        partSizeLoc       = GLES20.glGetAttribLocation(particleProgram, "aSize")
    }

    // ── draw (called every frame) ────────────────────────────────────────

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        time += (1f / 30f) * ctx.dtScale
        if (time > TIME_WRAP) time -= TIME_WRAP

        drawRibbons(trackData, ctx)
        spawnParticles(trackData, ctx)
        updateParticles(ctx.dtScale)
        drawParticles()
        updateRipples(ctx.dtScale)
        drawRipples(ctx)
    }

    // ── Fluid ribbon ─────────────────────────────────────────────────────

    private fun drawRibbons(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        GLES20.glUseProgram(fluidProgram)
        GLES20.glUniform1f(fluidTimeLoc, time)
        GLES20.glEnableVertexAttribArray(fluidPosLoc)
        GLES20.glEnableVertexAttribArray(fluidColorLoc)
        GLES20.glEnableVertexAttribArray(fluidDistLoc)
        GLES20.glEnableVertexAttribArray(fluidTrailLoc)
        for ((_, pts) in trackData) {
            if (pts.size >= 2) drawFluidRibbon(pts, ctx)
        }
        GLES20.glDisableVertexAttribArray(fluidPosLoc)
        GLES20.glDisableVertexAttribArray(fluidColorLoc)
        GLES20.glDisableVertexAttribArray(fluidDistLoc)
        GLES20.glDisableVertexAttribArray(fluidTrailLoc)
    }

    private fun drawFluidRibbon(pts: List<Pair<TrailPoint, Float>>, ctx: GLRenderContext) {
        val n = kotlin.math.min(pts.size, MAX_TRAIL_POINTS)
        if (n < 2 || n * 2 * BYTES_PER_VERT_FLUID > ctx.ribbonBuf.capacity()) return

        // beyblade color drives the water body
        val c  = pts.last().first.color
        val cr = (c shr 16 and 0xFF) / 255f
        val cg = (c shr  8 and 0xFF) / 255f
        val cb = (c        and 0xFF) / 255f

        for (i in 0 until n) {
            val tp = pts[i].first
            ptX[i] = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            ptY[i] = (1f - tp.center.y * 2f) * ctx.quadScaleY
            cumLen[i] = if (i == 0) 0f else {
                val dx = ptX[i] - ptX[i-1]; val dy = ptY[i] - ptY[i-1]
                cumLen[i-1] + sqrt(dx * dx + dy * dy)
            }
        }
        val totalLen = cumLen[n - 1]

        ctx.ribbonFloats.clear()
        for (i in 0 until n) {
            val x = ptX[i]; val y = ptY[i]
            val (nx, ny) = when {
                i == 0     -> GLHelper.segNormal(x, y, ptX[1], ptY[1])
                i == n - 1 -> GLHelper.segNormal(ptX[i-1], ptY[i-1], x, y)
                else       -> GLHelper.avgNormal(ptX[i-1], ptY[i-1], x, y, ptX[i+1], ptY[i+1])
            }
            val alpha = pts[i].second
            val hw    = 0.031f * (0.35f + 0.65f * alpha)   // thickest at head
            val trail = totalLen - cumLen[i]               // 0 at head
            ctx.ribbonFloats.put(x - nx*hw).put(y - ny*hw).put(cr).put(cg).put(cb).put(alpha).put(-1f).put(trail)
            ctx.ribbonFloats.put(x + nx*hw).put(y + ny*hw).put(cr).put(cg).put(cb).put(alpha).put(+1f).put(trail)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(fluidPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FLUID, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(fluidColorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FLUID, ctx.ribbonBuf)
        ctx.ribbonBuf.position(24)
        GLES20.glVertexAttribPointer(fluidDistLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FLUID, ctx.ribbonBuf)
        ctx.ribbonBuf.position(28)
        GLES20.glVertexAttribPointer(fluidTrailLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_FLUID, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, n * 2)
    }

    // ── Particles ────────────────────────────────────────────────────────

    private fun spawnParticles(trackData: Map<Int, List<Pair<TrailPoint, Float>>>, ctx: GLRenderContext) {
        for ((trackId, pts) in trackData) {
            if (pts.size < 2) continue
            val (tp,  _) = pts.last()
            val (tp1, _) = pts[pts.size - 2]
            val x  = (tp.center.x  * 2f - 1f) * ctx.quadScaleX
            val y  = (1f - tp.center.y  * 2f) * ctx.quadScaleY
            val x1 = (tp1.center.x * 2f - 1f) * ctx.quadScaleX
            val y1 = (1f - tp1.center.y * 2f) * ctx.quadScaleY

            val dx = x - x1; val dy = y - y1
            val moveLen = sqrt(dx * dx + dy * dy).coerceAtLeast(1e-5f)
            val perpX = -dy / moveLen
            val perpY =  dx / moveLen

            val last = lastPos[trackId]
            val dist = if (last != null) {
                val ldx = x - last.first; val ldy = y - last.second
                sqrt(ldx * ldx + ldy * ldy)
            } else Float.MAX_VALUE

            if (dist > 0.008f && Math.random() > 0.3) {
                lastPos[trackId] = x to y
                // normalize speed to the 30fps baseline (points are denser at 60fps)
                val moveNorm = moveLen / ctx.dtScale
                if (moveNorm > 0.015f && Math.random() > 0.5) spawnRipple(x, y)

                var spawned = 0
                for (p in particles) {
                    if (!p.active) {
                        p.active = true; p.x = x; p.y = y
                        val sideSign = if (spawned % 2 == 0) 1f else -1f
                        val strength = (moveNorm * 1.5f).coerceIn(0.02f, 0.045f)
                        p.vx = perpX * sideSign * strength + (Math.random().toFloat() - 0.5f) * 0.018f
                        p.vy = perpY * sideSign * strength + (Math.random().toFloat() - 0.5f) * 0.018f - 0.012f
                        p.sizePx = (Math.random() * 8f + 6f).toFloat()
                        p.alpha = 1.0f; p.isBlue = Math.random() > 0.3
                        if (++spawned >= 3) break
                    }
                }
                // Micro-bubbles along trail body
                if (pts.size > 4 && Math.random() > 0.6) {
                    val (btp, _) = pts[pts.size / 3]
                    val bx = (btp.center.x * 2f - 1f) * ctx.quadScaleX
                    val by = (1f - btp.center.y * 2f) * ctx.quadScaleY
                    for (p in particles) {
                        if (!p.active) {
                            p.active = true
                            p.x = bx + (Math.random().toFloat() - 0.5f) * 0.02f
                            p.y = by + (Math.random().toFloat() - 0.5f) * 0.02f
                            p.vx = (Math.random().toFloat() - 0.5f) * 0.006f
                            p.vy = -(Math.random().toFloat() * 0.012f + 0.005f)
                            p.sizePx = (Math.random() * 4f + 2f).toFloat()
                            p.alpha = 0.6f; p.isBlue = true; break
                        }
                    }
                }
            }
        }
    }

    private fun updateParticles(dt: Float) {
        for (p in particles) {
            if (!p.active) continue
            p.x += p.vx * dt; p.y += p.vy * dt
            p.vy += 0.001f * dt
            p.alpha -= 0.06f * dt
            if (p.alpha <= 0f) p.active = false
        }
    }

    private fun drawParticles() {
        particleFloats.clear()
        var count = 0
        for (p in particles) {
            if (!p.active) continue
            val r = if (p.isBlue) 0.749f else 1f
            val g = if (p.isBlue) 0.906f else 1f
            val b = if (p.isBlue) 1.000f else 1f
            particleFloats.put(p.x).put(p.y).put(r).put(g).put(b).put(p.alpha.coerceIn(0f, 1f)).put(p.sizePx)
            count++
        }
        if (count == 0) return

        GLES20.glUseProgram(particleProgram)
        GLES20.glEnableVertexAttribArray(partPosLoc)
        GLES20.glEnableVertexAttribArray(partColorLoc)
        GLES20.glEnableVertexAttribArray(partSizeLoc)
        particleBuf.position(0)
        GLES20.glVertexAttribPointer(partPosLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_PARTICLE, particleBuf)
        particleBuf.position(8)
        GLES20.glVertexAttribPointer(partColorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_PARTICLE, particleBuf)
        particleBuf.position(24)
        GLES20.glVertexAttribPointer(partSizeLoc,  1, GLES20.GL_FLOAT, false, BYTES_PER_PARTICLE, particleBuf)
        particleBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(partPosLoc)
        GLES20.glDisableVertexAttribArray(partColorLoc)
        GLES20.glDisableVertexAttribArray(partSizeLoc)
    }

    // ── Ripples ──────────────────────────────────────────────────────────

    private fun spawnRipple(x: Float, y: Float) {
        for (r in ripples) {
            if (!r.active) { r.active = true; r.x = x; r.y = y; r.radiusPx = 0f; r.alpha = 0.85f; break }
        }
    }

    private fun updateRipples(dt: Float) {
        for (r in ripples) {
            if (!r.active) continue
            r.radiusPx += 5f * dt; r.alpha -= 0.04f * dt
            if (r.alpha <= 0f) r.active = false
        }
    }

    private fun drawRipples(ctx: GLRenderContext) {
        if (ripples.none { it.active }) return

        GLES20.glUseProgram(waveProgram)
        GLES20.glEnableVertexAttribArray(wavePosLoc)
        GLES20.glEnableVertexAttribArray(waveColorLoc)
        GLES20.glEnableVertexAttribArray(waveCenterDistLoc)

        val vw = ctx.viewWidth.toFloat(); val vh = ctx.viewHeight.toFloat()
        for (r in ripples) {
            if (!r.active) continue
            val innerPx = (r.radiusPx - RING_WIDTH_PX).coerceAtLeast(0f)
            val outerPx = r.radiusPx + RING_WIDTH_PX
            val iRx = innerPx / (vw / 2f); val iRy = innerPx / (vh / 2f)
            val oRx = outerPx / (vw / 2f); val oRy = outerPx / (vh / 2f)
            val a = r.alpha.coerceIn(0f, 1f)

            ctx.ribbonFloats.clear()
            for (i in 0..RING_SEGMENTS) {
                val angle = (i.toFloat() / RING_SEGMENTS * 2f * Math.PI).toFloat()
                val cosA = cos(angle); val sinA = sin(angle)
                ctx.ribbonFloats.put(r.x + iRx*cosA).put(r.y + iRy*sinA).put(0.71f).put(0.90f).put(1f).put(a).put(-1f)
                ctx.ribbonFloats.put(r.x + oRx*cosA).put(r.y + oRy*sinA).put(0.71f).put(0.90f).put(1f).put(a).put(+1f)
            }
            ctx.ribbonBuf.position(0)
            GLES20.glVertexAttribPointer(wavePosLoc,        2, GLES20.GL_FLOAT, false, BYTES_PER_VERT_WAVE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(8)
            GLES20.glVertexAttribPointer(waveColorLoc,      4, GLES20.GL_FLOAT, false, BYTES_PER_VERT_WAVE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(24)
            GLES20.glVertexAttribPointer(waveCenterDistLoc, 1, GLES20.GL_FLOAT, false, BYTES_PER_VERT_WAVE, ctx.ribbonBuf)
            ctx.ribbonBuf.position(0)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, (RING_SEGMENTS + 1) * 2)
        }

        GLES20.glDisableVertexAttribArray(wavePosLoc)
        GLES20.glDisableVertexAttribArray(waveColorLoc)
        GLES20.glDisableVertexAttribArray(waveCenterDistLoc)
    }

    // ── Shaders & constants ──────────────────────────────────────────────

    companion object {
        private const val BYTES_PER_VERT_WAVE  = 28   // 7 floats × 4
        private const val BYTES_PER_VERT_FLUID = 32   // 8 floats × 4
        private const val MAX_TRAIL_POINTS     = 256
        private const val TIME_WRAP            = 120f // noise jumps once per 2 min — invisible

        private val FLUID_VERT = """
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

        // Real-liquid body in the beyblade's color: scrolling value noise gives
        // dark under-currents + turbulence + rolling crest sheen (water rolls
        // forward along the trail), and tears the edges irregularly. No white —
        // highlights are the beyblade color lifted 50%, so the hue always wins.
        private val FLUID_FRAG = """
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
                float d = abs(vCenterDist);

                // flow space scrolls backward over time → water rolls forward
                vec2  uv   = vec2(vTrailDist * 14.0 - uTime * 6.0, vCenterDist * 2.2);
                float n1   = noise(uv);                          // broad under-currents
                float n2   = noise(uv * 2.7 + 13.7);             // fine turbulence
                float turb = n1 * 0.65 + n2 * 0.35;

                // ragged silhouette — noise tears the edge dynamically
                float edgeCut = 0.74 + (turb - 0.5) * 0.40;
                float body = 1.0 - smoothstep(edgeCut - 0.15, edgeCut + 0.10, d);
                if (body <= 0.004) discard;

                // dark currents + ripple shading, hue stays the beyblade's
                vec3 col = vColor.rgb * (0.78 + 0.30 * turb);
                // rolling crest sheen: color lifted 50%, not white
                float crest = smoothstep(0.72, 0.88, n2);
                col = mix(col, vColor.rgb * 0.5 + vec3(0.5), crest * 0.45);

                float a = body * (0.45 + 0.50 * vColor.a) * (0.85 + 0.15 * turb);
                gl_FragColor = vec4(col, a);
            }""".trimIndent()

        private const val BYTES_PER_PARTICLE  = 28   // 7 floats × 4
        private const val RING_SEGMENTS       = 24
        private const val RING_WIDTH_PX       = 5f

        private val WAVE_TRAIL_VERT = """
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

        private val WAVE_TRAIL_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            varying float vCenterDist;
            void main() {
                float dist = abs(vCenterDist);
                float glow = 1.0 - dist * dist;
                gl_FragColor = vec4(vColor.rgb, vColor.a * glow);
            }""".trimIndent()

        private val PARTICLE_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            attribute float aSize;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                gl_PointSize = aSize;
                vColor = aColor;
            }""".trimIndent()

        private val PARTICLE_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                vec2 coord = gl_PointCoord - vec2(0.5);
                float dist = length(coord) * 2.0;
                if (dist > 1.0) discard;
                float alpha = vColor.a * (1.0 - dist * dist);
                gl_FragColor = vec4(vColor.rgb, alpha);
            }""".trimIndent()
    }
}
