import Foundation

/// Centralized effect selection. Every uploaded Android effect has a one-to-one Swift class.
enum GLEffectFactory {
  static func makeEffect(for type: EffectType) -> GLEffect {
    switch type {
    case .wave:
      return WaveGLEffect()
    case .thunder:
      return MoneyGLEffect()
    case .vortex:
      return BladeGLEffect()
    case .dark:
      return IceShatterGLEffect()
    case .crimson:
      return CrimsonLotusGLEffect()
    case .deathRay:
      return DeathRayGLEffect()
    case .emerald:
      return EmeraldGLEffect()
    case .inkWash:
      return InkWashGLEffect()
    case .spray:
      return SprayPaintGLEffect()
    case .lightning, .fire, .stardust:
      return GenericGLEffect()
    }
  }
}
