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

    private let confidenceThreshold: Float = 0.35
    private let nmsIoUThreshold: CGFloat = 0.45

    /*
     如果你的模型是 YOLO 640x640 匯出的 raw output，
     且輸出座標是 pixel 座標，這裡用 640 轉成 normalized 0...1。
     如果輸出本來就是 normalized，程式會自動判斷不除以 640。
     */
    private let modelInputSize: CGFloat = 640.0

    private var didPrintRawOutputInfo = false

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

        let boxedPixelBuffer = InferenceUncheckedSendableBox(
            value: pixelBuffer
        )

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
                print(
                    "[ERROR] VNImageRequestHandler perform failed:",
                    error.localizedDescription
                )

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
         如果 bbox 方向錯誤，可嘗試：
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

    // MARK: - Vision Object Detector Output

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

                guard confidence >= confidenceThreshold else {
                    return nil
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
                    boundingBox: clampNormalizedRect(flipped),
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

    // MARK: - YOLO Raw Tensor Output

    private func handleRawFeatureObservations(
        _ features: [VNCoreMLFeatureValueObservation]
    ) {
        if !didPrintRawOutputInfo {
            didPrintRawOutputInfo = true

            print("[WARN] CoreML returned raw feature outputs. Decode as YOLO tensor.")
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
        }

        guard let array = features.first?.featureValue.multiArrayValue else {
            DispatchQueue.main.async { [weak self] in
                self?.onResult?([])
            }
            return
        }

        let decoded = decodeYOLOOutput(array)
        let filtered = nonMaximumSuppression(
            decoded,
            iouThreshold: nmsIoUThreshold
        )

        DispatchQueue.main.async { [weak self, filtered] in
            self?.onResult?(filtered)
        }
    }

    private func decodeYOLOOutput(
        _ array: MLMultiArray
    ) -> [DetectionResult] {
        let shape = array.shape.map { $0.intValue }

        /*
         目前你的模型輸出：
         [1, 300, 6]

         每一筆預期為：
         [x1, y1, x2, y2, confidence, classId]
         */
        guard shape.count == 3 else {
            print("[ERROR] Unsupported YOLO output rank:", shape)
            return []
        }

        guard shape[0] == 1 else {
            print("[ERROR] Unsupported YOLO batch size:", shape)
            return []
        }

        let rowCount: Int
        let valueCount: Int
        let layout: YOLOOutputLayout

        if shape[2] >= 6 {
            rowCount = shape[1]
            valueCount = shape[2]
            layout = .rowsFirst
        } else if shape[1] >= 6 {
            rowCount = shape[2]
            valueCount = shape[1]
            layout = .channelsFirst
        } else {
            print("[ERROR] Unsupported YOLO output shape:", shape)
            return []
        }

        guard valueCount >= 6 else {
            print("[ERROR] YOLO output value count < 6:", shape)
            return []
        }

        var detections: [DetectionResult] = []

        for index in 0..<rowCount {
            let v0 = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 0
            )

            let v1 = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 1
            )

            let v2 = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 2
            )

            let v3 = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 3
            )

            let confidence = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 4
            )

            let classIdFloat = yoloValue(
                array,
                layout: layout,
                row: index,
                col: 5
            )

            guard confidence >= confidenceThreshold else {
                continue
            }

            guard let rect = makeYOLOBoundingBox(
                v0: v0,
                v1: v1,
                v2: v2,
                v3: v3
            ) else {
                continue
            }

            let classId = Int(classIdFloat.rounded())
            let color = colorForClass(classId)

            let detection = DetectionResult(
                boundingBox: rect,
                confidence: confidence,
                fps: currentFps,
                hardware: BeyTailInferenceHardware.npu,
                trackId: 0,
                dominantColor: color
            )

            detections.append(detection)
        }

        return detections
    }

    private enum YOLOOutputLayout {
        case rowsFirst
        case channelsFirst
    }

    private func yoloValue(
        _ array: MLMultiArray,
        layout: YOLOOutputLayout,
        row: Int,
        col: Int
    ) -> Float {
        let indexes: [NSNumber]

        switch layout {
        case .rowsFirst:
            indexes = [
                NSNumber(value: 0),
                NSNumber(value: row),
                NSNumber(value: col)
            ]

        case .channelsFirst:
            indexes = [
                NSNumber(value: 0),
                NSNumber(value: col),
                NSNumber(value: row)
            ]
        }

        return array[indexes].floatValue
    }

    private func makeYOLOBoundingBox(
        v0: Float,
        v1: Float,
        v2: Float,
        v3: Float
    ) -> CGRect? {
        /*
         優先判斷為 xyxy：
         [x1, y1, x2, y2]
         如果 x2 <= x1 或 y2 <= y1，再退回 cxcywh：
         [cx, cy, w, h]
         */

        let a = CGFloat(v0)
        let b = CGFloat(v1)
        let c = CGFloat(v2)
        let d = CGFloat(v3)

        let maxCoordinate = max(
            abs(a),
            abs(b),
            abs(c),
            abs(d)
        )

        let divisor: CGFloat = maxCoordinate > 2.0 ? modelInputSize : 1.0

        let x0 = a / divisor
        let y0 = b / divisor
        let x1 = c / divisor
        let y1 = d / divisor

        let rect: CGRect

        if x1 > x0, y1 > y0 {
            rect = CGRect(
                x: x0,
                y: y0,
                width: x1 - x0,
                height: y1 - y0
            )
        } else {
            let cx = a / divisor
            let cy = b / divisor
            let w = c / divisor
            let h = d / divisor

            guard w > 0,
                  h > 0 else {
                return nil
            }

            rect = CGRect(
                x: cx - w / 2.0,
                y: cy - h / 2.0,
                width: w,
                height: h
            )
        }

        let clamped = clampNormalizedRect(rect)

        guard clamped.width > 0.001,
              clamped.height > 0.001 else {
            return nil
        }

        return clamped
    }

    private func clampNormalizedRect(
        _ rect: CGRect
    ) -> CGRect {
        let minX = clamp(rect.minX, lower: 0.0, upper: 1.0)
        let minY = clamp(rect.minY, lower: 0.0, upper: 1.0)
        let maxX = clamp(rect.maxX, lower: 0.0, upper: 1.0)
        let maxY = clamp(rect.maxY, lower: 0.0, upper: 1.0)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0, maxX - minX),
            height: max(0.0, maxY - minY)
        )
    }

    private func clamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func colorForClass(_ classId: Int) -> UIColor {
        switch classId {
        case 0:
            return UIColor(hex: 0x00DDFF)

        case 1:
            return UIColor(hex: 0xFF00CC)

        case 2:
            return UIColor(hex: 0xFFD400)

        default:
            return .white
        }
    }

    // MARK: - NMS

    private func nonMaximumSuppression(
        _ detections: [DetectionResult],
        iouThreshold: CGFloat
    ) -> [DetectionResult] {
        let sorted = detections.sorted {
            $0.confidence > $1.confidence
        }

        var selected: [DetectionResult] = []

        for detection in sorted {
            var shouldKeep = true

            for kept in selected {
                let overlap = iou(
                    detection.boundingBox,
                    kept.boundingBox
                )

                if overlap > iouThreshold {
                    shouldKeep = false
                    break
                }
            }

            if shouldKeep {
                selected.append(detection)
            }
        }

        return selected
    }

    private func iou(
        _ a: CGRect,
        _ b: CGRect
    ) -> CGFloat {
        let intersection = a.intersection(b)

        if intersection.isNull ||
           intersection.width <= 0 ||
           intersection.height <= 0 {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea

        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
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