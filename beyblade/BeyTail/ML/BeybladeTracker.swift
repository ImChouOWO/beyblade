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

        var predictedCenter: CGPoint {
            CGPoint(
                x: center.x + velocity.x,
                y: center.y + velocity.y
            )
        }
    }

    private var tracks: [Track] = []
    private var nextId = 1

    private let maxMissedFrames = 8
    private let confirmFrames = 2
    private let maxMatchDistance: CGFloat = 0.35

    private let velocitySmoothAlpha: CGFloat = 0.30
    private let colorSmoothAlpha: CGFloat = 0.15

    // MARK: - Public API

    func update(_ detections: [DetectionResult]) -> [DetectionResult] {
        let now = CACurrentMediaTime()

        guard !detections.isEmpty else {
            markAllTracksMissed()
            removeDeadTracks()
            return []
        }

        if tracks.isEmpty {
            return createInitialTracks(
                from: detections,
                now: now
            )
        }

        let trackCount = tracks.count
        let detectionCount = detections.count

        let costMatrix = buildCostMatrix(
            tracks: tracks,
            detections: detections
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
            let detection = detections[detectionIndex]

            let centerDistance = distance(
                track.predictedCenter,
                detection.center
            )

            guard centerDistance <= maxMatchDistance else {
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

        removeDeadTracks()

        createTracksForUnmatchedDetections(
            detections: detections,
            matchedDetections: matchedDetections,
            now: now
        )

        return output
    }

    func predictStep() -> [DetectionResult] {
        var output: [DetectionResult] = []

        for index in tracks.indices {
            guard tracks[index].confirmedFrames >= confirmFrames,
                  tracks[index].missedFrames == 0 else {
                continue
            }

            let predicted = tracks[index].predictedCenter

            tracks[index].center = predicted

            let width = tracks[index].width
            let height = tracks[index].height

            let box = CGRect(
                x: predicted.x - width / 2.0,
                y: predicted.y - height / 2.0,
                width: width,
                height: height
            )

            let result = DetectionResult(
                boundingBox: box,
                confidence: tracks[index].confidence,
                fps: 0,
                hardware: BeyTailInferenceHardware.cpu,
                trackId: tracks[index].id,
                dominantColor: tracks[index].smoothColor
            )

            output.append(result)
        }

        return output
    }

    func reset() {
        tracks.removeAll()
        nextId = 1
    }

    // MARK: - Track Creation

    private func createInitialTracks(
        from detections: [DetectionResult],
        now: TimeInterval
    ) -> [DetectionResult] {
        var output: [DetectionResult] = []

        for detection in detections {
            let id = nextId
            nextId += 1

            let track = Track(
                id: id,
                center: detection.center,
                width: detection.boundingBox.width,
                height: detection.boundingBox.height,
                velocity: .zero,
                confidence: detection.confidence,
                smoothColor: detection.dominantColor,
                missedFrames: 0,
                confirmedFrames: 1,
                lastUpdateTime: now
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

            let id = nextId
            nextId += 1

            let track = Track(
                id: id,
                center: detection.center,
                width: detection.boundingBox.width,
                height: detection.boundingBox.height,
                velocity: .zero,
                confidence: detection.confidence,
                smoothColor: detection.dominantColor,
                missedFrames: 0,
                confirmedFrames: 1,
                lastUpdateTime: now
            )

            tracks.append(track)
        }
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

        let dx = newCenter.x - oldCenter.x
        let dy = newCenter.y - oldCenter.y

        let oldVelocity = tracks[index].velocity

        let newVelocity = CGPoint(
            x: oldVelocity.x * (1.0 - velocitySmoothAlpha) + dx * velocitySmoothAlpha,
            y: oldVelocity.y * (1.0 - velocitySmoothAlpha) + dy * velocitySmoothAlpha
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
    }

    private func markAllTracksMissed() {
        for index in tracks.indices {
            tracks[index].missedFrames += 1
        }
    }

    private func markUnmatchedTracksMissed(
        matchedTracks: Set<Int>
    ) {
        for index in tracks.indices {
            if !matchedTracks.contains(index) {
                tracks[index].missedFrames += 1
            }
        }
    }

    private func removeDeadTracks() {
        tracks.removeAll {
            $0.missedFrames > maxMissedFrames
        }
    }

    // MARK: - Cost Matrix

    private func buildCostMatrix(
        tracks: [Track],
        detections: [DetectionResult]
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

                let dist = distance(
                    track.predictedCenter,
                    detection.center
                )

                guard dist <= maxMatchDistance else {
                    continue
                }

                let sizeScore = calculateSizeScore(
                    track: track,
                    detection: detection
                )

                let velocityScore = calculateVelocityScore(
                    track: track,
                    detection: detection
                )

                let denominator = max(
                    sizeScore * velocityScore,
                    0.0001
                )

                let cost = Float(dist) / denominator

                matrix[trackIndex][detectionIndex] = cost
            }
        }

        return matrix
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
            detection.boundingBox.width * detection.boundingBox.height,
            0.0001
        )

        let areaRatio = detectionArea / trackArea
        let ratioError = abs(Float(areaRatio) - 1.0)

        let score = exp(-3.0 * ratioError)

        return score.clamped(to: 0.01...1.0)
    }

    private func calculateVelocityScore(
        track: Track,
        detection: DetectionResult
    ) -> Float {
        let observedVelocity = CGPoint(
            x: detection.center.x - track.center.x,
            y: detection.center.y - track.center.y
        )

        let velocityError = distance(
            observedVelocity,
            track.velocity
        )

        let score = exp(-8.0 * Float(velocityError))

        return score.clamped(to: 0.01...1.0)
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

        first.getRed(
            &r1,
            green: &g1,
            blue: &b1,
            alpha: &a1
        )

        second.getRed(
            &r2,
            green: &g2,
            blue: &b2,
            alpha: &a2
        )

        let red = r1 * (1.0 - t) + r2 * t
        let green = g1 * (1.0 - t) + g2 * t
        let blue = b1 * (1.0 - t) + b2 * t
        let alpha = a1 * (1.0 - t) + a2 * t

        return UIColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
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

                if value.isFinite {
                    squareCost[row][col] = value
                } else {
                    squareCost[row][col] = largeCost
                }
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
            let assignedCost = squareCost[row][col]

            if assignedCost < largeCost {
                assignment[row] = col
            }
        }

        return assignment
    }
}