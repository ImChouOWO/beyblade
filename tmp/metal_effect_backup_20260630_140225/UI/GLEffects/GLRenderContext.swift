import UIKit

final class GLRenderContext {
  var viewWidth: Int = 1
  var viewHeight: Int = 1

  /// Android uses these when the video quad is letterboxed/cropped.
  /// MainViewModel already maps points into the overlay coordinate space,
  /// therefore both remain 1 in the iOS overlay.
  var quadScaleX: Float = 1
  var quadScaleY: Float = 1

  /// 1.0 means a 30 FPS update. 60 FPS frames use about 0.5.
  var dtScale: Float = 1

  /// Shared ribbon scratch storage. 256 KiB is enough for all uploaded effects.
  let ribbonFloats = GLFloatBuffer(capacity: 65_536)

  var minDimension: Float {
    Float(min(viewWidth, viewHeight))
  }

  func update(size: CGSize, deltaTime: CFTimeInterval) {
    viewWidth = max(Int(size.width.rounded()), 1)
    viewHeight = max(Int(size.height.rounded()), 1)
    dtScale = Float(max(min(deltaTime * 30.0, 3.0), 0.1))
  }
}
