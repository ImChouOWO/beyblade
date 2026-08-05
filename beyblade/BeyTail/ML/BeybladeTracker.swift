import CoreGraphics
import UIKit

final class BeybladeTracker {

    private struct Track {
        let id: Int
        var center: CGPoint
        var width: CGFloat
        var height: CGFloat
        var velocity: CGPoint
        var confidence: Float
        var smoothColor: UIColor
        var missedFrames: Int
        var confirmedFrames: Int
        var lastUpdateTime: TimeInterval
        var fps: Float
        var hardware: BeyTailInferenceHardware

        func predictedCenter(
            at now: TimeInterval,
            maximumPredictionTime: TimeInterval
        ) -> CGPoint {
            let elapsed = min(
                max(now - lastUpdateTime, 0),
                maximumPredictionTime
            )

            return CGPoint(
                x: center.x + velocity.x * elapsed,
                y: center.y + velocity.y * elapsed
            )
        }
    }

    private var tracks: [Track] = []
    private var nextId = 1

    /// 場景中的陀螺最多為 5 顆，避免誤判持續建立新軌跡。
    private let maxTrackCount = 5

    /// 軌跡最多保留的漏檢次數。
    private let maxMissedFrames = 30

    /// 僅在前三次短暫漏檢時輸出預測框，避免拖尾立即中斷。
    private let maxPredictionMissedFrames = 6

    /// 新物件必須連續匹配三次，才會正式輸出。
    /// 可降低高速模糊時偶發的第三個誤判框。
    private let confirmFrames = 3

    /// 新軌跡需要較高信心；已存在軌跡則可接受較弱偵測結果。
    private let newTrackConfidenceThreshold: Float = 0.45
    private let existingTrackConfidenceThreshold: Float = 0.15

    /// 高速移動時放寬配對距離，但仍限制最大範圍。
    private let baseMatchDistance: CGFloat = 0.22
    private let maximumMatchDistance: CGFloat = 0.58

    /// 速度採每秒 normalized 座標，避免推論間隔改變時預測距離失真。
    private let velocitySmoothAlpha: CGFloat = 0.52
    private let colorSmoothAlpha: CGFloat = 0.15
    private let maximumPredictionTime: TimeInterval = 0.32

    // MARK: - Public API

    func update(_ detections: [DetectionResult]) -> [DetectionResult] {
        let now = CACurrentMediaTime()
        let validDetections = sanitizeDetections(detections)

        guard !validDetections.isEmpty else {
            markAllTracksMissed()

            let output = predictedResults(
                forTrackIndices: Set(tracks.indices),
                now: now
            )

            removeDeadTracks()
            return output
        }

        if tracks.isEmpty {
            return createInitialTracks(
                from: validDetections,
                now: now
            )
        }

        let trackCount = tracks.count
        let detectionCount = validDetections.count

        let costMatrix = buildCostMatrix(
            tracks: tracks,
            detections: validDetections,
            now: now
        )

        let assignment = hungarian(
            costMatrix,
            trackCount,
            detectionCount
        )

        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()
        var output: [DetectionResult] = []

        for trackIndex in 0..<trackCount {
            guard trackIndex < assignment.count else {
                continue
            }

            let detectionIndex = assignment[trackIndex]

            guard detectionIndex >= 0,
                  detectionIndex < detectionCount else {
                continue
            }

            let track = tracks[trackIndex]
            let detection = validDetections[detectionIndex]

            guard detection.confidence >= existingTrackConfidenceThreshold else {
                continue
            }

            let predictedCenter = track.predictedCenter(
                at: now,
                maximumPredictionTime: maximumPredictionTime
            )

            let centerDistance = distance(
                predictedCenter,
                detection.center
            )

            guard centerDistance <= matchDistanceLimit(
                for: track,
                now: now
            ) else {
                continue
            }

            updateTrack(
                at: trackIndex,
                with: detection,
                now: now
            )

            matchedTracks.insert(trackIndex)
            matchedDetections.insert(detectionIndex)

            let updatedTrack = tracks[trackIndex]

            if updatedTrack.confirmedFrames >= confirmFrames {
                output.append(
                    makeDetectionResult(
                        from: detection,
                        track: updatedTrack
                    )
                )
            }
        }

        markUnmatchedTracksMissed(
            matchedTracks: matchedTracks
        )

        let unmatchedConfirmedTracks = Set(
            tracks.indices.filter {
                !matchedTracks.contains($0)
            }
        )

        output.append(
            contentsOf: predictedResults(
                forTrackIndices: unmatchedConfirmedTracks,
                now: now
            )
        )

        createTracksForUnmatchedDetections(
            detections: validDetections,
            matchedDetections: matchedDetections,
            now: now
        )

        removeDeadTracks()

        return output.sorted {
            $0.trackId < $1.trackId
        }
    }

