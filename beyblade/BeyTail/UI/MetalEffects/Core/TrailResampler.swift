import CoreGraphics
import UIKit

/// Reconstructs a denser centerline when model inference runs slower than the
/// 30 Hz effect renderer. This keeps the Metal geometry close to the Android
/// GLSurfaceView output instead of producing long, angular segments.
enum TrailResampler {
    static func resample(
        _ tracks: MetalTrackData,
        drawableSize: CGSize,
        spacingPixels: CGFloat = 5,
        maximumSamplesPerTrack: Int = 256
    ) -> MetalTrackData {
        guard drawableSize.width > 1,
              drawableSize.height > 1,
              spacingPixels > 0 else {
            return tracks
        }

        var result: MetalTrackData = [:]
        result.reserveCapacity(tracks.count)

        for (trackID, samples) in tracks {
            guard samples.count >= 2 else {
                result[trackID] = samples
                continue
            }

            var output: [MetalTrailSample] = []
            output.reserveCapacity(
                min(samples.count * 3, maximumSamplesPerTrack)
            )
            output.append(samples[0])

            for index in 1..<samples.count {
                let previous = samples[index - 1]
                let current = samples[index]
                let dx = (current.first.center.x - previous.first.center.x) *
                    drawableSize.width
                let dy = (current.first.center.y - previous.first.center.y) *
                    drawableSize.height
                let distance = hypot(dx, dy)
                let steps = max(Int(ceil(distance / spacingPixels)), 1)

                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let center = CGPoint(
                        x: previous.first.center.x +
                            (current.first.center.x - previous.first.center.x) * t,
                        y: previous.first.center.y +
                            (current.first.center.y - previous.first.center.y) * t
                    )
                    let timestamp = previous.first.timestamp +
                        (current.first.timestamp - previous.first.timestamp) *
                        Double(t)
                    let alpha = previous.second +
                        (current.second - previous.second) * Float(t)

                    output.append((
                        first: TrailPoint(
                            center: center,
                            timestamp: timestamp,
                            trackId: current.first.trackId,
                            color: blendColor(
                                previous.first.color,
                                current.first.color,
                                t: t
                            )
                        ),
                        second: alpha
                    ))

                    if output.count >= maximumSamplesPerTrack {
                        break
                    }
                }

                if output.count >= maximumSamplesPerTrack {
                    break
                }
            }

            result[trackID] = output
        }

        return result
    }

    private static func blendColor(
        _ lhs: UIColor,
        _ rhs: UIColor,
        t: CGFloat
    ) -> UIColor {
        let l = MetalHelper.rgba(lhs)
        let r = MetalHelper.rgba(rhs)
        let u = Float(t)
        return UIColor(
            red: CGFloat(l.0 + (r.0 - l.0) * u),
            green: CGFloat(l.1 + (r.1 - l.1) * u),
            blue: CGFloat(l.2 + (r.2 - l.2) * u),
            alpha: CGFloat(l.3 + (r.3 - l.3) * u)
        )
    }
}
