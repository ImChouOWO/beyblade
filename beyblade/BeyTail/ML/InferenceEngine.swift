import CoreML
import Vision
import AVFoundation
import UIKit
import ImageIO

private struct InferenceUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

private struct PendingInferenceFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let sourceSize: CGSize
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

    /// 一次只執行一個 Vision request。
    private var isProcessing = false

    /// 推論忙碌時不再直接丟掉所有影格，只保留最新一張等待處理。
    private var pendingFrame: PendingInferenceFrame?
    private var replacedPendingFrameCount = 0
    private var isEnabled = false

    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()
    private(set) var currentFps: Float = 0

    private var activeFrameSize = CGSize(width: 1, height: 1)

    private let dominantColorExtractor = DominantColorExtractor()
    private var activeColorPixelBuffer: CVPixelBuffer?
    private var activeColorOrientation: CGImagePropertyOrientation = .up

    /// 高速模糊時允許較低信心框進入追蹤器。
    /// 新軌跡仍會由 BeybladeTracker 的較高門檻與連續確認機制過濾。
    private let confidenceThreshold: Float = 0.15

    /// 稍微放寬 NMS，降低兩顆陀螺接近時被合併成一顆的機率。
    private let nmsIoUThreshold: CGFloat = 0.35

    /// 避免大量低品質候選框進入追蹤器。
    private let maxOutputDetections = 3

    /// App 預期使用的模型輸入尺寸。
    /// 真正推論尺寸仍由 Core ML 模型本身決定。
    private static let preferredModelInputSize = CGSize(
        width: 640,
        height: 640
    )

    /// YOLO raw output bbox 座標的基準尺寸。
    /// 啟動時會從 Core ML model description 讀取實際值。
    private var modelInputSize = CGSize(
        width: 640,
        height: 640
    )

    private let singleClassId = 0

    private var didPrintFrameDebug = false
    private var didPrintRawOutputInfo = false
    private var didPrintFirstRows = false
    private var didPrintKeptRows = false
    private var didPrintCoordinateDebug = false

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

                self.modelInputSize = Self.detectModelInputSize(
                    from: mlModel,
                    fallback: Self.preferredModelInputSize
                )

                Self.printModelDescriptionDebug(
                    mlModel,
                    resolvedModelInputSize: modelInputSize,
                    preferredModelInputSize: Self.preferredModelInputSize
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

                print(
                    "[INFO] CoreML model loaded:",
                    modelURL.lastPathComponent
                )

            } catch {
                self.model = nil
                self.request = nil
                self.isMockMode = true

                print(
                    "[ERROR] CoreML model load failed:",
                    error.localizedDescription
                )
                print(
                    "[INFO] Use frame-driven MOCK mode:",
                    modelName
                )
            }

        } else {
            self.model = nil
            self.request = nil
            self.isMockMode = true

            print(
                "[INFO] CoreML model not found. Use frame-driven MOCK mode:",
                modelName
            )
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

    // MARK: - Model Input

    private static func detectModelInputSize(
        from mlModel: MLModel,
        fallback: CGSize
    ) -> CGSize {
        for (_, description) in
            mlModel.modelDescription.inputDescriptionsByName {
            if let imageConstraint = description.imageConstraint {
                let width = imageConstraint.pixelsWide
                let height = imageConstraint.pixelsHigh

                if width > 0,
                   height > 0 {
                    return CGSize(
                        width: width,
                        height: height
                    )
                }
            }

            if let multiArrayConstraint =
                description.multiArrayConstraint {
                let shape = multiArrayConstraint.shape.map {
                    $0.intValue
                }

                if shape.count >= 2 {
                    let height = shape[shape.count - 2]
                    let width = shape[shape.count - 1]

                    if width > 0,
                       height > 0 {
                        return CGSize(
                            width: width,
                            height: height
                        )
                    }
                }
            }
        }

        return fallback
    }

    private static func printModelDescriptionDebug(
        _ mlModel: MLModel,
        resolvedModelInputSize: CGSize,
        preferredModelInputSize: CGSize
    ) {
        print("========== [MODEL DESCRIPTION DEBUG] ==========")
        print(
            "[MODEL RESOLVED INPUT SIZE]",
            resolvedModelInputSize
        )

        if resolvedModelInputSize != preferredModelInputSize {
            print(
                "[MODEL WARNING] Current Core ML model is not 640x640:",
                resolvedModelInputSize,
                "The model must be re-exported as 640x640 to perform true 640x640 inference."
            )
        } else {
            print("[MODEL INPUT] 640x640 enabled")
        }

        for input in mlModel.modelDescription.inputDescriptionsByName {
            print(
                "[MODEL INPUT]",
                input.key,
                "type:",
                input.value.type.rawValue
            )
        }

        for output in mlModel.modelDescription.outputDescriptionsByName {
            print(
                "[MODEL OUTPUT]",
                output.key,
                "type:",
                output.value.type.rawValue
            )
        }

        print("===============================================")
    }

    // MARK: - Public API

    func start() {
        inferenceQueue.async { [weak self] in
            self?.isEnabled = true
        }

        if isMockMode {
            print(
                "[INFO] InferenceEngine mock mode enabled. No Timer is used."
            )
        } else {
            print(
                "[INFO] InferenceEngine started:",
                modelName,
                "input:",
                modelInputSize
            )
        }
    }

    func stop() {
        inferenceQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.isEnabled = false
            self.pendingFrame = nil
            self.activeColorPixelBuffer = nil
            self.isProcessing = false
        }

        print("[INFO] InferenceEngine stop")
    }

    func processFrame(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) {
        if isMockMode {
            mockTick()
            return
        }

        guard let pixelBuffer =
            CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print(
                "[WARN] Cannot get pixelBuffer from sampleBuffer."
            )
            return
        }

        let frame = PendingInferenceFrame(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            sourceSize: CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )

        inferenceQueue.async { [weak self, frame] in
            guard let self,
                  self.isEnabled else {
                return
            }

            if self.isProcessing {
                self.pendingFrame = frame
                self.replacedPendingFrameCount += 1

                if self.replacedPendingFrameCount.isMultiple(of: 30) {
                    print(
                        "[Inference] pending frame replaced:",
                        self.replacedPendingFrameCount
                    )
                }
                return
            }

            self.isProcessing = true
            self.performInference(frame)
        }
    }

    /// 離線影片處理使用的同步推論介面。
    func inferSynchronously(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        timestamp: TimeInterval = 0
    ) throws -> [DetectionResult] {
        if isMockMode {
            return makeMockDetections(
                timestamp: timestamp,
                fps: 0
            )
        }

        guard let model else {
            return []
        }

        let frameSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        let synchronousRequest = VNCoreMLRequest(model: model)
        synchronousRequest.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        try handler.perform([synchronousRequest])

        if let objects = synchronousRequest.results as?
            [VNRecognizedObjectObservation] {
            let detections = decodeObjectObservations(
                objects,
                fps: 0
            )

            let filtered = nonMaximumSuppression(
                detections,
                iouThreshold: nmsIoUThreshold
            )

            return applyingDominantColors(
                to: filtered,
                pixelBuffer: pixelBuffer,
                orientation: orientation
            )
        }

        if let features = synchronousRequest.results as?
            [VNCoreMLFeatureValueObservation],
           let array = features.first?.featureValue.multiArrayValue {
            let decoded = decodeYOLOv10Output(
                array,
                sourceFrameSize: frameSize,
                fps: 0
            )

            let filtered = nonMaximumSuppression(
                decoded,
                iouThreshold: nmsIoUThreshold
            )

            return applyingDominantColors(
                to: filtered,
                pixelBuffer: pixelBuffer,
                orientation: orientation
            )
        }

        return []
    }

    // MARK: - Live Inference Buffer

    private func performInference(
        _ frame: PendingInferenceFrame
    ) {
        guard isEnabled,
              let request else {
            finishCurrentInference()
            return
        }

        activeFrameSize = frame.sourceSize
        activeColorPixelBuffer = frame.pixelBuffer
        activeColorOrientation = frame.orientation

        if !didPrintFrameDebug {
            didPrintFrameDebug = true

            print(
                "[FRAME DEBUG]",
                "pixelBufferSize:",
                frame.sourceSize,
                "orientation:",
                frame.orientation.rawValue,
                "modelInputSize:",
                modelInputSize
            )
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: frame.orientation,
            options: [:]
        )

        do {
            try autoreleasepool {
                try handler.perform([request])
            }
        } catch {
            print(
                "[ERROR] VNImageRequestHandler perform failed:",
                error.localizedDescription
            )

            publish([])
            finishCurrentInference()
        }
    }

    private func finishCurrentInference() {
        activeColorPixelBuffer = nil

        guard isEnabled else {
            pendingFrame = nil
            isProcessing = false
            return
        }

        if let nextFrame = pendingFrame {
            pendingFrame = nil
            inferenceQueue.async { [weak self, nextFrame] in
                self?.performInference(nextFrame)
            }
        } else {
            isProcessing = false
        }
    }

    // MARK: - Vision Result

    private func handleVisionResult(
        request: VNRequest,
        error: Error?
    ) {
        defer {
            finishCurrentInference()
        }

        guard isEnabled else {
            return
        }

        if let error {
            print(
                "[ERROR] Vision request failed:",
                error.localizedDescription
            )
            publish([])
            return
        }

        updateFps()

        guard let results = request.results else {
            publish([])
            return
        }

        if let objects = results as?
            [VNRecognizedObjectObservation] {
            let detections = decodeObjectObservations(
                objects,
                fps: currentFps
            )

            let filtered = nonMaximumSuppression(
                detections,
                iouThreshold: nmsIoUThreshold
            )

            publish(
                applyingDominantColors(
                    to: filtered
                )
            )
            return
        }

        if let features = results as?
            [VNCoreMLFeatureValueObservation] {
            handleRawFeatureObservations(features)
            return
        }

        print(
            "[WARN] Unsupported Vision result type:",
            String(describing: results.first)
        )
        publish([])
    }

    private func decodeObjectObservations(
        _ objects: [VNRecognizedObjectObservation],
        fps: Float
    ) -> [DetectionResult] {
        objects
            .prefix(100)
            .compactMap { observation -> DetectionResult? in
                let confidence =
                    observation.labels.first?.confidence ??
                    observation.confidence

                guard confidence >= confidenceThreshold else {
                    return nil
                }

                let rect = CGRect(
                    x: observation.boundingBox.minX,
                    y: 1.0 - observation.boundingBox.maxY,
                    width: observation.boundingBox.width,
                    height: observation.boundingBox.height
                )

                return DetectionResult(
                    boundingBox: clampNormalizedRect(rect),
                    confidence: confidence,
                    fps: fps,
                    hardware: BeyTailInferenceHardware.npu,
                    trackId: 0,
                    dominantColor: UIColor(hex: 0x00DDFF)
                )
            }
    }

    // MARK: - YOLOv10 Raw Tensor Output

    private func handleRawFeatureObservations(
        _ features: [VNCoreMLFeatureValueObservation]
    ) {
        if !didPrintRawOutputInfo {
            didPrintRawOutputInfo = true

            print(
                "[WARN] CoreML returned raw feature outputs. Decode as YOLOv10 tensor."
            )

            for feature in features {
                print(
                    "[WARN] output:",
                    feature.featureName,
                    "type:",
                    feature.featureValue.type.rawValue
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

        guard let array =
            features.first?.featureValue.multiArrayValue else {
            publish([])
            return
        }

        let decoded = decodeYOLOv10Output(
            array,
            sourceFrameSize: activeFrameSize,
            fps: currentFps
        )

        let filtered = nonMaximumSuppression(
            decoded,
            iouThreshold: nmsIoUThreshold
        )

        publish(
            applyingDominantColors(
                to: filtered
            )
        )
    }

    private enum YOLOOutputLayout {
        case rowsFirst
        case channelsFirst
    }

    private func decodeYOLOv10Output(
        _ array: MLMultiArray,
        sourceFrameSize: CGSize,
        fps: Float
    ) -> [DetectionResult] {
        let shape = array.shape.map {
            $0.intValue
        }

        guard shape.count == 3,
              shape[0] == 1 else {
            print(
                "[ERROR] Unsupported YOLOv10 output shape:",
                shape
            )
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
            print(
                "[ERROR] Unsupported YOLOv10 output shape:",
                shape
            )
            return []
        }

        guard valueCount >= 6 else {
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

            if !didPrintFirstRows,
               row < 5 {
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
                  classIdFloat.isFinite,
                  confidence >= confidenceThreshold else {
                continue
            }

            let classId = Int(classIdFloat.rounded())

            guard classId == singleClassId,
                  let rect = makeYOLOv10XYXYBoundingBox(
                    x1: x1Raw,
                    y1: y1Raw,
                    x2: x2Raw,
                    y2: y2Raw,
                    sourceFrameSize: sourceFrameSize
                  ) else {
                continue
            }

            if !didPrintKeptRows,
               keptPrintCount < 5 {
                keptPrintCount += 1

                print(
                    "[KEEP]",
                    "conf:", confidence,
                    "mappedRect:", rect
                )
            }

            detections.append(
                DetectionResult(
                    boundingBox: rect,
                    confidence: confidence,
                    fps: fps,
                    hardware: BeyTailInferenceHardware.npu,
                    trackId: 0,
                    dominantColor: UIColor(hex: 0x00DDFF)
                )
            )
        }

        didPrintFirstRows = true

        if keptPrintCount > 0 {
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

        if !didPrintCoordinateDebug {
            didPrintCoordinateDebug = true

            print(
                "[COORD DEBUG]",
                "maxCoordinate:", maxCoordinate,
                "coordinateSpace:", coordinateSpace,
                "modelInputSize:", modelInputSize,
                "sourceFrameSize:", sourceFrameSize
            )
        }

        let normalized = normalizeYOLOCoordinates(
            x1: rawX1,
            y1: rawY1,
            x2: rawX2,
            y2: rawY2,
            coordinateSpace: coordinateSpace,
            sourceFrameSize: sourceFrameSize
        )

        guard normalized.2 > normalized.0,
              normalized.3 > normalized.1 else {
            return nil
        }

        let clamped = clampNormalizedRect(
            CGRect(
                x: normalized.0,
                y: normalized.1,
                width: normalized.2 - normalized.0,
                height: normalized.3 - normalized.1
            )
        )

        guard clamped.width > 0.001,
              clamped.height > 0.001 else {
            return nil
        }

        return clamped
    }

    private enum YOLOCoordinateSpace: CustomStringConvertible {
        case normalized
        case modelInputPixel
        case sourceFramePixel

        var description: String {
            switch self {
            case .normalized:
                return "normalized"
            case .modelInputPixel:
                return "modelInputPixel"
            case .sourceFramePixel:
                return "sourceFramePixel"
            }
        }
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

        if maxCoordinate <= modelMax * 1.50 {
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
                x1 / max(modelInputSize.width, 1.0),
                y1 / max(modelInputSize.height, 1.0),
                x2 / max(modelInputSize.width, 1.0),
                y2 / max(modelInputSize.height, 1.0)
            )

        case .sourceFramePixel:
            return (
                x1 / max(sourceFrameSize.width, 1.0),
                y1 / max(sourceFrameSize.height, 1.0),
                x2 / max(sourceFrameSize.width, 1.0),
                y2 / max(sourceFrameSize.height, 1.0)
            )
        }
    }

    // MARK: - Dominant Color

    private func applyingDominantColors(
        to detections: [DetectionResult]
    ) -> [DetectionResult] {
        guard let pixelBuffer = activeColorPixelBuffer else {
            return detections
        }

        return applyingDominantColors(
            to: detections,
            pixelBuffer: pixelBuffer,
            orientation: activeColorOrientation
        )
    }

    private func applyingDominantColors(
        to detections: [DetectionResult],
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [DetectionResult] {
        detections.map { detection in
            let detectedColor = dominantColorExtractor.extract(
                from: pixelBuffer,
                normalizedRect: detection.boundingBox,
                orientation: orientation
            ) ?? detection.dominantColor

            return DetectionResult(
                boundingBox: detection.boundingBox,
                confidence: detection.confidence,
                fps: detection.fps,
                hardware: detection.hardware,
                trackId: detection.trackId,
                dominantColor: detectedColor
            )
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
            let shouldKeep = selected.allSatisfy { kept in
                iou(
                    detection.boundingBox,
                    kept.boundingBox
                ) <= iouThreshold
            }

            if shouldKeep {
                selected.append(detection)
            }

            if selected.count >= maxOutputDetections {
                break
            }
        }

        return selected
    }

    private func iou(
        _ first: CGRect,
        _ second: CGRect
    ) -> CGFloat {
        let intersection = first.intersection(second)

        if intersection.isNull ||
           intersection.width <= 0 ||
           intersection.height <= 0 {
            return 0
        }

        let intersectionArea =
            intersection.width * intersection.height

        let unionArea =
            first.width * first.height +
            second.width * second.height -
            intersectionArea

        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
    }

    // MARK: - Normalization

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

    // MARK: - Result / FPS

    private func publish(
        _ detections: [DetectionResult]
    ) {
        DispatchQueue.main.async { [weak self, detections] in
            self?.onResult?(detections)
        }
    }

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
        let timestamp = CACurrentMediaTime() - mockStartTime

        updateFps()

        publish(
            makeMockDetections(
                timestamp: timestamp,
                fps: currentFps
            )
        )
    }

    private func makeMockDetections(
        timestamp: TimeInterval,
        fps: Float
    ) -> [DetectionResult] {
        let t = Float(timestamp)
        let pi2 = Float.pi * 2.0

        let firstAngle = t * (pi2 / 3.0)
        let firstCenterX = 0.5 + 0.28 * cos(firstAngle)
        let firstCenterY = 0.5 + 0.28 * sin(firstAngle)
        let firstHalfSize: Float = 0.07

        let secondAngle =
            -(t * (pi2 / 4.5)) + Float.pi
        let secondCenterX = 0.5 + 0.22 * cos(secondAngle)
        let secondCenterY = 0.5 + 0.22 * sin(secondAngle)
        let secondHalfSize: Float = 0.055

        return [
            DetectionResult(
                boundingBox: CGRect(
                    x: Double(firstCenterX - firstHalfSize),
                    y: Double(firstCenterY - firstHalfSize),
                    width: Double(firstHalfSize * 2.0),
                    height: Double(firstHalfSize * 2.0)
                ),
                confidence: 0.95,
                fps: fps,
                hardware: BeyTailInferenceHardware.mock,
                trackId: 0,
                dominantColor: UIColor(hex: 0x00DDFF)
            ),
            DetectionResult(
                boundingBox: CGRect(
                    x: Double(secondCenterX - secondHalfSize),
                    y: Double(secondCenterY - secondHalfSize),
                    width: Double(secondHalfSize * 2.0),
                    height: Double(secondHalfSize * 2.0)
                ),
                confidence: 0.91,
                fps: fps,
                hardware: BeyTailInferenceHardware.mock,
                trackId: 0,
                dominantColor: UIColor(hex: 0xFF00CC)
            )
        ]
    }
}