    /// 離線影片未執行偵測的影格，可使用此方法延伸已確認軌跡。
    func predictStep() -> [DetectionResult] {
        let now = CACurrentMediaTime()

        return tracks.indices.compactMap { index in
            guard tracks[index].confirmedFrames >= confirmFrames,
                  tracks[index].missedFrames <= maxPredictionMissedFrames else {
                return nil
            }

            return makePredictedDetectionResult(
                track: tracks[index],
                now: now
            )
        }
    }

    func reset() {
        tracks.removeAll()
        nextId = 1
    }

    // MARK: - Detection Validation

    private func sanitizeDetections(
        _ detections: [DetectionResult]
    ) -> [DetectionResult] {
        detections
            .filter { detection in
                let rect = detection.boundingBox

                return detection.confidence >= existingTrackConfidenceThreshold &&
                    rect.minX.isFinite &&
                    rect.minY.isFinite &&
                    rect.width.isFinite &&
                    rect.height.isFinite &&
                    rect.width > 0.005 &&
                    rect.height > 0.005
            }
            .sorted {
                $0.confidence > $1.confidence
            }
    }

    // MARK: - Track Creation

    private func createInitialTracks(
        from detections: [DetectionResult],
        now: TimeInterval
    ) -> [DetectionResult] {
        var output: [DetectionResult] = []

        for detection in detections where
            detection.confidence >= newTrackConfidenceThreshold {
            guard tracks.count < maxTrackCount else {
                break
            }

            let track = makeTrack(
                from: detection,
                now: now
            )

            tracks.append(track)

            if track.confirmedFrames >= confirmFrames {
                output.append(
                    makeDetectionResult(
                        from: detection,
                        track: track
                    )
                )
            }
        }

        return output
    }

    private func createTracksForUnmatchedDetections(
        detections: [DetectionResult],
        matchedDetections: Set<Int>,
        now: TimeInterval
    ) {
        for detectionIndex in detections.indices {
            guard !matchedDetections.contains(detectionIndex) else {
                continue
            }

            let detection = detections[detectionIndex]

            guard detection.confidence >= newTrackConfidenceThreshold else {
                continue
            }

            guard tracks.count < maxTrackCount else {
                break
            }

            guard !isDuplicateOfExistingTrack(
                detection,
                now: now
            ) else {
                continue
            }

            tracks.append(
                makeTrack(
                    from: detection,
                    now: now
                )
            )
        }
    }

    private func makeTrack(
        from detection: DetectionResult,
        now: TimeInterval
    ) -> Track {
        let id = nextId
        nextId += 1

        return Track(
            id: id,
            center: detection.center,
            width: detection.boundingBox.width,
            height: detection.boundingBox.height,
            velocity: .zero,
            confidence: detection.confidence,
            smoothColor: detection.dominantColor,
            missedFrames: 0,
            confirmedFrames: 1,
            lastUpdateTime: now,
            fps: detection.fps,
            hardware: detection.hardware
        )
    }

    private func isDuplicateOfExistingTrack(
        _ detection: DetectionResult,
        now: TimeInterval
    ) -> Bool {
        for track in tracks {
            let predicted = track.predictedCenter(
                at: now,
                maximumPredictionTime: maximumPredictionTime
            )

            let centerDistance = distance(
                predicted,
                detection.center
            )

            let sizeReference = max(
                min(track.width, track.height),
                0.02
            )

            if centerDistance < sizeReference * 0.35 {
                return true
            }
        }

        return false
    }

    // MARK: - Track Update

    private func updateTrack(
        at index: Int,
        with detection: DetectionResult,
        now: TimeInterval
    ) {
        guard tracks.indices.contains(index) else {
            return
        }

        let oldCenter = tracks[index].center
        let newCenter = detection.center

        let elapsed = min(
            max(now - tracks[index].lastUpdateTime, 1.0 / 120.0),
            0.50
        )

        let observedVelocity = CGPoint(
            x: (newCenter.x - oldCenter.x) / elapsed,
            y: (newCenter.y - oldCenter.y) / elapsed
        )

        let oldVelocity = tracks[index].velocity

        let newVelocity = CGPoint(
            x: oldVelocity.x * (1.0 - velocitySmoothAlpha) +
                observedVelocity.x * velocitySmoothAlpha,
            y: oldVelocity.y * (1.0 - velocitySmoothAlpha) +
                observedVelocity.y * velocitySmoothAlpha
        )

        let blendedColor = blendColor(
            tracks[index].smoothColor,
            detection.dominantColor,
            t: colorSmoothAlpha
        )

        tracks[index].center = newCenter
        tracks[index].width = detection.boundingBox.width
        tracks[index].height = detection.boundingBox.height
        tracks[index].velocity = newVelocity
        tracks[index].confidence = detection.confidence
        tracks[index].smoothColor = blendedColor
        tracks[index].missedFrames = 0
        tracks[index].confirmedFrames += 1
        tracks[index].lastUpdateTime = now
        tracks[index].fps = detection.fps
        tracks[index].hardware = detection.hardware
    }

