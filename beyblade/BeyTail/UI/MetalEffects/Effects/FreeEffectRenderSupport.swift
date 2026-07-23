import UIKit

/// Shared geometry and color helpers for the three free dynamic-color effects.
enum FreeEffectRenderSupport {
    static func clipPosition(
        _ point: TrailPoint,
        context: MetalRenderContext
    ) -> (Float, Float) {
        (
            Float(point.center.x * 2 - 1) * context.quadScaleX,
            Float(1 - point.center.y * 2) * context.quadScaleY
        )
    }

    static func clipPerPixel(
        context: MetalRenderContext
    ) -> Float {
        2.0 / max(context.minDimension, 1)
    }

    static func mixedColor(
        _ color: UIColor,
        whiteMix: Float,
        alpha: Float
    ) -> (Float, Float, Float, Float) {
        let rgba = MetalHelper.rgba(color)
        let amount = whiteMix.metalClamped()

        return (
            rgba.0 + (1 - rgba.0) * amount,
            rgba.1 + (1 - rgba.1) * amount,
            rgba.2 + (1 - rgba.2) * amount,
            alpha.metalClamped()
        )
    }

    static func appendLineVertex(
        to buffer: MetalFloatBuffer,
        x: Float,
        y: Float,
        color: (Float, Float, Float, Float)
    ) {
        buffer
            .put(x)
            .put(y)
            .put(color.0)
            .put(color.1)
            .put(color.2)
            .put(color.3)
    }

    static func segmentNormal(
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float
    ) -> (Float, Float) {
        MetalHelper.segNormal(
            x0,
            y0,
            x1,
            y1
        )
    }

    static func hash(
        _ value: Float
    ) -> Float {
        let raw = sin(value * 12.9898 + 78.233) * 43_758.547
        return raw - floor(raw)
    }

    static func signedHash(
        _ value: Float
    ) -> Float {
        hash(value) * 2 - 1
    }
}
