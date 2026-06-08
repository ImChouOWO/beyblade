import CoreML
import Vision
import AVFoundation
import UIKit
import ImageIO

private struct InferenceUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

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

    private var activeFrameSize = CGSize(width: 1, height: 1)

    /*
     YOLOv10 standard output:
     [1, 300, 6]

     each row:
     [x1, y1, x2, y2, confidence, classId]
     */
    private let confidenceThreshold: Float = 0.30
    private let nmsIoUThreshold: CGFloat = 0.35
    private let maxOutputDetections = 2

    private let modelInputSize = CGSize(width: 640, height: 640)

    /*
     單類別多目標偵測。
     若你的模型只有一類，classId 應為 0。
     */
    private let singleClassId = 0

    /*
     bbox 方向修正。

     你目前 imageOrientation() = .right。
     iPhone portrait camera 常見需要把 YOLO output 轉到 portrait overlay 座標。

     測試順序：
     1. rotateRight
     2. rotateLeft
     3. flipY
     4. none
     */
    private enum BBoxOrientationMode {
        case none
        case rotateRight
        case rotateLeft
        case flipY
    }

    private let bboxOrientationMode: BBoxOrientationMode = .none
    private var didPrintRawOutputInfo = false
    private var didPrintFirstRows = false
    private var didPrintKeptRows = false

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

        /*
         scaleFill 代表 Vision 會把來源 frame 拉伸到模型輸入尺寸。
         YOLOv10 raw bbox 若是 640x640 座標，會在後面除以 modelInputSize。
         */
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

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

        let boxedPixelBuffer = InferenceUncheckedSendableBox(
            value: pixelBuffer
        )

        let boxedRequest = InferenceUncheckedSendableBox(
            value: request
        )

        inferenceQueue.async { [weak self, boxedPixelBuffer, boxedRequest] in
            guard let self else {
                return
            }

            if self.isProcessing {
                return
            }

            self.isProcessing = true

            self.activeFrameSize = CGSize(
                width: frameWidth,
                height: frameHeight
            )

            let handler = VNImageRequestHandler(
                cvPixelBuffer: boxedPixelBuffer.value,
                orientation: self.imageOrientation(),
                options: [:]
            )

            do {
                try handler.perform([boxedRequest.value])
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
         iPhone portrait camera 常見是 .right。
         如果 bbox 方向錯，可嘗試：
         .up / .down / .left / .right
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

    // MARK: - VNRecognizedObjectObservation Output

    private func handleObjectObservations(
        _ objects: [VNRecognizedObjectObservation]
    ) {
        let detections = objects
            .prefix(100)
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
                 UI / DetectionResult 使用左上角，因此這裡翻轉 Y。
                 */
                let rect = CGRect(
                    x: obs.boundingBox.minX,
                    y: 1.0 - obs.boundingBox.maxY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height
                )

                return DetectionResult(
                    boundingBox: clampNormalizedRect(rect),
                    confidence: confidence,
                    fps: currentFps,
                    hardware: BeyTailInferenceHardware.npu,
                    trackId: 0,
                    dominantColor: UIColor(hex: 0x00DDFF)
                )
            }

        let filtered = nonMaximumSuppression(
            detections,
            iouThreshold: nmsIoUThreshold
        )

        DispatchQueue.main.async { [weak self, filtered] in
            self?.onResult?(filtered)
        }
    }

    // MARK: - YOLOv10 Raw Tensor Output

    private func handleRawFeatureObservations(
        _ features: [VNCoreMLFeatureValueObservation]
    ) {
        if !didPrintRawOutputInfo {
            didPrintRawOutputInfo = true

            print("[WARN] CoreML returned raw feature outputs. Decode as YOLOv10 tensor.")
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

        let decoded = decodeYOLOv10Output(
            array,
            sourceFrameSize: activeFrameSize
        )

        let filtered = nonMaximumSuppression(
            decoded,
            iouThreshold: nmsIoUThreshold
        )

        DispatchQueue.main.async { [weak self, filtered] in
            self?.onResult?(filtered)
        }
    }

    private enum YOLOOutputLayout {
        case rowsFirst
        case channelsFirst
    }

    private func decodeYOLOv10Output(
        _ array: MLMultiArray,
        sourceFrameSize: CGSize
    ) -> [DetectionResult] {
        let shape = array.shape.map {
            $0.intValue
        }

        guard shape.count == 3 else {
            print("[ERROR] Unsupported YOLOv10 output rank:", shape)
            return []
        }

        guard shape[0] == 1 else {
            print("[ERROR] Unsupported YOLOv10 batch size:", shape)
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
            print("[ERROR] Unsupported YOLOv10 output shape:", shape)
            return []
        }

        guard valueCount >= 6 else {
            print("[ERROR] YOLOv10 output value count < 6:", shape)
            return []
        }

        var detections: [DetectionResult] = []
        var keptPrintCount = 0

        for row in 0..<rowCount {
            let x1Raw = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 0
            )

            let y1Raw = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 1
            )

            let x2Raw = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 2
            )

            let y2Raw = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 3
            )

            let confidence = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 4
            )

            let classIdFloat = yoloValue(
                array,
                layout: layout,
                row: row,
                col: 5
            )

            if !didPrintFirstRows, row < 5 {
                print(
                    "[DEBUG] row:",
                    row,
                    "x1:", x1Raw,
                    "y1:", y1Raw,
                    "x2:", x2Raw,
                    "y2:", y2Raw,
                    "conf:", confidence,
                    "class:", classIdFloat
                )
            }

            guard x1Raw.isFinite,
                  y1Raw.isFinite,
                  x2Raw.isFinite,
                  y2Raw.isFinite,
                  confidence.isFinite,
                  classIdFloat.isFinite else {
                continue
            }

            guard confidence >= confidenceThreshold else {
                continue
            }

            let classId = Int(classIdFloat.rounded())

            guard classId == singleClassId else {
                continue
            }

            guard let rect = makeYOLOv10XYXYBoundingBox(
                x1: x1Raw,
                y1: y1Raw,
                x2: x2Raw,
                y2: y2Raw,
                sourceFrameSize: sourceFrameSize
            ) else {
                continue
            }

            if !didPrintKeptRows, keptPrintCount < 5 {
                keptPrintCount += 1
                print(
                    "[KEEP]",
                    "x1:", x1Raw,
                    "y1:", y1Raw,
                    "x2:", x2Raw,
                    "y2:", y2Raw,
                    "conf:", confidence,
                    "class:", classIdFloat,
                    "mappedRect:", rect
                )
            }

            /*
             依你的要求：先不要做面積篩選。
             所以這裡不使用 minBoxAreaRatio / maxBoxAreaRatio。
             */

            let detection = DetectionResult(
                boundingBox: rect,
                confidence: confidence,
                fps: currentFps,
                hardware: BeyTailInferenceHardware.npu,
                trackId: 0,
                dominantColor: UIColor(hex: 0x00DDFF)
            )

            detections.append(detection)
        }

        if !didPrintFirstRows {
            didPrintFirstRows = true
        }

        if !didPrintKeptRows, keptPrintCount > 0 {
            didPrintKeptRows = true
        }

        return detections
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

    private func makeYOLOv10XYXYBoundingBox(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        sourceFrameSize: CGSize
    ) -> CGRect? {
        /*
         標準 YOLOv10 格式：
         [x1, y1, x2, y2]

         先轉成 normalized rect，再根據 bboxOrientationMode 做方向修正。
         */

        let rawX1 = CGFloat(x1)
        let rawY1 = CGFloat(y1)
        let rawX2 = CGFloat(x2)
        let rawY2 = CGFloat(y2)

        let maxCoordinate = max(
            max(abs(rawX1), abs(rawY1)),
            max(abs(rawX2), abs(rawY2))
        )

        let coordinateSpace = inferCoordinateSpace(
            maxCoordinate: maxCoordinate,
            sourceFrameSize: sourceFrameSize
        )

        let normalized = normalizeYOLOCoordinates(
            x1: rawX1,
            y1: rawY1,
            x2: rawX2,
            y2: rawY2,
            coordinateSpace: coordinateSpace,
            sourceFrameSize: sourceFrameSize
        )

        let nx1 = normalized.0
        let ny1 = normalized.1
        let nx2 = normalized.2
        let ny2 = normalized.3

        guard nx2 > nx1,
              ny2 > ny1 else {
            return nil
        }

        let rawRect = CGRect(
            x: nx1,
            y: ny1,
            width: nx2 - nx1,
            height: ny2 - ny1
        )

        let orientedRect = applyBBoxOrientation(rawRect)
        let clamped = clampNormalizedRect(orientedRect)

        guard clamped.width > 0.001,
              clamped.height > 0.001 else {
            return nil
        }

        return clamped
    }

    private func applyBBoxOrientation(
        _ rect: CGRect
    ) -> CGRect {
        switch bboxOrientationMode {
        case .none:
            return rect

        case .flipY:
            return CGRect(
                x: rect.minX,
                y: 1.0 - rect.maxY,
                width: rect.width,
                height: rect.height
            )

        case .rotateRight:
            /*
             normalized point transform:
             old(x, y) -> new(1 - y, x)
             */
            let p1 = CGPoint(
                x: 1.0 - rect.minY,
                y: rect.minX
            )

            let p2 = CGPoint(
                x: 1.0 - rect.maxY,
                y: rect.maxX
            )

            return rectFromPoints(p1, p2)

        case .rotateLeft:
            /*
             normalized point transform:
             old(x, y) -> new(y, 1 - x)
             */
            let p1 = CGPoint(
                x: rect.minY,
                y: 1.0 - rect.minX
            )

            let p2 = CGPoint(
                x: rect.maxY,
                y: 1.0 - rect.maxX
            )

            return rectFromPoints(p1, p2)
        }
    }

    private func rectFromPoints(
        _ a: CGPoint,
        _ b: CGPoint
    ) -> CGRect {
        let minX = min(a.x, b.x)
        let minY = min(a.y, b.y)
        let maxX = max(a.x, b.x)
        let maxY = max(a.y, b.y)

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private enum YOLOCoordinateSpace {
        case normalized
        case modelInputPixel
        case sourceFramePixel
    }

    private func inferCoordinateSpace(
        maxCoordinate: CGFloat,
        sourceFrameSize: CGSize
    ) -> YOLOCoordinateSpace {
        if maxCoordinate <= 2.0 {
            return .normalized
        }

        let modelMax = max(
            modelInputSize.width,
            modelInputSize.height
        )

        if maxCoordinate <= modelMax * 1.25 {
            return .modelInputPixel
        }

        return .sourceFramePixel
    }

    private func normalizeYOLOCoordinates(
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat,
        coordinateSpace: YOLOCoordinateSpace,
        sourceFrameSize: CGSize
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch coordinateSpace {
        case .normalized:
            return (
                x1,
                y1,
                x2,
                y2
            )

        case .modelInputPixel:
            return (
                x1 / modelInputSize.width,
                y1 / modelInputSize.height,
                x2 / modelInputSize.width,
                y2 / modelInputSize.height
            )

        case .sourceFramePixel:
            let safeWidth = max(sourceFrameSize.width, 1.0)
            let safeHeight = max(sourceFrameSize.height, 1.0)

            return (
                x1 / safeWidth,
                y1 / safeHeight,
                x2 / safeWidth,
                y2 / safeHeight
            )
        }
    }

    private func clampNormalizedRect(
        _ rect: CGRect
    ) -> CGRect {
        let minX = clamp(
            rect.minX,
            lower: 0.0,
            upper: 1.0
        )

        let minY = clamp(
            rect.minY,
            lower: 0.0,
            upper: 1.0
        )

        let maxX = clamp(
            rect.maxX,
            lower: 0.0,
            upper: 1.0
        )

        let maxY = clamp(
            rect.maxY,
            lower: 0.0,
            upper: 1.0
        )

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

        return Array(selected.prefix(maxOutputDetections))
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
