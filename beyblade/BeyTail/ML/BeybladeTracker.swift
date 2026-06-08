import CoreGraphics
import UIKit

// 對應 Android BeybladeTracker.kt
// Hungarian + Kalman velocity 多目標追蹤
class BeybladeTracker {

    private struct Track {
        let id: Int
        var center: CGPoint
        var width: CGFloat
        var velocity: CGPoint = .zero
        var confidence: Float
        var smoothColor: UIColor = .white
        var missedFrames: Int = 0
        var confirmedFrames: Int = 0

        var predictedCenter: CGPoint {
            CGPoint(x: center.x + velocity.x, y: center.y + velocity.y)
        }
    }

    private var tracks: [Track] = []
    private var nextId = 1
    private let maxMissedFrames = 8
    private let confirmFrames = 2
    private let maxMatchDistance: CGFloat = 0.35

    func update(_ detections: [DetectionResult]) -> [DetectionResult] {
        guard !detections.isEmpty else {
            for i in tracks.indices { tracks[i].missedFrames += 1 }
            tracks.removeAll { $0.missedFrames > maxMissedFrames }
            return []
        }

        if tracks.isEmpty {
            return detections.map { det in
                let id = nextId; nextId += 1
                tracks.append(Track(id: id, center: det.center, width: det.boundingBox.width,
                                    confidence: det.confidence, smoothColor: det.dominantColor,
                                    confirmedFrames: 1))
                return DetectionResult(boundingBox: det.boundingBox, confidence: det.confidence,
                                       fps: det.fps, hardware: det.hardware,
                                       trackId: confirmedFrames(for: id) >= confirmFrames ? id : 0,
                                       dominantColor: det.dominantColor)
            }.filter { $0.trackId != 0 }
        }

        let n = tracks.count
        let m = detections.count

        // Build cost matrix
        var costMatrix = Array(repeating: Array(repeating: Float.infinity, count: m), count: n)
        for i in 0 ..< n {
            for j in 0 ..< m {
                let dist = distance(tracks[i].predictedCenter, detections[j].center)
                guard dist <= maxMatchDistance else { continue }
                let ratio = tracks[i].width > 0 ? Float(detections[j].boundingBox.width / tracks[i].width) : 1
                let sizeScore = exp(-3 * abs(ratio - 1)).clamped(to: 0.01...1)
                let velErr = Float(distance(
                    CGPoint(x: detections[j].center.x - tracks[i].center.x,
                            y: detections[j].center.y - tracks[i].center.y),
                    CGPoint(x: tracks[i].velocity.x, y: tracks[i].velocity.y)
                ))
                let velocityScore = exp(-8 * velErr).clamped(to: 0.01...1)
                costMatrix[i][j] = Float(dist) / (sizeScore * velocityScore)
            }
        }

        let assignment = hungarian(costMatrix, n, m)

        var matchedTrack = Set<Int>()
        var matchedDet   = Set<Int>()
        var result: [DetectionResult] = []

        for i in 0 ..< n {
            let j = assignment[i]
            guard j >= 0 else { continue }
            guard distance(tracks[i].predictedCenter, detections[j].center) <= maxMatchDistance else { continue }

            let det = detections[j]
            let newCenter = det.center

            tracks[i].velocity = CGPoint(
                x: 0.7 * tracks[i].velocity.x + 0.3 * (newCenter.x - tracks[i].center.x),
                y: 0.7 * tracks[i].velocity.y + 0.3 * (newCenter.y - tracks[i].center.y)
            )
            tracks[i].center        = newCenter
            tracks[i].width         = det.boundingBox.width
            tracks[i].confidence    = det.confidence
            tracks[i].smoothColor   = blendColor(tracks[i].smoothColor, det.dominantColor, t: 0.15)
            tracks[i].missedFrames  = 0
            tracks[i].confirmedFrames += 1

            matchedTrack.insert(i)
            matchedDet.insert(j)

            if tracks[i].confirmedFrames >= confirmFrames {
                result.append(DetectionResult(
                    boundingBox: det.boundingBox, confidence: det.confidence,
                    fps: det.fps, hardware: det.hardware,
                    trackId: tracks[i].id, dominantColor: tracks[i].smoothColor
                ))
            }
        }

        for i in 0 ..< n where !matchedTrack.contains(i) {
            tracks[i].missedFrames += 1
        }
        tracks.removeAll { $0.missedFrames > maxMissedFrames }

        for j in 0 ..< m where !matchedDet.contains(j) {
            let id = nextId; nextId += 1
            tracks.append(Track(id: id,
                                center: detections[j].center,
                                width: detections[j].boundingBox.width,
                                confidence: detections[j].confidence,
                                smoothColor: detections[j].dominantColor,
                                confirmedFrames: 1))
        }

        return result
    }

    func predictStep() -> [DetectionResult] {
        return tracks
            .filter { $0.confirmedFrames >= confirmFrames && $0.missedFrames == 0 }
            .map { track in
                tracks[tracks.firstIndex(where: { $0.id == track.id })!].center = track.predictedCenter
                let hw = track.width / 2
                return DetectionResult(
                    boundingBox: CGRect(x: track.predictedCenter.x - hw, y: track.predictedCenter.y - hw,
                                        width: track.width, height: track.width),
                    confidence: track.confidence, fps: 0, hardware: .cpu,
                    trackId: track.id, dominantColor: track.smoothColor
                )
            }
    }

    func reset() { tracks.removeAll(); nextId = 1 }

    // MARK: - Helpers

    private func confirmedFrames(for id: Int) -> Int {
        tracks.first { $0.id == id }?.confirmedFrames ?? 0
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return sqrt(dx*dx + dy*dy)
    }

    private func blendColor(_ c1: UIColor, _ c2: UIColor, t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: nil)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
        return UIColor(red: r1*(1-t)+r2*t, green: g1*(1-t)+g2*t, blue: b1*(1-t)+b2*t, alpha: 1)
    }

    // Hungarian O(n³) — 對應 Android BeybladeTracker.hungarian()
    private func hungarian(_ cost: [[Float]], _ numRows: Int, _ numCols: Int) -> [Int] {
        let n = max(numRows, numCols)
        var c = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        for i in 0..<numRows { for j in 0..<numCols { c[i][j] = cost[i][j] } }

        var u = Array(repeating: Float(0), count: n+1)
        var v = Array(repeating: Float(0), count: n+1)
        var p = Array(repeating: 0, count: n+1)
        var way = Array(repeating: 0, count: n+1)

        for i in 1...n {
            p[0] = i; var j0 = 0
            var minv = Array(repeating: Float.infinity, count: n+1)
            var used = Array(repeating: false, count: n+1)
            repeat {
                used[j0] = true
                let i0 = p[j0]; var delta = Float.infinity; var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = c[i0-1][j-1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }

        var result = Array(repeating: -1, count: numRows)
        for j in 1...n { let i = p[j]; if i >= 1 && i <= numRows && j <= numCols { result[i-1] = j-1 } }
        return result
    }
}
