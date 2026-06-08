import CoreGraphics
import UIKit

struct TrailPoint {
    let center: CGPoint
    let timestamp: TimeInterval   // CACurrentMediaTime()
    let trackId: Int
    let color: UIColor
}
