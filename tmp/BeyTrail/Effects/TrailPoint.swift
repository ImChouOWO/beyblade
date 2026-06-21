import Foundation
import simd

/// 一個軌跡點 — center 為畫面正規化座標（0~1，y 向下，同 Android）。
struct TrailPoint {
    var center: SIMD2<Float>
    var timestamp: TimeInterval
    var trackId: Int
    /// 陀螺中心偵測色（線性 0~1 RGB）
    var color: SIMD3<Float>
}
