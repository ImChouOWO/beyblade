package com.beyblade.trailfilter.gl.effects

import android.opengl.GLES20
import com.beyblade.trailfilter.effects.EffectType
import com.beyblade.trailfilter.effects.TrailPoint
import com.beyblade.trailfilter.gl.GLEffect
import com.beyblade.trailfilter.gl.GLHelper
import com.beyblade.trailfilter.gl.GLRenderContext

/**
 * Generic ribbon trail for all effects that don't have custom GL logic.
 * Two ribbon passes: wide glow layer + narrow bright core.
 * Color = beyblade's detected dominant color (pts.last().first.color).
 */
class GenericGLEffect : GLEffect() {

    private var program  = 0
    private var posLoc   = -1
    private var colorLoc = -1

    override fun onGLReady(ctx: GLRenderContext) {
        program  = GLHelper.buildProgram(TRAIL_VERT, TRAIL_FRAG)
        posLoc   = GLES20.glGetAttribLocation(program, "aPosition")
        colorLoc = GLES20.glGetAttribLocation(program, "aColor")
    }

    override fun draw(
        trackData: Map<Int, List<Pair<TrailPoint, Float>>>,
        ctx: GLRenderContext,
        effectType: EffectType
    ) {
        GLES20.glUseProgram(program)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glEnableVertexAttribArray(colorLoc)
        for ((_, pts) in trackData) {
            if (pts.size < 2) continue
            // colorOverride wins (e.g. fire = red, lightning = yellow); otherwise beyblade color
            val color = effectType.colorOverride ?: pts.last().first.color
            drawRibbon(pts, 0.070f * effectType.glowWidthMult, alphaScale = 0.45f, coreBoost = 0.00f, color, ctx)
            drawRibbon(pts, 0.022f * effectType.coreWidthMult, alphaScale = 0.92f, coreBoost = 0.55f, color, ctx)
        }
        GLES20.glDisableVertexAttribArray(posLoc)
        GLES20.glDisableVertexAttribArray(colorLoc)
    }

    private fun drawRibbon(
        pts: List<Pair<TrailPoint, Float>>,
        halfWidth: Float,
        alphaScale: Float,
        coreBoost: Float,
        headColor: Int,
        ctx: GLRenderContext
    ) {
        val n = pts.size
        if (n < 2) return
        if (n * 2 * BYTES_PER_VERT > ctx.ribbonBuf.capacity()) return

        ctx.ribbonFloats.clear()

        for (i in 0 until n) {
            val (tp, alpha) = pts[i]
            val x = (tp.center.x * 2f - 1f) * ctx.quadScaleX
            val y = (1f - tp.center.y * 2f) * ctx.quadScaleY

            val (nx, ny) = when {
                i == 0 -> {
                    val (tp1, _) = pts[1]
                    GLHelper.segNormal(x, y, tp1.center.x * 2f - 1f, 1f - tp1.center.y * 2f)
                }
                i == n - 1 -> {
                    val (tpP, _) = pts[n - 2]
                    GLHelper.segNormal(tpP.center.x * 2f - 1f, 1f - tpP.center.y * 2f, x, y)
                }
                else -> {
                    val (tpP, _) = pts[i - 1]; val (tpN, _) = pts[i + 1]
                    GLHelper.avgNormal(
                        tpP.center.x * 2f - 1f, 1f - tpP.center.y * 2f,
                        x, y,
                        tpN.center.x * 2f - 1f, 1f - tpN.center.y * 2f
                    )
                }
            }

            val hw = halfWidth * alpha * (1f - alpha * 0.7f)
            val c = headColor
            fun ch(base: Float) = (base + (1f - base) * coreBoost * alpha).coerceIn(0f, 1f)
            val r = ch((c shr 16 and 0xFF) / 255f)
            val g = ch((c shr  8 and 0xFF) / 255f)
            val b = ch((c        and 0xFF) / 255f)
            val a = alpha * alphaScale

            ctx.ribbonFloats.put(x - nx * hw).put(y - ny * hw).put(r).put(g).put(b).put(a)
            ctx.ribbonFloats.put(x + nx * hw).put(y + ny * hw).put(r).put(g).put(b).put(a)
        }

        ctx.ribbonBuf.position(0)
        GLES20.glVertexAttribPointer(posLoc,   2, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(8)
        GLES20.glVertexAttribPointer(colorLoc, 4, GLES20.GL_FLOAT, false, BYTES_PER_VERT, ctx.ribbonBuf)
        ctx.ribbonBuf.position(0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, n * 2)
    }

    companion object {
        private const val BYTES_PER_VERT = 24  // 6 floats × 4 bytes

        private val TRAIL_VERT = """
            attribute vec2 aPosition;
            attribute vec4 aColor;
            varying vec4 vColor;
            void main() {
                gl_Position = vec4(aPosition, 0.0, 1.0);
                vColor = aColor;
            }""".trimIndent()

        private val TRAIL_FRAG = """
            precision mediump float;
            varying vec4 vColor;
            void main() {
                gl_FragColor = vColor;
            }""".trimIndent()
    }
}
