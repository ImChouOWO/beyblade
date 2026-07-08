import Foundation

/// 每個特效共用的拖尾渲染參數。
///
/// - widthMultiplier：相對於各 MetalEffect 原始寬度的倍率。
/// - lengthMs：軌跡點保留時間；數值越大，畫面上的拖尾越長。
struct TrailRenderProfile: Sendable {
  let widthMultiplier: Float
  let lengthMs: Int64
}

/// 所有特效的拖尾寬度與長度集中設定。
///
/// 目前依需求將全部特效寬度設為原始值的 1.25 倍。
/// 後續只需修改這個表，不必再進入各個 MetalEffect 檔案調整。
enum TrailRenderProfiles {
  static let values: [EffectType: TrailRenderProfile] = [
    .lightning: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 400),
    .fire: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 600),
    .stardust: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 280),
    .wave: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 800),
    .thunder: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 650),
    .vortex: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 320),
    .dark: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 800),
    .crimson: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 780),
    .deathRay: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 520),
    .emerald: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 720),
    .inkWash: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 900),
    .spray: TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 700),
  ]

  static func profile(for effect: EffectType) -> TrailRenderProfile {
    values[effect] ?? TrailRenderProfile(widthMultiplier: 1.25, lengthMs: 500)
  }
}

extension EffectType {
  var trailRenderProfile: TrailRenderProfile {
    TrailRenderProfiles.profile(for: self)
  }

  var trailWidthMultiplier: Float {
    trailRenderProfile.widthMultiplier
  }

  var trailLengthMs: Int64 {
    trailRenderProfile.lengthMs
  }
}
