import CoreGraphics
import UIKit

/// Shared CPU geometry helpers used by the direct Kotlin-to-Swift effect ports.
enum MetalHelper {
    static func makeProgram(
        _ shader: MetalShaderKind
    ) -> MetalProgramID {
        shader.programID
    }

    static func drawInterleaved(
        buffer: MetalFloatBuffer,
        strideBytes: Int,
        attributes: [MetalVertexAttribute],
        mode: MetalPrimitiveCode,
        vertexCount: Int
    ) {
        MetalRuntime.current?.drawInterleaved(
            buffer: buffer,
            strideBytes: strideBytes,
            attributes: attributes,
            primitiveCode: mode,
            vertexCount: vertexCount
        )
    }

    static func segNormal(
        _ x1: Float,
        _ y1: Float,
        _ x2: Float,
        _ y2: Float
    ) -> (Float, Float) {
        let dx = x2 - x1
        let dy = y2 - y1
        let length = max(sqrt(dx * dx + dy * dy), 0.000_001)
        return (-dy / length, dx / length)
    }

    static func avgNormal(
        _ x0: Float,
        _ y0: Float,
        _ x1: Float,
        _ y1: Float,
        _ x2: Float,
        _ y2: Float
    ) -> (Float, Float) {
        let n1 = segNormal(x0, y0, x1, y1)
        let n2 = segNormal(x1, y1, x2, y2)
        let nx = n1.0 + n2.0
        let ny = n1.1 + n2.1
        let length = max(sqrt(nx * nx + ny * ny), 0.000_001)
        return (nx / length, ny / length)
    }

    static func rgba(
        _ color: UIColor
    ) -> (Float, Float, Float, Float) {
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Float(r), Float(g), Float(b), Float(a))
        }
        var white: CGFloat = 1
        color.getWhite(&white, alpha: &a)
        return (Float(white), Float(white), Float(white), Float(a))
    }

    static func vivid(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        guard color.getHue(
            &h,
            saturation: &s,
            brightness: &b,
            alpha: &a
        ) else {
            return color
        }
        return UIColor(
            hue: h,
            saturation: max(s, 0.85),
            brightness: 1,
            alpha: a
        )
    }

    static func hueShift(
        _ color: UIColor,
        degrees: CGFloat
    ) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        guard color.getHue(
            &h,
            saturation: &s,
            brightness: &b,
            alpha: &a
        ) else {
            return color
        }
        let shifted = (h + degrees / 360)
            .truncatingRemainder(dividingBy: 1)
        return UIColor(
            hue: shifted < 0 ? shifted + 1 : shifted,
            saturation: max(s, 0.85),
            brightness: 1,
            alpha: a
        )
    }

    static func normalizedPosition(
        _ point: CGPoint
    ) -> (Float, Float) {
        (Float(point.x * 2 - 1), Float(1 - point.y * 2))
    }
}

extension Float {
    func metalClamped(
        _ lower: Float = 0,
        _ upper: Float = 1
    ) -> Float {
        min(max(self, lower), upper)
    }
}
