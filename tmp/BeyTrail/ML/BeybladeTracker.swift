import Foundation
import simd

/// 多目標追蹤器 — 對應 Android BeybladeTracker：
/// 匈牙利演算法指派 + 尺寸/速度 re-ID 加權 + EMA 平滑 + Kalman 預測補幀。
final class BeybladeTracker {
    private let maxMissedFrames: Int
    private let confirmFrames: Int
    private let maxMatchDistance: Float

    private final class Track {
        let id: Int
        var center: SIMD2<Float>
        var width: Float
        var velocity = SIMD2<Float>(0, 0)
        var confidence: Float
        var smoothColor: SIMD3<Float>
        var missedFrames = 0
        var confirmedFrames = 0

        init(id: Int, center: SIMD2<Float>, width: Float,
             confidence: Float, color: SIMD3<Float>) {
            self.id = id; self.center = center; self.width = width
            self.confidence = confidence; self.smoothColor = color
        }
        var predictedCenter: SIMD2<Float> { center + velocity }
    }

    private var tracks: [Track] = []
    private var nextId = 1

    init(maxMissedFrames: Int = 8, confirmFrames: Int = 2, maxMatchDistance: Float = 0.35) {
        self.maxMissedFrames = maxMissedFrames
        self.confirmFrames = confirmFrames
        self.maxMatchDistance = maxMatchDistance
    }

    func update(_ detections: [DetectionResult]) -> [DetectionResult] {
        if detections.isEmpty {
            tracks.forEach { $0.missedFrames += 1 }
            tracks.removeAll { $0.missedFrames > maxMissedFrames }
            return []
        }

        if tracks.isEmpty {
            return detections.compactMap { det in
                let id = nextId; nextId += 1
                let t = Track(id: id, center: det.center, width: det.width,
                              confidence: det.confidence, color: det.dominantColor)
                t.confirmedFrames = 1
                tracks.append(t)
                if 1 >= confirmFrames {
                    var r = det; r.trackId = id; return r
                }
                return nil
            }
        }

        let n = tracks.count
        let m = detections.count

        // cost[i][j] = 距離 / (尺寸分 × 速度分)
        var cost = [[Float]](repeating: [Float](repeating: 0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                let predicted = tracks[i].predictedCenter
                let det = detections[j]
                let dist = simd_distance(predicted, det.center)
                if dist > maxMatchDistance {
                    cost[i][j] = Float.greatestFiniteMagnitude / 2
                } else {
                    let ratio = tracks[i].width > 0 ? det.width / tracks[i].width : 1
                    let sizeScore = max(0.01, exp(-3 * abs(ratio - 1)))
                    let actual = det.center - tracks[i].center
                    let velErr = simd_distance(actual, tracks[i].velocity)
                    let velocityScore = max(0.01, exp(-8 * velErr))
                    cost[i][j] = dist / (sizeScore * velocityScore)
                }
            }
        }

        let assignment = hungarian(cost: cost, rows: n, cols: m)
        var matchedTrack = Set<Int>()
        var matchedDet = Set<Int>()
        var result: [DetectionResult] = []

        for i in 0..<n {
            let j = assignment[i]
            if j < 0 { continue }
            let dist = simd_distance(tracks[i].predictedCenter, detections[j].center)
            if dist > maxMatchDistance { continue }

            let track = tracks[i]
            let det = detections[j]
            let newCenter = det.center
            track.velocity = 0.7 * track.velocity + 0.3 * (newCenter - track.center)
            track.center = newCenter
            track.width = det.width
            track.confidence = det.confidence
            // 顏色 EMA（同 Android 係數 0.2）
            track.smoothColor = track.smoothColor * 0.8 + det.dominantColor * 0.2
            track.missedFrames = 0
            track.confirmedFrames += 1
            matchedTrack.insert(i)
            matchedDet.insert(j)

            if track.confirmedFrames >= confirmFrames {
                var r = det
                r.trackId = track.id
                r.dominantColor = track.smoothColor
                result.append(r)
            }
        }

        for i in 0..<n where !matchedTrack.contains(i) {
            tracks[i].missedFrames += 1
        }
        tracks.removeAll { $0.missedFrames > maxMissedFrames }

        for j in 0..<m where !matchedDet.contains(j) {
            let det = detections[j]
            let t = Track(id: nextId, center: det.center, width: det.width,
                          confidence: det.confidence, color: det.dominantColor)
            nextId += 1
            t.confirmedFrames = 1
            tracks.append(t)
        }

        return result
    }

    /// Kalman 預測步：YOLO 跳過的幀以速度外插（stepScale 同 Android）。
    func predictStep(stepScale: Float = 1) -> [DetectionResult] {
        return tracks
            .filter { $0.confirmedFrames >= confirmFrames && $0.missedFrames == 0 }
            .map { track in
                track.center = simd_clamp(
                    track.center + track.velocity * stepScale,
                    SIMD2(0, 0), SIMD2(1, 1))
                let hw = track.width / 2
                return DetectionResult(
                    boundingBox: SIMD4(track.center.x - hw, track.center.y - hw,
                                       track.width, track.width),
                    confidence: track.confidence,
                    trackId: track.id,
                    dominantColor: track.smoothColor)
            }
    }

    func reset() {
        tracks.removeAll()
        nextId = 1
    }

    // ── 匈牙利演算法（Kuhn–Munkres O(n³)，補方陣） ──────────────────────
    private func hungarian(cost: [[Float]], rows: Int, cols: Int) -> [Int] {
        let n = max(rows, cols)
        let inf = Float.greatestFiniteMagnitude / 4
        var a = [[Float]](repeating: [Float](repeating: 0, count: n + 1), count: n + 1)
        for i in 1...n {
            for j in 1...n {
                a[i][j] = (i <= rows && j <= cols) ? cost[i - 1][j - 1] : inf
            }
        }
        var u = [Float](repeating: 0, count: n + 1)
        var v = [Float](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)
        var way = [Int](repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Float](repeating: inf, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = inf
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = a[i0][j] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta }
                    else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignment = [Int](repeating: -1, count: rows)
        for j in 1...n {
            let i = p[j]
            if i >= 1 && i <= rows && j <= cols {
                assignment[i - 1] = j - 1
            }
        }
        return assignment
    }
}
