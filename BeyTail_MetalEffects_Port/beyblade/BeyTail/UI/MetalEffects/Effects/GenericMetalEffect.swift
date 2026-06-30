import UIKit

/// Direct port of GenericMetalEffect.kt.
final class GenericMetalEffect: MetalEffect {
  private var program: MetalProgramID = 0
  private var posLoc: MetalLocation = -1
  private var colorLoc: MetalLocation = -1

  override func onMetalReady(context: MetalRenderContext) {
    program = MetalHelper.makeProgram(.flatColor)
    posLoc = metalGetAttribLocation(program, "aPosition")
    colorLoc = metalGetAttribLocation(program, "aColor")
  }

  override func draw(
    trackData: MetalTrackData,
    context: MetalRenderContext,
    effectType: EffectType
  ) {
    metalUseProgram(program)
    for (_, points) in trackData where points.count >= 2 {
      let color = effectType.colorOverride ?? points.last!.first.color
      drawRibbon(
        points,
        halfWidth: 0.070 * effectType.glowWidthMult,
        alphaScale: 0.45,
        coreBoost: 0,
        headColor: color,
        context: context
      )
      drawRibbon(
        points,
        halfWidth: 0.022 * effectType.coreWidthMult,
        alphaScale: 0.92,
        coreBoost: 0.55,
        headColor: color,
        context: context
      )
    }
  }

  private func drawRibbon(
    _ points: [MetalTrailSample],
    halfWidth: Float,
    alphaScale: Float,
    coreBoost: Float,
    headColor: UIColor,
    context: MetalRenderContext
  ) {
    let n = points.count
    guard n >= 2,
      n * 2 * Self.bytesPerVertex <= context.ribbonFloats.capacityBytes
    else {
      return
    }

    let base = MetalHelper.rgba(headColor)
    context.ribbonFloats.clear()

    for i in 0..<n {
      let sample = points[i]
      let point = sample.first
      let alpha = sample.second
      let x = Float(point.center.x * 2 - 1) * context.quadScaleX
      let y = Float(1 - point.center.y * 2) * context.quadScaleY

      let normal: (Float, Float)
      if i == 0 {
        let next = points[1].first.center
        normal = MetalHelper.segNormal(
          x, y,
          Float(next.x * 2 - 1) * context.quadScaleX,
          Float(1 - next.y * 2) * context.quadScaleY
        )
      } else if i == n - 1 {
        let previous = points[n - 2].first.center
        normal = MetalHelper.segNormal(
          Float(previous.x * 2 - 1) * context.quadScaleX,
          Float(1 - previous.y * 2) * context.quadScaleY,
          x, y
        )
      } else {
        let previous = points[i - 1].first.center
        let next = points[i + 1].first.center
        normal = MetalHelper.avgNormal(
          Float(previous.x * 2 - 1) * context.quadScaleX,
          Float(1 - previous.y * 2) * context.quadScaleY,
          x, y,
          Float(next.x * 2 - 1) * context.quadScaleX,
          Float(1 - next.y * 2) * context.quadScaleY
        )
      }

      let half = halfWidth * alpha * (1 - alpha * 0.7)
      let brighten: (Float) -> Float = { component in
        (component + (1 - component) * coreBoost * alpha).metalClamped()
      }
      let r = brighten(base.0)
      let g = brighten(base.1)
      let b = brighten(base.2)
      let a = alpha * alphaScale

      context.ribbonFloats
        .put(x - normal.0 * half).put(y - normal.1 * half)
        .put(r).put(g).put(b).put(a)
      context.ribbonFloats
        .put(x + normal.0 * half).put(y + normal.1 * half)
        .put(r).put(g).put(b).put(a)
    }

    MetalHelper.drawInterleaved(
      buffer: context.ribbonFloats,
      strideBytes: Self.bytesPerVertex,
      attributes: [
        MetalVertexAttribute(location: posLoc, size: 2, offsetBytes: 0),
        MetalVertexAttribute(location: colorLoc, size: 4, offsetBytes: 8),
      ],
      mode: MGL_TRIANGLE_STRIP,
      vertexCount: n * 2
    )
  }

  private static let bytesPerVertex = 24
}
