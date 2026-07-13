import UIKit

enum InferenceHardware: String {
    case npu = "NPU"
    case gpu = "GPU"
    case cpu = "CPU"
    case mock = "MOCK"
}

enum EffectType: String, CaseIterable, Identifiable, Sendable {
    case lightning
    case fire
    case stardust
    case wave
    case thunder
    case vortex
    case dark
    case crimson
    case deathRay
    case emerald
    case inkWash
    case spray

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .lightning: return "⚡"
        case .fire: return "🔥"
        case .stardust: return "✨"
        case .wave: return "🌊"
        case .thunder: return "💰"
        case .vortex: return "⚔️"
        case .dark: return "🧊"
        case .crimson: return "🌺"
        case .deathRay: return "🔆"
        case .emerald: return "🍃"
        case .inkWash: return "🖌️"
        case .spray: return "🎨"
        }
    }

    var displayName: String {
        switch self {
        case .lightning: return "閃電"
        case .fire: return "火炎"
        case .stardust: return "星塵"
        case .wave: return "滔天浪潮"
        case .thunder: return "金錢衝擊"
        case .vortex: return "爆刃亂舞"
        case .dark: return "狂暴冰裂"
        case .crimson: return "紅蓮破滅"
        case .deathRay: return "破壞死光"
        case .emerald: return "翡翠破壞"
        case .inkWash: return "水墨橫空"
        case .spray: return "噴漆塗鴉"
        }
    }

    var description: String {
        switch self {
        case .lightning: return "電流閃動軌跡"
        case .fire: return "炙熱火焰軌跡"
        case .stardust: return "晶瑩散射軌跡"
        case .wave: return "水波流動軌跡"
        case .thunder: return "黃金噴錢衝擊"
        case .vortex: return "斬擊刀光軌跡"
        case .dark: return "冰封碎裂軌跡"
        case .crimson: return "烈焰火舌軌跡"
        case .deathRay: return "湮滅死光光柱"
        case .emerald: return "神木葉刃軌跡"
        case .inkWash: return "飛白乾墨軌跡"
        case .spray: return "鮮豔噴漆潑濺"
        }
    }

    var fallbackPrice: Int { isDefaultOwned ? 0 : 40 }
    var price: Int { fallbackPrice }

    var isDefaultOwned: Bool {
        switch self {
        case .lightning, .fire, .stardust:
            return true
        default:
            return false
        }
    }

    var requiresPurchase: Bool { !isDefaultOwned }
    var isLocked: Bool { requiresPurchase }

    var productID: String? {
        switch self {
        case .lightning, .fire, .stardust:
            return nil
        case .wave:
            return StoreProductID.wave
        case .thunder:
            return StoreProductID.moneyImpact
        case .vortex:
            return StoreProductID.bladeDance
        case .dark:
            return StoreProductID.iceBreak
        case .crimson:
            return StoreProductID.crimsonLotus
        case .deathRay:
            return StoreProductID.deathRay
        case .emerald:
            return StoreProductID.emerald
        case .inkWash:
            return StoreProductID.inkWash
        case .spray:
            return StoreProductID.sprayPaint
        }
    }

    static let premiumPackProductID = StoreProductID.premiumPack

    /// 限定特效包只包含這四個特效。
    static let premiumPackEffects: [EffectType] = [
        .wave,
        .thunder,
        .vortex,
        .dark
    ]

    static let premiumPackEffectSet = Set(premiumPackEffects)

    var isIncludedInPremiumPack: Bool {
        Self.premiumPackEffectSet.contains(self)
    }

    static var allProductIDs: Set<String> {
        individualProductIDs.union([premiumPackProductID])
    }

    static var individualProductIDs: Set<String> {
        Set(shopEffects.compactMap(\.productID))
    }

    static var defaultOwnedEffects: [EffectType] {
        [.lightning, .fire, .stardust]
    }

    static var defaultMenuEffects: [EffectType] {
        defaultOwnedEffects
    }

    static var shopEffects: [EffectType] {
        [
            .wave,
            .thunder,
            .vortex,
            .dark,
            .crimson,
            .deathRay,
            .emerald,
            .inkWash,
            .spray
        ]
    }

    static var ownedFallbackEffects: [EffectType] {
        defaultOwnedEffects
    }

    var colorOverride: UIColor? {
        switch self {
        case .lightning: return UIColor(hex: 0xFFDD22)
        case .fire: return UIColor(hex: 0xFF2A12)
        case .stardust: return nil
        case .wave: return UIColor(hex: 0x168CFF)
        case .thunder: return UIColor(hex: 0xFFD34E)
        case .vortex: return UIColor(hex: 0xD8E2EA)
        case .dark: return UIColor(hex: 0x9DEBFF)
        case .crimson: return UIColor(hex: 0xC9082E)
        case .deathRay: return UIColor(hex: 0xA54CFF)
        case .emerald: return UIColor(hex: 0x24D77A)
        case .inkWash: return UIColor(white: 0.04, alpha: 1)
        case .spray: return nil
        }
    }

    var glowWidthMult: Float {
        switch self {
        case .lightning: return 0.9
        case .fire: return 1.5
        case .stardust: return 0.6
        case .wave: return 2.2
        case .thunder: return 1.6
        case .vortex: return 1.7
        case .dark: return 1.9
        case .crimson: return 2.4
        case .deathRay: return 2.8
        case .emerald: return 1.6
        case .inkWash: return 2.2
        case .spray: return 2.0
        }
    }

    var coreWidthMult: Float {
        switch self {
        case .lightning: return 0.9
        case .fire: return 1.0
        case .stardust: return 0.6
        case .wave: return 0.9
        case .thunder: return 1.2
        case .vortex: return 0.8
        case .dark: return 0.8
        case .crimson: return 1.1
        case .deathRay: return 1.4
        case .emerald: return 0.9
        case .inkWash: return 1.2
        case .spray: return 1.0
        }
    }

    var fadeDurationMs: Int64 {
        trailRenderProfile.lengthMs
    }
}

private enum StoreProductID {
    static let wave =
        "com.ahher0893.beyblade.effect.wave"
    static let moneyImpact =
        "com.ahher0893.beyblade.effect.money_impact"
    static let bladeDance =
        "com.ahher0893.beyblade.effect.blade_dance"
    static let iceBreak =
        "com.ahher0893.beyblade.effect.ice_break"
    static let crimsonLotus =
        "com.ahher0893.beyblade.effect.crimson_lotus"
    static let deathRay =
        "com.ahher0893.beyblade.effect.death_ray"
    static let emerald =
        "com.ahher0893.beyblade.effect.emerald"
    static let inkWash =
        "com.ahher0893.beyblade.effect.ink_wash"
    static let sprayPaint =
        "com.ahher0893.beyblade.effect.spray_paint"
    static let premiumPack =
        "com.ahher0893.beyblade.effects.premium_pack"
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
