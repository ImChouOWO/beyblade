import Foundation
import simd

enum InferenceHardware: String {
    case ane  = "[ANE]"    // Apple Neural Engine（對應 Android NPU）
    case gpu  = "[GPU]"
    case cpu  = "[CPU]"
    case mock = "[MOCK]"
}

/// 一筆偵測結果 — 座標皆為畫面正規化（0~1，y 向下）。
struct DetectionResult {
    /// 邊界框（x, y, w, h）正規化
    var boundingBox: SIMD4<Float>
    var confidence: Float
    var fps: Float = 0
    var hardware: InferenceHardware = .cpu
    var trackId: Int = 0
    /// 陀螺中心偵測色
    var dominantColor: SIMD3<Float> = SIMD3(1, 1, 1)

    var center: SIMD2<Float> {
        SIMD2(boundingBox.x + boundingBox.z / 2, boundingBox.y + boundingBox.w / 2)
    }
    var width: Float { boundingBox.z }
}
