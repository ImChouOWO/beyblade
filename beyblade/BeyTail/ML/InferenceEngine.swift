import CoreML
import Vision
import AVFoundation
import UIKit
import ImageIO

private struct InferenceUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

// 對應 Android InferenceEngine.kt
// 有 CoreML 模型 → 真實推論
// 無模型 → frame-driven mock 模式
final class InferenceEngine: @unchecked Sendable {

    let isMockMode: Bool

    private let modelName: String
    private var model: VNCoreMLModel?
    private var request: VNCoreMLRequest?

    private let inferenceQueue = DispatchQueue(
        label: "com.beytail.inference.engine",
        qos: .userInitiated
    )

    private var isProcessing = false

    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()
    private(set) var currentFps: Float = 0

    var onResult: (([DetectionResult]) -> Void)?

    // MARK: - Init

    init(modelName: String = "best") {
        self.modelName = modelName

        if let modelURL = Bundle.main.url(
            forResource: modelName,
            withExtension: "mlmodelc"
        ) {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all

                let mlModel = try MLModel(
                    contentsOf: modelURL,
                    configuration: config
                )

                let vnModel = try VNCoreMLModel(for: mlModel)

                self.model = vnModel
                self.isMockMode = false

                self.request = Self.makeRequest(
                    model: vnModel,
                    onResult: { [weak self] request, error in
                        self?.handleVisionResult(
                            request: request,
                            error: error
                        )
                    }
                )

                print("[INFO] CoreML model loaded:", modelURL.lastPathComponent)

            } catch {
                self.model = nil
                self.request = nil
                self.isMockMode = true

                print("[ERROR] CoreML model load failed:", error.localizedDescription)
                print("[INFO] Use frame-driven MOCK mode:", modelName)
            }

        } else {
            self.model = nil
            self.request = nil
            self.isMockMode = true

            print("[INFO] CoreML model not found. Use frame-driven MOCK mode:", modelName)
        }
    }

    private static func makeRequest(
        model: VNCoreMLModel,
        onResult: @escaping (VNRequest, Error?) -> Void
    ) -> VNCoreMLRequest {
        let request = VNCoreMLRequest(
            model: model,
            completionHandler: onResult
        )

        request.imageCropAndScaleOption = .scaleFill

        return request
    }

    // MARK: - Public API

    func start() {
        if isMockMode {
            print("[INFO] InferenceEngine mock mode enabled. No Timer is used.")
        } else {
            print("[INFO] InferenceEngine started:", modelName)
        }
    }

    func stop() {
        inferenceQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.isProcessing = false
        }

        print("[INFO] InferenceEngine stop")
    }

    func processFrame(_ sampleBuffer: CMSampleBuffer) {
        if isMockMode {
            mockTick()
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[WARN] Cannot get pixelBuffer from sampleBuffer.")
            return
        }

        guard let request else {
            return
        }

        let boxedPixelBuffer = InferenceUncheckedSendableBox(value: pixelBuffer)

        inferenceQueue.async { [weak self, boxedPixelBuffer, request] in
            guard let self else {
                return
            }

            if self.isProcessing {
                return
            }

            self.isProcessing = true

            let handler = VNImageRequestHandler(
                cvPixelBuffer: boxedPixelBuffer.value,
                orientation: self.imageOrientation(),
                options: [:]
            )

            do {
                try handler.perform([request])
            } catch {
                print("[ERROR] VNImageRequestHandler perform failed:", error.localizedDescription)

                self.isProcessing = false

                DispatchQueue.main.async { [weak self] in
                    self?.onResult?([])
                }
            }
        }
    }

    private func imageOrientation() -> CGImagePropertyOrientation {
        /*
         目前先以 iPhone 直向 portrait 為主。
         如果 bbox 旋轉或方向錯誤，可嘗試：
         .right / .left / .up / .down
         */
        return .right
    }

    // MARK: - Vision Result

    private func handleVisionResult(
        request: VNRequest,
        error: Error?
    ) {
        defer {
            inferenceQueue.async { [weak self] in
                self?.isProcessing = false
            }
        }

        if let error {
            print("[ERROR] Vision request failed:", error.localizedDescription)

            DispatchQueue.main.async { [weak self] in
                self?.onResult?([])
            }

            return
        }

        updateFps()

        guard let results = request.results else {
            DispatchQueue.main.async { [weak self] in
                self?.onResult?([])
            }

            return
        }

        if let objects = results as? [VNRecognizedObjectObservation] {
            handleObjectObservations(objects)
            return
        }

        if let features = results as? [VNCoreMLFeatureValueObservation] {
            handleRawFeatureObservations(features)
            return
        }

        print("[WARN] Unsupported Vision result type:", type(of: results.first))

        DispatchQueue.main.async { [weak self] in
            self?.onResult?([])
        }
    }

    private func handleObjectObservations(
        _ objects: [VNRecognizedObjectObservation]
    ) {
        let detections = objects
            .prefix(10)
            .compactMap { obs -> DetectionResult? in
                let confidence: Float

                if let bestLabel = obs.labels.first {
                    confidence = bestLabel.confidence
                } else {
                    confidence = obs.confidence
                }

                /*
                 VNRecognizedObjectObservation.boundingBox 是 normalized 0...1，
                 原點在左下角。

                 DetectionResult / UI 使用左上座標，因此這裡翻轉 Y。
                 */
                let flipped = CGRect(
                    x: obs.boundingBox.minX,
                    y: 1.0 - obs.boundingBox.maxY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height
                )

                return DetectionResult(
                    boundingBox: flipped,
                    confidence: confidence,
                    fps: currentFps,
                    hardware: BeyTailInferenceHardware.npu,
                    trackId: 0,
                    dominantColor: .white
                )
            }

        DispatchQueue.main.async { [weak self, detections] in
            self?.onResult?(detections)
        }
    }

    private func handleRawFeatureObservations(
        _ features: [VNCoreMLFeatureValueObservation]
    ) {
        /*
         如果看到這個 log，代表 CoreML 模型不是 Vision Object Detector 格式，
         可能是 YOLO raw tensor output。

         下一步需要補 YOLO output decode：
         1. 讀取 MLMultiArray
         2. 解析 bbox / confidence / class
         3. threshold
         4. NMS
         */

        print("[WARN] CoreML returned raw feature outputs. Need YOLO tensor decode.")
        print("[WARN] raw output count:", features.count)

        for feature in features {
            print(
                "[WARN] output:",
                feature.featureName,
                "type:",
                feature.featureValue.type
            )

            if let array = feature.featureValue.multiArrayValue {
                print(
                    "[WARN] MLMultiArray shape:",
                    array.shape,
                    "dataType:",
                    array.dataType.rawValue
                )
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onResult?([])
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
                hardware: BeyTailInferenceHardware.mock,
                trackId: 0,
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
                hardware: BeyTailInferenceHardware.mock,
                trackId: 0,
                dominantColor: UIColor(hex: 0xFF00CC)
            )
        ]

        DispatchQueue.main.async { [weak self, detections] in
            self?.onResult?(detections)
        }
    }
}