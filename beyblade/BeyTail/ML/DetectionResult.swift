import CoreGraphics
import UIKit

enum BeyTailInferenceHardware {
    case cpu
    case gpu
    case npu
    case mock

    var label: String {
        switch self {
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .npu:
            return "NPU"
        case .mock:
            return "MOCK"
        }
    }
}

struct DetectionResult: @unchecked Sendable {
    let boundingBox: CGRect
    let confidence: Float
    let fps: Float
    let hardware: BeyTailInferenceHardware
    let trackId: Int
    let dominantColor: UIColor

    var center: CGPoint {
        CGPoint(
            x: boundingBox.midX,
            y: boundingBox.midY
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0

        self.init(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}