import CoreGraphics
import UIKit

// 對應 Android TrailEffectEngine.kt
// 負責儲存軌跡點並計算淡出 alpha
class TrailEffectEngine {

    var fadeDurationMs: Int64 = 500
    private let maxPoints = 120
    private var points: [TrailPoint] = []
    private let lock = NSLock()

    func addPoint(trackId: Int, center: CGPoint, color: UIColor = .white) {
        lock.lock()
        defer { lock.unlock() }
        points.append(TrailPoint(center: center, timestamp: CACurrentMediaTime(),
                                 trackId: trackId, color: color))
        if points.count > maxPoints { points.removeFirst() }
    }

    // 回傳每個點及其當下 alpha（0=消失 1=最亮）
    func getVisiblePoints(now: TimeInterval) -> [(TrailPoint, Float)] {
        lock.lock()
        defer { lock.unlock() }
        let fadeSec = Double(fadeDurationMs) / 1000.0
        points.removeAll { now - $0.timestamp > fadeSec }
        return points.map { pt in
            let alpha = Float(1.0 - (now - pt.timestamp) / fadeSec).clamped(to: 0...1)
            return (pt, alpha)
        }
    }

    // 依 trackId 分組，回傳 [(point, alpha)]，oldest→newest
    func getPointsByTrack(now: TimeInterval) -> [Int: [(TrailPoint, Float)]] {
        lock.lock()
        defer { lock.unlock() }
        let fadeSec = Double(fadeDurationMs) / 1000.0
        points.removeAll { now - $0.timestamp > fadeSec }
        var result: [Int: [(TrailPoint, Float)]] = [:]
        for pt in points {
            let alpha = Float(1.0 - (now - pt.timestamp) / fadeSec).clamped(to: 0...1)
            result[pt.trackId, default: []].append((pt, alpha))
        }
        return result
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        points.removeAll()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