    private func markAllTracksMissed() {
        for index in tracks.indices {
            tracks[index].missedFrames += 1
        }
    }

    private func markUnmatchedTracksMissed(
        matchedTracks: Set<Int>
    ) {
        for index in tracks.indices where
            !matchedTracks.contains(index) {
            tracks[index].missedFrames += 1
        }
    }

    private func removeDeadTracks() {
        tracks.removeAll {
            $0.missedFrames > maxMissedFrames
        }
    }

    // MARK: - Prediction Output

    private func predictedResults(
        forTrackIndices indices: Set<Int>,
        now: TimeInterval
    ) -> [DetectionResult] {
        indices.compactMap { index in
            guard tracks.indices.contains(index),
                  tracks[index].confirmedFrames >= confirmFrames,
                  tracks[index].missedFrames > 0,
                  tracks[index].missedFrames <= maxPredictionMissedFrames else {
                return nil
            }

            return makePredictedDetectionResult(
                track: tracks[index],
                now: now
            )
        }
    }

    private func makePredictedDetectionResult(
        track: Track,
        now: TimeInterval
    ) -> DetectionResult {
        let predicted = clampNormalizedPoint(
            track.predictedCenter(
                at: now,
                maximumPredictionTime: maximumPredictionTime
            )
        )

        let box = clampNormalizedRect(
            CGRect(
                x: predicted.x - track.width / 2.0,
                y: predicted.y - track.height / 2.0,
                width: track.width,
                height: track.height
            )
        )

        let decay = pow(
            0.82,
            Float(max(track.missedFrames, 0))
        )

        return DetectionResult(
            boundingBox: box,
            confidence: max(track.confidence * decay, 0.01),
            fps: track.fps,
            hardware: track.hardware,
            trackId: track.id,
            dominantColor: track.smoothColor
        )
    }

    // MARK: - Cost Matrix

    private func buildCostMatrix(
        tracks: [Track],
        detections: [DetectionResult],
        now: TimeInterval
    ) -> [[Float]] {
        var matrix = Array(
            repeating: Array(
                repeating: Float.infinity,
                count: detections.count
            ),
            count: tracks.count
        )

        for trackIndex in tracks.indices {
            for detectionIndex in detections.indices {
                let track = tracks[trackIndex]
                let detection = detections[detectionIndex]

                let predicted = track.predictedCenter(
                    at: now,
                    maximumPredictionTime: maximumPredictionTime
                )

                let dist = distance(
                    predicted,
                    detection.center
                )

                guard dist <= matchDistanceLimit(
                    for: track,
                    now: now
                ) else {
                    continue
                }

                let sizeScore = calculateSizeScore(
                    track: track,
                    detection: detection
                )

                let motionScore = calculateMotionScore(
                    track: track,
                    detection: detection,
                    now: now
                )

                let confidenceScore = max(
                    detection.confidence,
                    0.10
                )

                let denominator = max(
                    sizeScore * motionScore * confidenceScore,
                    0.0001
                )

                matrix[trackIndex][detectionIndex] =
                    Float(dist) / denominator
            }
        }

        return matrix
    }

    private func matchDistanceLimit(
        for track: Track,
        now: TimeInterval
    ) -> CGFloat {
        let elapsed = min(
            max(now - track.lastUpdateTime, 0),
            maximumPredictionTime
        )

        let speed = sqrt(
            track.velocity.x * track.velocity.x +
            track.velocity.y * track.velocity.y
        )

        let missedAllowance =
            CGFloat(track.missedFrames) * 0.035

        return min(
            baseMatchDistance +
                speed * elapsed * 0.80 +
                missedAllowance,
            maximumMatchDistance
        )
    }

