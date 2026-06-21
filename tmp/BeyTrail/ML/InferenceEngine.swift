import Foundation
import CoreVideo
import simd

/// 推論引擎 — 對應 Android InferenceEngine：
///   - 模型存在（Resources/Models/BeybladeDetector.mlmodelc）→ Core ML 推論
///   - 不存在 → Mock 模式（畫面中央繞圈假資料，供 UI/特效開發）
///
/// 模型到位後的兩條路線（擇一）：
///   A. Core ML：用 coremltools 把 YOLO .tflite/.pt 轉成 .mlmodel，放進 Resources/Models/，
///      補完 `runCoreML()` 的輸出解析（YOLO head 解碼 + NMS，可照 Android runInference 移植）
///   B. TFLite：加 TensorFlowLiteSwift SPM/Pod，直接載入 .tflite（介面相同）
final class InferenceEngine {

    let isMockMode: Bool
    private(set) var hardware: InferenceHardware = .mock
    private(set) var currentFps: Float = 0

    /// YOLO 每 N 幀跑一次，其餘幀 Kalman 補位（30fps=2、60fps=4，同 Android）
    var inferenceFrameInterval = 2

    let confidenceThreshold: Float = 0.5
    let nmsIouThreshold: Float = 0.45

    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()

    // Mock 狀態
    private var mockAngle: Float = 0

    init() {
        // TODO(模型)：嘗試載入 Core ML 模型
        // if let url = Bundle.main.url(forResource: "BeybladeDetector", withExtension: "mlmodelc") {
        //     model = try? MLModel(contentsOf: url, configuration: cfg) // cfg.computeUnits = .all → ANE
        //     isMockMode = (model == nil)
        // }
        isMockMode = true
        hardware = .mock
    }

    /// 對一幀 BGRA pixel buffer 做推論（即時與離線共用）。
    /// 回傳正規化偵測框 + 中心色。
    func infer(pixelBuffer: CVPixelBuffer) -> [DetectionResult] {
        updateFps()
        if isMockMode { return mockDetections() }
        // TODO(模型)：縮放至模型輸入 → Core ML 推論 → YOLO 解碼 + NMS
        //             → sampleCenterColor() 取中心色（照 Android sampleBboxColorFromPlanes 移植）
        return []
    }

    // ── Mock：畫面中央繞圈（同 Android mock 行為） ──────────────────────
    private func mockDetections() -> [DetectionResult] {
        mockAngle += 0.12
        let cx = 0.5 + 0.22 * cos(mockAngle)
        let cy = 0.5 + 0.22 * sin(mockAngle)
        let size: Float = 0.14
        return [DetectionResult(
            boundingBox: SIMD4(cx - size / 2, cy - size / 2, size, size),
            confidence: 0.9,
            fps: currentFps,
            hardware: .mock,
            dominantColor: SIMD3(0, 0.867, 1))]   // 0x00DDFF
    }

    // ── 中心色取樣（模型到位後由 infer 呼叫） ───────────────────────────
    /// 取 bbox 中心 0.2 半徑區域平均色，飽和/亮度設下限（同 Android）。
    func sampleCenterColor(pixelBuffer: CVPixelBuffer, box: SIMD4<Float>) -> SIMD3<Float> {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return SIMD3(1, 1, 1) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let cx = (box.x + box.z / 2) * Float(w)
        let cy = (box.y + box.w / 2) * Float(h)
        let r = min(box.z * Float(w), box.w * Float(h)) * 0.2
        let x0 = max(0, Int(cx - r)), x1 = min(w - 1, Int(cx + r))
        let y0 = max(0, Int(cy - r)), y1 = min(h - 1, Int(cy + r))
        guard x1 > x0, y1 > y0 else { return SIMD3(1, 1, 1) }

        let step = max(1, (x1 - x0) / 5)
        var rSum = 0, gSum = 0, bSum = 0, n = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let off = y * stride + x * 4          // BGRA
                bSum += Int(ptr[off])
                gSum += Int(ptr[off + 1])
                rSum += Int(ptr[off + 2])
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return SIMD3(1, 1, 1) }
        var rgb = SIMD3(Float(rSum) / Float(n) / 255,
                        Float(gSum) / Float(n) / 255,
                        Float(bSum) / Float(n) / 255)
        // 飽和度 ≥0.75、亮度 ≥0.85（HSV 下限，同 Android）
        rgb = Self.boostSaturation(rgb, minSat: 0.75, minVal: 0.85)
        return rgb
    }

    private static func boostSaturation(_ c: SIMD3<Float>, minSat: Float, minVal: Float) -> SIMD3<Float> {
        let maxc = max(c.x, max(c.y, c.z))
        let minc = min(c.x, min(c.y, c.z))
        var h: Float = 0
        let d = maxc - minc
        if d > 0 {
            if maxc == c.x      { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if maxc == c.y { h = (c.z - c.x) / d + 2 }
            else                { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        let s = max(maxc == 0 ? 0 : d / maxc, minSat)
        let v = max(maxc, minVal)
        // HSV → RGB
        let cc = v * s
        let x = cc * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - cc
        var rgb: SIMD3<Float>
        switch h {
        case ..<60:   rgb = SIMD3(cc, x, 0)
        case ..<120:  rgb = SIMD3(x, cc, 0)
        case ..<180:  rgb = SIMD3(0, cc, x)
        case ..<240:  rgb = SIMD3(0, x, cc)
        case ..<300:  rgb = SIMD3(x, 0, cc)
        default:      rgb = SIMD3(cc, 0, x)
        }
        return rgb + SIMD3(repeating: m)
    }

    private func updateFps() {
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFpsTime >= 1 {
            currentFps = Float(frameCount) / Float(now - lastFpsTime)
            frameCount = 0
            lastFpsTime = now
        }
    }
}
