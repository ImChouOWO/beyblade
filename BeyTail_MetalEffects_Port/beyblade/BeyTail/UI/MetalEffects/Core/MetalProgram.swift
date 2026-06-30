import Foundation

// MARK: - Lightweight compatibility vocabulary
// These constants describe primitive/blend semantics only. No OpenGL API is
// imported or called anywhere in the Metal implementation.
typealias MetalProgramID = UInt32
typealias MetalLocation = Int32
typealias MetalPrimitiveCode = UInt32

let MGL_POINTS: MetalPrimitiveCode = 0x0000
let MGL_LINES: MetalPrimitiveCode = 0x0001
let MGL_LINE_STRIP: MetalPrimitiveCode = 0x0003
let MGL_TRIANGLES: MetalPrimitiveCode = 0x0004
let MGL_TRIANGLE_STRIP: MetalPrimitiveCode = 0x0005

let MGL_ONE: MetalPrimitiveCode = 1
let MGL_SRC_ALPHA: MetalPrimitiveCode = 0x0302
let MGL_ONE_MINUS_SRC_ALPHA: MetalPrimitiveCode = 0x0303

enum MetalBlendMode: UInt32 {
    case alpha = 0
    case additive = 1
}

enum MetalShaderKind: UInt32, CaseIterable {
    case flatColor = 1
    case blade
    case crimsonFire
    case crimsonPolygon
    case crimsonHaze
    case deathBeam
    case deathPoint
    case emeraldVine
    case leaf
    case iceRibbon
    case iceBlade
    case iceFog
    case ink
    case inkDrop
    case gold
    case coin
    case sprayPaint
    case splat
    case waveFluid
    case waveTrail
    case waveParticle

    var isPointShader: Bool {
        switch self {
        case .crimsonHaze, .deathPoint, .iceFog, .inkDrop, .splat, .waveParticle:
            return true
        default:
            return false
        }
    }

    var programID: MetalProgramID { rawValue }
}

enum MetalAttributeSemantic: MetalLocation {
    case position = 0
    case color = 1
    case centerDistance = 2
    case trailDistance = 3
    case size = 4
    case uv = 5
    case extra = 6
}

enum MetalUniformSemantic: MetalLocation {
    case time = 0
    case strandAlpha = 1
    case tint = 2
}

/// The original effect classes use a stateful immediate-mode style. This
/// runtime points those small compatibility calls at the active Metal encoder.
private final class MetalRuntimeBox: NSObject {
    weak var context: MetalRenderContext?
}

/// Per-thread current encoder state. Live preview and background video
/// compositing can therefore render concurrently without sharing GL-style
/// mutable state.
enum MetalRuntime {
    private static let threadKey =
        "com.beytail.metal-effects.current-context"

    static var current: MetalRenderContext? {
        get {
            (Thread.current.threadDictionary[threadKey] as? MetalRuntimeBox)?
                .context
        }
        set {
            if let newValue {
                let box = MetalRuntimeBox()
                box.context = newValue
                Thread.current.threadDictionary[threadKey] = box
            } else {
                Thread.current.threadDictionary.removeObject(
                    forKey: threadKey
                )
            }
        }
    }
}

@inline(__always)
func metalGetAttribLocation(
    _ program: MetalProgramID,
    _ name: String
) -> MetalLocation {
    _ = program
    switch name {
    case "aPosition": return MetalAttributeSemantic.position.rawValue
    case "aColor": return MetalAttributeSemantic.color.rawValue
    case "aCenterDist": return MetalAttributeSemantic.centerDistance.rawValue
    case "aTrailDist": return MetalAttributeSemantic.trailDistance.rawValue
    case "aSize": return MetalAttributeSemantic.size.rawValue
    case "aUV": return MetalAttributeSemantic.uv.rawValue
    case "aDissolve", "aSeed": return MetalAttributeSemantic.extra.rawValue
    default: return -1
    }
}

@inline(__always)
func metalGetUniformLocation(
    _ program: MetalProgramID,
    _ name: String
) -> MetalLocation {
    _ = program
    switch name {
    case "uTime": return MetalUniformSemantic.time.rawValue
    case "uStrandAlpha": return MetalUniformSemantic.strandAlpha.rawValue
    case "uTint": return MetalUniformSemantic.tint.rawValue
    default: return -1
    }
}

@inline(__always)
func metalUseProgram(_ program: MetalProgramID) {
    guard let kind = MetalShaderKind(rawValue: program) else { return }
    MetalRuntime.current?.currentShader = kind
}

@inline(__always)
func metalUniform1f(_ location: MetalLocation, _ value: Float) {
    guard let semantic = MetalUniformSemantic(rawValue: location) else { return }
    switch semantic {
    case .time:
        MetalRuntime.current?.timeUniform = value
    case .strandAlpha:
        MetalRuntime.current?.strandAlphaUniform = value
    case .tint:
        break
    }
}

@inline(__always)
func metalUniform3f(
    _ location: MetalLocation,
    _ x: Float,
    _ y: Float,
    _ z: Float
) {
    guard MetalUniformSemantic(rawValue: location) == .tint else { return }
    MetalRuntime.current?.tintUniform = SIMD3<Float>(x, y, z)
}

@inline(__always)
func metalBlendFunc(
    _ source: MetalPrimitiveCode,
    _ destination: MetalPrimitiveCode
) {
    if source == MGL_SRC_ALPHA && destination == MGL_ONE {
        MetalRuntime.current?.blendMode = .additive
    } else {
        MetalRuntime.current?.blendMode = .alpha
    }
}

@inline(__always)
func metalLineWidth(_ width: Float) {
    MetalRuntime.current?.lineWidth = max(width, 1)
}
