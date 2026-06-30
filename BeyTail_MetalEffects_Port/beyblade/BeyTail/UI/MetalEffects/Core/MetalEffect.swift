import Foundation

/// Retains the Android Pair.first / Pair.second access pattern used by the
/// original Kotlin effect algorithms.
typealias MetalTrailSample = (first: TrailPoint, second: Float)
typealias MetalTrackData = [Int: [MetalTrailSample]]

/// Base class for every Metal trail effect.
class MetalEffect {
    private(set) var isMetalReady = false

    final func prepareIfNeeded(context: MetalRenderContext) {
        guard !isMetalReady else { return }
        onMetalReady(context: context)
        isMetalReady = true
    }

    func onMetalReady(context: MetalRenderContext) {
        // Subclass hook.
    }

    func draw(
        trackData: MetalTrackData,
        context: MetalRenderContext,
        effectType: EffectType
    ) {
        // Subclass hook.
    }

    func reset() {
        // Subclass hook.
    }
}