    private func calculateSizeScore(
        track: Track,
        detection: DetectionResult
    ) -> Float {
        let trackArea = max(
            track.width * track.height,
            0.0001
        )

        let detectionArea = max(
            detection.boundingBox.width *
                detection.boundingBox.height,
            0.0001
        )

        let areaRatio = detectionArea / trackArea
        let ratioError = abs(log(max(Float(areaRatio), 0.0001)))
        let score = exp(-1.25 * ratioError)

        return score.clamped(to: 0.05...1.0)
    }

    private func calculateMotionScore(
        track: Track,
        detection: DetectionResult,
        now: TimeInterval
    ) -> Float {
        let predicted = track.predictedCenter(
            at: now,
            maximumPredictionTime: maximumPredictionTime
        )

        let predictionError = distance(
            predicted,
            detection.center
        )

        let score = exp(-3.5 * Float(predictionError))

        return score.clamped(to: 0.05...1.0)
    }

    // MARK: - Result Builder

    private func makeDetectionResult(
        from detection: DetectionResult,
        track: Track
    ) -> DetectionResult {
        DetectionResult(
            boundingBox: detection.boundingBox,
            confidence: detection.confidence,
            fps: detection.fps,
            hardware: detection.hardware,
            trackId: track.id,
            dominantColor: track.smoothColor
        )
    }

    // MARK: - Helpers

    private func distance(
        _ a: CGPoint,
        _ b: CGPoint
    ) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y

        return sqrt(dx * dx + dy * dy)
    }

    private func clampNormalizedPoint(
        _ point: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )
    }

    private func clampNormalizedRect(
        _ rect: CGRect
    ) -> CGRect {
        let minX = min(max(rect.minX, 0.0), 1.0)
        let minY = min(max(rect.minY, 0.0), 1.0)
        let maxX = min(max(rect.maxX, 0.0), 1.0)
        let maxY = min(max(rect.maxY, 0.0), 1.0)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0, maxX - minX),
            height: max(0.0, maxY - minY)
        )
    }

    private func blendColor(
        _ first: UIColor,
        _ second: UIColor,
        t: CGFloat
    ) -> UIColor {
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0

        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0

        guard first.getRed(
            &r1,
            green: &g1,
            blue: &b1,
            alpha: &a1
        ), second.getRed(
            &r2,
            green: &g2,
            blue: &b2,
            alpha: &a2
        ) else {
            return second
        }

        return UIColor(
            red: r1 * (1.0 - t) + r2 * t,
            green: g1 * (1.0 - t) + g2 * t,
            blue: b1 * (1.0 - t) + b2 * t,
            alpha: a1 * (1.0 - t) + a2 * t
        )
    }

    // MARK: - Hungarian Assignment

    private func hungarian(
        _ cost: [[Float]],
        _ numRows: Int,
        _ numCols: Int
    ) -> [Int] {
        guard numRows > 0,
              numCols > 0 else {
            return Array(
                repeating: -1,
                count: numRows
            )
        }

        let size = max(numRows, numCols)
        let largeCost: Float = 1_000_000

        var squareCost = Array(
            repeating: Array(
                repeating: largeCost,
                count: size
            ),
            count: size
        )

        for row in 0..<numRows {
            for col in 0..<numCols {
                let value = cost[row][col]
                squareCost[row][col] =
                    value.isFinite ? value : largeCost
            }
        }

        var u = Array(
            repeating: Float(0),
            count: size + 1
        )
        var v = Array(
            repeating: Float(0),
            count: size + 1
        )
        var p = Array(
            repeating: 0,
            count: size + 1
        )
        var way = Array(
            repeating: 0,
            count: size + 1
        )

        for i in 1...size {
            p[0] = i
            var j0 = 0
            var minv = Array(
                repeating: Float.infinity,
                count: size + 1
            )
            var used = Array(
                repeating: false,
                count: size + 1
            )

            repeat {
                used[j0] = true

                let i0 = p[j0]
                var delta = Float.infinity
                var j1 = 0

                for j in 1...size where !used[j] {
                    let currentCost = squareCost[i0 - 1][j - 1]
                    let current = currentCost - u[i0] - v[j]

                    if current < minv[j] {
                        minv[j] = current
                        way[j] = j0
                    }

                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }

                for j in 0...size {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }

                j0 = j1

            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignment = Array(
            repeating: -1,
            count: numRows
        )

        for j in 1...size {
            let i = p[j]

            guard i >= 1,
                  i <= numRows,
                  j <= numCols else {
                continue
            }

            let row = i - 1
            let col = j - 1

            if squareCost[row][col] < largeCost {
                assignment[row] = col
            }
        }

        return assignment
    }
}
