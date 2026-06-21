import Foundation
import simd

/// 軌跡點儲存與淡出計算（對應 Android TrailEffectEngine）。
/// 即時相機用 CACurrentMediaTime()；離線影片處理傳入影片 PTS。
final class TrailEffectEngine {
    var fadeDuration: TimeInterval
    private let maxPoints: Int
    private var points: [TrailPoint] = []
    private let lock = NSLock()

    init(fadeDuration: TimeInterval = 0.5, maxPoints: Int = 120) {
        self.fadeDuration = fadeDuration
        self.maxPoints = maxPoints
    }

    func addPoint(trackId: Int, center: SIMD2<Float>, color: SIMD3<Float>,
                  timestamp: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        points.append(TrailPoint(center: center, timestamp: timestamp,
                                 trackId: trackId, color: color))
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
    }

    /// 各 track 依時間排序的點列（舊→新）+ 存活度 alpha（1 = 剛加入）。
    func pointsByTrack(now: TimeInterval) -> [Int: [(TrailPoint, Float)]] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now - fadeDuration
        points.removeAll { $0.timestamp < cutoff }
        var result: [Int: [(TrailPoint, Float)]] = [:]
        for p in points {
            let alpha = Float(max(0, min(1, 1 - (now - p.timestamp) / fadeDuration)))
            result[p.trackId, default: []].append((p, alpha))
        }
        return result
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        points.removeAll()
    }
}
