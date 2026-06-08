import UIKit

enum InferenceHardware: String {
    case npu = "NPU"
    case gpu = "GPU"
    case cpu = "CPU"
    case mock = "MOCK"
}

enum EffectType: CaseIterable {
    case lightning, fire, stardust, wave, thunder, vortex, dark

    var emoji: String {
        switch self {
        case .lightning: return "⚡"
        case .fire:      return "🔥"
        case .stardust:  return "✨"
        case .wave:      return "🌊"
        case .thunder:   return "⛏️"
        case .vortex:    return "🌀"
        case .dark:      return "🌑"
        }
    }

    var displayName: String {
        switch self {
        case .lightning: return "閃電"
        case .fire:      return "火炎"
        case .stardust:  return "星塵"
        case .wave:      return "浪潮"
        case .thunder:   return "雷石"
        case .vortex:    return "漩渦"
        case .dark:      return "暗能"
        }
    }

    var description: String {
        switch self {
        case .lightning: return "電流閃動軌跡"
        case .fire:      return "炙熱火焰軌跡"
        case .stardust:  return "晶瑩散射軌跡"
        case .wave:      return "水波流動軌跡"
        case .thunder:   return "碰撞特效"
        case .vortex:    return "旋轉散落軌跡"
        case .dark:      return "暗黑能量軌跡"
        }
    }

    // nil = 使用相機偵測顏色
    var colorOverride: UIColor? {
        switch self {
        case .lightning: return UIColor(hex: 0x00F5FF)
        case .fire:      return UIColor(hex: 0xFF6B35)
        case .stardust:  return nil
        case .wave:      return UIColor(hex: 0x0088FF)
        case .thunder:   return UIColor(hex: 0xFFCC00)
        case .vortex:    return UIColor(hex: 0xBF5FFF)
        case .dark:      return UIColor(hex: 0x440066)
        }
    }

    var glowWidthMult: Float  { switch self { case .lightning: return 0.8; case .fire: return 1.5; case .stardust: return 0.5; case .wave: return 2.2; case .thunder: return 1.0; case .vortex: return 1.6; case .dark: return 0.7 } }
    var coreWidthMult: Float  { switch self { case .lightning: return 0.9; case .fire: return 1.0; case .stardust: return 0.6; case .wave: return 0.8; case .thunder: return 1.4; case .vortex: return 0.8; case .dark: return 0.5 } }
    var fadeDurationMs: Int64 { switch self { case .lightning: return 400; case .fire: return 600; case .stardust: return 280; case .wave: return 800; case .thunder: return 360; case .vortex: return 900; case .dark: return 1000 } }
    var isLocked: Bool        { switch self { case .lightning, .fire, .stardust: return false; default: return true } }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >>  8) & 0xFF) / 255,
            blue:  CGFloat( hex        & 0xFF) / 255,
            alpha: 1
        )
    }
}
