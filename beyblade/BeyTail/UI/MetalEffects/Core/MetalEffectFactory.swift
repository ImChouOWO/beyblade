import Foundation

enum MetalEffectFactory {
    static func makeEffect(
        for type: EffectType
    ) -> MetalEffect {
        switch type {
        case .lightning,
             .fire,
             .stardust:
            // 三個基礎特效只使用通用純軌跡 renderer。
            return GenericMetalEffect()

        case .wave:
            return WaveMetalEffect()

        case .thunder:
            return MoneyMetalEffect()

        case .vortex:
            // 只有爆刃亂舞可以使用劍刃粒子。
            return BladeMetalEffect()

        case .dark:
            return IceShatterMetalEffect()

        case .crimson:
            return CrimsonLotusMetalEffect()

        case .deathRay:
            return DeathRayMetalEffect()

        case .emerald:
            return EmeraldMetalEffect()

        case .inkWash:
            return InkWashMetalEffect()

        case .spray:
            return SprayPaintMetalEffect()
        }
    }
}
