import UIKit

// Keeps MainViewModel and ContentView unchanged while switching the renderer
// from the deprecated OpenGL ES/GLKView implementation to Metal/MTKView.
typealias TrailOverlayView = MetalTrailOverlayView
