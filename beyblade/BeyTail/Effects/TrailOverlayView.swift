import UIKit

// 對應 Android TrailOverlayView.kt
// 透明疊加層，用 Core Graphics 畫軌跡光帶
class TrailOverlayView: UIView {

    var effectEngine: TrailEffectEngine?
    var currentEffect: EffectType = .lightning

    // Debug 辨識框（debug 模式才顯示）
    var debugBoundingBoxes: [(CGRect, Int)] = [] {
        didSet { setNeedsDisplay() }
    }

    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
        startDisplayLink()
    }

    private func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let engine = effectEngine else { return }

        let now = CACurrentMediaTime()
        let trackData = engine.getPointsByTrack(now: now)

        for (_, pointsWithAlpha) in trackData {
            drawTrail(ctx: ctx, points: pointsWithAlpha, rect: rect)
        }

        // Debug bounding boxes
        ctx.setStrokeColor(UIColor.green.cgColor)
        ctx.setLineWidth(2)
        for (normRect, _) in debugBoundingBoxes {
            let screenRect = CGRect(
                x: normRect.minX * rect.width,
                y: normRect.minY * rect.height,
                width: normRect.width * rect.width,
                height: normRect.height * rect.height
            )
            ctx.stroke(screenRect)
        }
    }

    private func drawTrail(ctx: CGContext, points: [(TrailPoint, Float)], rect: CGRect) {
        guard points.count >= 2 else { return }

        let glowW  = CGFloat(14 * currentEffect.glowWidthMult)
        let coreW  = CGFloat(4  * currentEffect.coreWidthMult)

        for i in 1 ..< points.count {
            let (p0, a0) = points[i - 1]
            let (p1, a1) = points[i]
            let alpha = CGFloat((a0 + a1) / 2)

            let from = CGPoint(x: p0.center.x * rect.width,  y: p0.center.y * rect.height)
            let to   = CGPoint(x: p1.center.x * rect.width,  y: p1.center.y * rect.height)

            let trailColor = currentEffect.colorOverride ?? p1.color

            // Glow layer
            ctx.setStrokeColor(trailColor.withAlphaComponent(alpha * 0.35).cgColor)
            ctx.setLineWidth(glowW)
            ctx.setLineCap(.round)
            ctx.move(to: from); ctx.addLine(to: to)
            ctx.strokePath()

            // Core layer
            ctx.setStrokeColor(trailColor.withAlphaComponent(alpha * 0.9).cgColor)
            ctx.setLineWidth(coreW)
            ctx.move(to: from); ctx.addLine(to: to)
            ctx.strokePath()
        }
    }
}
