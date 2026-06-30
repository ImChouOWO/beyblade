import Foundation

enum MetalEffectFactory {
    static func makeEffect(
        for type: EffectType
    ) -> MetalEffect {
        switch type {
        case .wave:
            return WaveMetalEffect()
        case .thunder:
            return MoneyMetalEffect()
        case .vortex:
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
        case .lightning, .fire, .stardust:
            return GenericMetalEffect()
        }
    }
}
