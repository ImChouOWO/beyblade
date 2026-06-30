import Foundation
import simd

enum PicRibbonStyle: Float {
    case generic = 0
    case lightning = 1
    case fire = 2
    case stardust = 3
    case wave = 4
    case money = 5
    case blade = 6
    case ice = 7
    case crimson = 8
    case deathRay = 9
    case emerald = 10
    case inkWash = 11
    case sprayPaint = 12
}

enum PicSpriteStyle: Float {
    case softCircle = 0
    case spark = 1
    case ring = 2
    case bubble = 3
    case coin = 4
    case blade = 5
    case shard = 6
    case fireball = 7
    case haze = 8
    case leaf = 9
    case inkDrop = 10
    case splat = 11
    case star = 12
    case solidTri = 13    // 多邊形 / streak 用：mask 恆 1，直接吃頂點色
}

struct PicUniforms {
    var viewportSize: SIMD2<Float>
    var time: Float
    var pixelScale: Float
}

struct PicRibbonVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var uv: SIMD2<Float>
    var style: Float
    var seed: Float
}

struct PicSpriteVertex {
    var center: SIMD2<Float>
    var corner: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var rotation: Float
    var style: Float
    var seed: Float
    var age: Float
}

struct PicDrawRange {
    let start: Int
    let count: Int
}

struct PicFrameGeometry {
    var ribbonVertices: [PicRibbonVertex] = []
    var ribbonRanges: [PicDrawRange] = []
    var spriteVertices: [PicSpriteVertex] = []

    var isEmpty: Bool {
        ribbonVertices.isEmpty && spriteVertices.isEmpty
    }
}
