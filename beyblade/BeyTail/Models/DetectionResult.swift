import CoreGraphics
import UIKit

struct DetectionResult {
    let boundingBox: CGRect      // normalized 0..1
    let confidence: Float
    let fps: Float
    let hardware: InferenceHardware
    let trackId: Int
    let dominantColor: UIColor

    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    init(boundingBox: CGRect, confidence: Float, fps: Float,
         hardware: InferenceHardware, trackId: Int = 0,
         dominantColor: UIColor = .white) {
        self.boundingBox   = boundingBox
        self.confidence    = confidence
        self.fps           = fps
        self.hardware      = hardware
        self.trackId       = trackId
        self.dominantColor = dominantColor
    }
}
