import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UIKit

/// Extracts a stable, saturated representative color from the center of a
/// normalized detection rectangle.
///
/// The input rectangle uses the project's convention: normalized coordinates,
/// origin at the upper-left. The image is first oriented with the same
/// CGImagePropertyOrientation used by Vision, then converted to Core Image's
/// lower-left coordinate system.
final class DominantColorExtractor {
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let sampleWidth = 32
    private let sampleHeight = 32
    private let hueBinCount = 36

    init() {
        context = CIContext(options: [
            .cacheIntermediates: false
        ])
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    func extract(
        from pixelBuffer: CVPixelBuffer,
        normalizedRect: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> UIColor? {
        let rect = normalizedRect.standardized
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard rect.width > 0.002,
              rect.height > 0.002 else {
            return nil
        }

        // Ignore the bbox edge because it usually contains arena/background.
        let insetRect = rect.insetBy(
            dx: rect.width * 0.18,
            dy: rect.height * 0.18
        )

        guard insetRect.width > 0.001,
              insetRect.height > 0.001 else {
            return nil
        }

        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(orientation)
        let extent = orientedImage.extent

        guard extent.width > 1,
              extent.height > 1 else {
            return nil
        }

        // Project normalized upper-left coordinates into Core Image's
        // lower-left image coordinates.
        let cropRect = CGRect(
            x: extent.minX + insetRect.minX * extent.width,
            y: extent.minY + (1.0 - insetRect.maxY) * extent.height,
            width: insetRect.width * extent.width,
            height: insetRect.height * extent.height
        ).intersection(extent)

        guard cropRect.width > 1,
              cropRect.height > 1 else {
            return nil
        }

        let cropped = orientedImage.cropped(to: cropRect)
        let translated = cropped.transformed(
            by: CGAffineTransform(
                translationX: -cropRect.minX,
                y: -cropRect.minY
            )
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / cropRect.width,
                y: CGFloat(sampleHeight) / cropRect.height
            )
        )

        var pixels = [UInt8](
            repeating: 0,
            count: sampleWidth * sampleHeight * 4
        )

        context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: sampleWidth * 4,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: sampleWidth,
                height: sampleHeight
            ),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return dominantColor(fromRGBA: pixels)
    }

    private func dominantColor(fromRGBA pixels: [UInt8]) -> UIColor? {
        var histogram = [Float](repeating: 0, count: hueBinCount)
        var samples: [ColorSample] = []
        samples.reserveCapacity(sampleWidth * sampleHeight)

        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let red = Float(pixels[offset]) / 255.0
                let green = Float(pixels[offset + 1]) / 255.0
                let blue = Float(pixels[offset + 2]) / 255.0
                let alpha = Float(pixels[offset + 3]) / 255.0

                guard alpha > 0.10 else {
                    continue
                }

                let hsv = rgbToHSV(red: red, green: green, blue: blue)

                // Reject gray highlights, black shadows and clipped whites.
                guard hsv.saturation >= 0.25,
                      hsv.value >= 0.12,
                      hsv.value <= 0.98 else {
                    continue
                }

                let nx = (Float(x) + 0.5) / Float(sampleWidth) - 0.5
                let ny = (Float(y) + 0.5) / Float(sampleHeight) - 0.5
                let centerDistance = min(sqrt(nx * nx + ny * ny) / 0.7071, 1)
                let centerWeight = 0.20 + 0.80 * (1.0 - centerDistance)
                let weight = hsv.saturation * hsv.saturation
                    * (0.45 + 0.55 * hsv.value)
                    * centerWeight

                let bin = min(
                    Int(hsv.hue * Float(hueBinCount)),
                    hueBinCount - 1
                )
                histogram[bin] += weight
                samples.append(
                    ColorSample(
                        red: red,
                        green: green,
                        blue: blue,
                        hueBin: bin,
                        weight: weight
                    )
                )
            }
        }

        guard let dominantBin = histogram.indices.max(
            by: { histogram[$0] < histogram[$1] }
        ), histogram[dominantBin] > 0 else {
            return nil
        }

        var redSum: Float = 0
        var greenSum: Float = 0
        var blueSum: Float = 0
        var weightSum: Float = 0

        for sample in samples {
            let distance = circularBinDistance(
                sample.hueBin,
                dominantBin,
                count: hueBinCount
            )

            guard distance <= 1 else {
                continue
            }

            redSum += sample.red * sample.weight
            greenSum += sample.green * sample.weight
            blueSum += sample.blue * sample.weight
            weightSum += sample.weight
        }

        guard weightSum > 0 else {
            return nil
        }

        let baseColor = UIColor(
            red: CGFloat(redSum / weightSum),
            green: CGFloat(greenSum / weightSum),
            blue: CGFloat(blueSum / weightSum),
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1

        guard baseColor.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            return baseColor
        }

        // Keep the detected hue, but prevent the trail from becoming gray or
        // too dark after camera exposure and RGB averaging.
        return UIColor(
            hue: hue,
            saturation: min(max(saturation, 0.68) * 1.08, 1.0),
            brightness: min(max(brightness, 0.72) * 1.04, 1.0),
            alpha: 1
        )
    }

    private func circularBinDistance(
        _ lhs: Int,
        _ rhs: Int,
        count: Int
    ) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, count - direct)
    }

    private func rgbToHSV(
        red: Float,
        green: Float,
        blue: Float
    ) -> (hue: Float, saturation: Float, value: Float) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        let saturation = maximum > 0 ? delta / maximum : 0
        var hue: Float = 0

        if delta > 0.000_01 {
            if maximum == red {
                hue = (green - blue) / delta
                if hue < 0 {
                    hue += 6
                }
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }

        return (hue, saturation, maximum)
    }

    private struct ColorSample {
        let red: Float
        let green: Float
        let blue: Float
        let hueBin: Int
        let weight: Float
    }
}
