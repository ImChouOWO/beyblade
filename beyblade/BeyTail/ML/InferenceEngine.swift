import CoreML
import Vision
import AVFoundation
import UIKit

// 對應 Android InferenceEngine.kt
// 有 CoreML 模型 → 真實推論
// 無模型 → frame-driven mock 模式
//
// 重要：
// 舊版 mock 使用 Timer 連續輸出結果，會造成影片結束後仍持續 inference。
// 這版改為只有 processFrame(...) 被呼叫時才產生 mock 結果。
final class InferenceEngine: @unchecked Sendable {

    let isMockMode: Bool

    private var model: VNCoreMLModel?

    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()
    private(set) var currentFps: Float = 0

    var onResult: (([DetectionResult]) -> Void)?

    // MARK: - Init

    init() {
        if let modelURL = Bundle.main.url(
            forResource: "beyblade_detector",
            withExtension: "mlmodelc"
        ),
           let mlModel = try? MLModel(contentsOf: modelURL),
           let vnModel = try? VNCoreMLModel(for: mlModel) {

            model = vnModel
            isMockMode = false
            print("[INFO] CoreML model loaded:", modelURL.lastPathComponent)

        } else {
            model = nil
            isMockMode = true
            print("[INFO] CoreML model not found. Use frame-driven MOCK mode.")
        }
    }

    // MARK: - Public API

    func start() {
        if isMockMode {
            print("[INFO] InferenceEngine mock mode enabled. No Timer is used.")
        }
    }

    func stop() {
        // Frame-driven mock 不需要 Timer，因此這裡不做額外工作。
        print("[INFO] InferenceEngine stop")
    }

    // 每幀從 CameraManager 或 VideoFrameSource 收到 CMSampleBuffer 後呼叫
    func processFrame(_ sampleBuffer: CMSampleBuffer) {
        if isMockMode {
            mockTick()
            return
        }

        guard let model else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[WARN] Cannot get pixelBuffer from sampleBuffer.")
            return
        }

        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self else { return }

            if let error {
                print("[ERROR] Vision request failed:", error.localizedDescription)
                return
            }

            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async {
                    self.onResult?([])
                }
                return
            }

            self.updateFps()

            let detections = results.prefix(10).map { obs -> DetectionResult in
                // VNRecognizedObjectObservation.boundingBox 是左下原點。
                // UI / CoreGraphics 常用左上原點，所以翻轉 Y。
                let flipped = CGRect(
                    x: obs.boundingBox.minX,
                    y: 1.0 - obs.boundingBox.maxY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height
                )

                return DetectionResult(
                    boundingBox: flipped,
                    confidence: obs.confidence,
                    fps: self.currentFps,
                    hardware: .npu,
                    dominantColor: self.sampleColor(
                        pixelBuffer: pixelBuffer,
                        normRect: flipped
                    )
                )
            }

            DispatchQueue.main.async {
                self.onResult?(detections)
            }
        }

        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up
        )

        do {
            try handler.perform([request])
        } catch {
            print("[ERROR] VNImageRequestHandler perform failed:", error.localizedDescription)
        }
    }

    // MARK: - FPS

    private func updateFps() {
        frameCount += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsTime

        if elapsed >= 0.5 {
            currentFps = Float(frameCount) / Float(elapsed)
            frameCount = 0
            lastFpsTime = now
        }
    }

    // MARK: - Frame-driven Mock

    private var mockStartTime: TimeInterval = CACurrentMediaTime()

    private func mockTick() {
        let t = Float(CACurrentMediaTime() - mockStartTime)
        let pi2 = Float.pi * 2.0

        let a1 = t * (pi2 / 3.0)
        let cx1 = 0.5 + 0.28 * cos(a1)
        let cy1 = 0.5 + 0.28 * sin(a1)
        let h1: Float = 0.07

        let a2 = -(t * (pi2 / 4.5)) + Float.pi
        let cx2 = 0.5 + 0.22 * cos(a2)
        let cy2 = 0.5 + 0.22 * sin(a2)
        let h2: Float = 0.055

        updateFps()

        let fps = currentFps

        let detections = [
            DetectionResult(
                boundingBox: CGRect(
                    x: Double(cx1 - h1),
                    y: Double(cy1 - h1),
                    width: Double(h1 * 2.0),
                    height: Double(h1 * 2.0)
                ),
                confidence: 0.95,
                fps: fps,
                hardware: .mock,
                dominantColor: UIColor(hex: 0x00DDFF)
            ),
            DetectionResult(
                boundingBox: CGRect(
                    x: Double(cx2 - h2),
                    y: Double(cy2 - h2),
                    width: Double(h2 * 2.0),
                    height: Double(h2 * 2.0)
                ),
                confidence: 0.91,
                fps: fps,
                hardware: .mock,
                dominantColor: UIColor(hex: 0xFF00CC)
            )
        ]

        DispatchQueue.main.async {
            self.onResult?(detections)
        }
    }

    // MARK: - Color Sampling

    private func sampleColor(
        pixelBuffer: CVPixelBuffer,
        normRect: CGRect
    ) -> UIColor {

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return .white
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buf = base.assumingMemoryBound(to: UInt8.self)

        let x0 = max(0, min(w - 1, Int(normRect.minX * CGFloat(w))))
        let y0 = max(0, min(h - 1, Int(normRect.minY * CGFloat(h))))
        let x1 = max(0, min(w, Int(normRect.maxX * CGFloat(w))))
        let y1 = max(0, min(h, Int(normRect.maxY * CGFloat(h))))

        guard x1 > x0, y1 > y0 else {
            return .white
        }

        let step = max(1, (x1 - x0) / 5)

        var rSum = 0
        var gSum = 0
        var bSum = 0
        var n = 0

        var y = y0
        while y < y1 {
            var x = x0

            while x < x1 {
                let off = y * rowBytes + x * 4

                // 32BGRA 記憶體順序通常是 B, G, R, A
                bSum += Int(buf[off])
                gSum += Int(buf[off + 1])
                rSum += Int(buf[off + 2])

                n += 1
                x += step
            }

            y += step
        }

        guard n > 0 else {
            return .white
        }

        return UIColor(
            red: CGFloat(rSum / n) / 255.0,
            green: CGFloat(gSum / n) / 255.0,
            blue: CGFloat(bSum / n) / 255.0,
            alpha: 1.0
        )
    }
}
