import Foundation

/// 每個特效共用的渲染參數。
///
/// 保留 `TrailRenderProfile` 名稱以相容既有程式；內容已擴充為完整特效設定。
///
/// - widthMultiplier：主要拖尾／光束寬度倍率。
/// - lengthMs：軌跡點保留時間，數值越大拖尾越長。
/// - particleSizeMultiplier：粒子視覺尺寸倍率；0 代表不可見。
/// - particleFrequencyMultiplier：粒子生成密度倍率；0 代表停止生成。
struct TrailRenderProfile: Sendable {
  let widthMultiplier: Float
  let lengthMs: Int64
  let particleSizeMultiplier: Float
  let particleFrequencyMultiplier: Float

  static let fallback = TrailRenderProfile(
    widthMultiplier: 2,
    lengthMs: 500,
    particleSizeMultiplier: 1.5,
    particleFrequencyMultiplier: 1.0
  )
}

/// 所有特效的渲染設定集中於此。
///
/// 目前全部主要拖尾寬度均為原始值的 1.25 倍；粒子大小與頻率先維持原始值。
/// 後續只需修改這張表，不需進入個別 MetalEffect 檔案。
enum TrailRenderProfiles {
  static let values: [EffectType: TrailRenderProfile] = [
    .lightning: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 400,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .fire: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 600,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .stardust: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 280,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .wave: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 800,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .thunder: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 650,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .vortex: TrailRenderProfile(
        widthMultiplier: 2.5,
      lengthMs: 400,
        particleSizeMultiplier: 2.5,
      particleFrequencyMultiplier: 6
    ),
    .dark: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 800,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .crimson: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 780,
      particleSizeMultiplier: 3.5,
      particleFrequencyMultiplier: 3.0
    ),
    .deathRay: TrailRenderProfile(
        widthMultiplier: 1.1,
      lengthMs: 400,
      particleSizeMultiplier: 1.0,
      particleFrequencyMultiplier: 1.0
    ),
    .emerald: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 720,
      particleSizeMultiplier: 1.5,
      particleFrequencyMultiplier: 1.0
    ),
    .inkWash: TrailRenderProfile(
      widthMultiplier: 2.25,
      lengthMs: 900,
      particleSizeMultiplier: 2.5,
      particleFrequencyMultiplier: 1.5
    ),
    .spray: TrailRenderProfile(
      widthMultiplier: 2,
      lengthMs: 700,
      particleSizeMultiplier: 2 ,
      particleFrequencyMultiplier: 1.0
    ),
  ]

  static func profile(for effect: EffectType) -> TrailRenderProfile {
    values[effect] ?? .fallback
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
