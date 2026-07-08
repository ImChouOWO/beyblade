import OpenGLES
import UIKit

/// Named tuple preserves the Android `Pair.first / Pair.second` semantics.
typealias GLTrailSample = (first: TrailPoint, second: Float)
typealias GLTrackData = [Int: [GLTrailSample]]

/// Base class corresponding to Android `GLEffect`.
class GLEffect {
  private(set) var isGLReady = false

  final func prepareIfNeeded(context: GLRenderContext) {
    guard !isGLReady else { return }
    onGLReady(context: context)
    isGLReady = true
  }

  func onGLReady(context: GLRenderContext) {
    // Subclass hook.
  }

  func draw(
    trackData: GLTrackData,
    context: GLRenderContext,
    effectType: EffectType
  ) {
    // Subclass hook.
  }

  func reset() {
    // Subclass hook.
  }
}
