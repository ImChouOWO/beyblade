import Foundation

enum MetalEffectFactory {
    static func makeEffect(
        for effectType: EffectType
    ) -> MetalEffect {
        let renderer: MetalEffect

        switch effectType {
        case .lightning,
             .fire,
             .stardust:
            // 三個基礎特效只使用純軌跡 renderer。
            renderer = GenericMetalEffect()

        case .wave:
            renderer = WaveMetalEffect()

        case .thunder:
            renderer = MoneyMetalEffect()

        case .vortex:
            // 只有爆刃亂舞使用 BladeMetalEffect。
            renderer = BladeMetalEffect()

        case .dark:
            renderer = IceShatterMetalEffect()

        case .crimson:
            renderer = CrimsonLotusMetalEffect()

        case .deathRay:
            renderer = DeathRayMetalEffect()

        case .emerald:
            renderer = EmeraldMetalEffect()

        case .inkWash:
            renderer = InkWashMetalEffect()

        case .spray:
            renderer = SprayPaintMetalEffect()
        }

        #if DEBUG
        print(
            "[MetalEffectFactory]",
            effectType.rawValue,
            "->",
            String(
                describing: Swift.type(of: renderer)
            )
        )
        #endif

        return renderer
    }
}
