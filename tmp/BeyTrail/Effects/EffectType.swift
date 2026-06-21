import Foundation
import simd

/// 對應 Android EffectType — 8 種特效，含購買 / 下架 / 開發白名單機制。
enum EffectType: String, CaseIterable, Identifiable {
    case lightning, fire, stardust, wave, thunder, vortex, dark, crimson

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .lightning: return "⚡"
        case .fire:      return "🔥"
        case .stardust:  return "✨"
        case .wave:      return "🌊"
        case .thunder:   return "🛡️"
        case .vortex:    return "⚔️"
        case .dark:      return "🧊"
        case .crimson:   return "🌺"
        }
    }

    var displayName: String {
        switch self {
        case .lightning: return "閃電"
        case .fire:      return "火炎"
        case .stardust:  return "星塵"
        case .wave:      return "滔天浪潮"
        case .thunder:   return "不滅鋼盾"
        case .vortex:    return "爆刃亂舞"
        case .dark:      return "狂暴冰裂"
        case .crimson:   return "紅蓮破滅"
        }
    }

    var blurb: String {
        switch self {
        case .lightning: return "電流閃動軌跡"
        case .fire:      return "炙熱火焰軌跡"
        case .stardust:  return "晶瑩散射軌跡"
        case .wave:      return "水波流動軌跡"
        case .thunder:   return "防禦幾何能量盾"
        case .vortex:    return "斬擊刀光軌跡"
        case .dark:      return "冰封碎裂軌跡"
        case .crimson:   return "烈焰火舌軌跡"
        }
    }

    /// 固定色（nil = 抓陀螺中心偵測色）。對應 Android colorOverride。
    var colorOverride: SIMD3<Float>? {
        switch self {
        case .lightning: return SIMD3(1.00, 0.867, 0.133)   // 黃 0xFFDD22
        case .fire:      return SIMD3(1.00, 0.165, 0.071)   // 紅 0xFF2A12
        default:         return nil
        }
    }

    var glowWidthMult: Float {
        switch self {
        case .lightning: return 0.8
        case .fire:      return 1.5
        case .stardust:  return 0.5
        case .wave:      return 2.2
        case .thunder:   return 1.2
        case .vortex:    return 1.6
        case .dark:      return 0.7
        case .crimson:   return 1.5
        }
    }

    var coreWidthMult: Float {
        switch self {
        case .lightning: return 0.9
        case .fire:      return 1.0
        case .stardust:  return 0.6
        case .wave:      return 0.8
        case .thunder:   return 1.0
        case .vortex:    return 0.8
        case .dark:      return 0.5
        case .crimson:   return 1.0
        }
    }

    /// 尾跡淡出時間（秒）— 與 Android fadeDurationMs 一致
    var fadeDuration: TimeInterval {
        switch self {
        case .lightning: return 0.400
        case .fire:      return 0.600
        case .stardust:  return 0.280
        case .wave:      return 0.800
        case .thunder:   return 0.450
        case .vortex:    return 0.280
        case .dark:      return 0.800
        case .crimson:   return 0.600
        }
    }

    /// nil = 免費；否則為 App Store Connect 商品 ID（與 Play 一致）
    var productId: String? {
        switch self {
        case .lightning, .fire, .stardust: return nil
        case .wave:    return "waveeffect"
        case .thunder: return "thundereffect"
        case .vortex:  return "vortexeffect"
        case .dark:    return "darkeffect"
        case .crimson: return "crimsonlotus"
        }
    }

    // ── 購買 / 下架 / 測試白名單（對應 Android 機制） ─────────────────

    /// StoreManager 查到購買後更新
    static var ownedProductIds: Set<String> = []

    /// 已下架：商店購買區不顯示，已購者照常使用（出新版上架時移除）
    static let delistedProductIds: Set<String> = ["crimsonlotus"]

    /// ⚠️ 開發測試白名單：視為已購買。出任何 release 前必須清空。
    static let devUnlockedProductIds: Set<String> = ["crimsonlotus"]

    var locked: Bool {
        guard let id = productId else { return false }
        return !EffectType.ownedProductIds.contains(id)
            && !EffectType.devUnlockedProductIds.contains(id)
    }

    var delisted: Bool {
        guard let id = productId else { return false }
        return EffectType.delistedProductIds.contains(id)
    }

    static let bundleProductId = "bundleeffects"
    static let bundleIncludes: Set<String> =
        ["waveeffect", "thundereffect", "vortexeffect", "darkeffect"]
}
