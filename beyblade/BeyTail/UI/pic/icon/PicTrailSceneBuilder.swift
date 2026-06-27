import UIKit
import simd

final class PicTrailSceneBuilder {

    private struct Sample {
        var position: SIMD2<Float>
        var alpha: Float
        var color: UIColor
        var timestamp: TimeInterval
    }

    func build(
        effect: EffectType,
        trackData: [Int: [(TrailPoint, Float)]],
        debugBoundingBoxes: [(CGRect, Int)],
        viewportSize: CGSize,
        now: TimeInterval
    ) -> PicFrameGeometry {
        var geometry = PicFrameGeometry()

        guard viewportSize.width > 1, viewportSize.height > 1 else {
            return geometry
        }

        for trackID in trackData.keys.sorted() {
            guard let points = trackData[trackID], points.count >= 2 else {
                continue
            }

            let samples = makeSamples(points, viewportSize: viewportSize)

            switch effect {
            case .lightning:
                buildLightning(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .fire:
                buildFire(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .stardust:
                buildStardust(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .wave:
                buildWave(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .thunder:
                buildMoney(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .vortex:
                buildBlade(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .dark:
                buildIce(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .crimson:
                buildCrimson(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .deathRay:
                buildDeathRay(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .emerald:
                buildEmerald(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .inkWash:
                buildInkWash(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )

            case .spray:
                buildSprayPaint(
                    samples,
                    trackID: trackID,
                    now: now,
                    geometry: &geometry
                )
            }
        }

        appendDebugBoxes(
            debugBoundingBoxes,
            viewportSize: viewportSize,
            geometry: &geometry
        )

        return geometry
    }

    // MARK: - Effect builders

    private func buildLightning(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let yellow = rgba(UIColor(hex: 0xFFDD22))
        let white = SIMD4<Float>(1, 1, 0.92, 1)

        appendRibbon(
            samples,
            width: 26,
            baseColor: yellow,
            usePointColor: false,
            style: .lightning,
            alphaScale: 0.22,
            wobble: 7,
            phase: Float(now * 18) + Float(trackID),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 9,
            baseColor: yellow,
            usePointColor: false,
            style: .lightning,
            alphaScale: 0.78,
            wobble: 4,
            phase: Float(now * 22) + Float(trackID) * 0.7,
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 2.5,
            baseColor: white,
            usePointColor: false,
            style: .lightning,
            alphaScale: 0.95,
            wobble: 2,
            phase: Float(now * 25),
            offset: 0,
            geometry: &geometry
        )

        for index in stride(from: 1, to: samples.count, by: 3) {
            let sample = samples[index]
            let seed = random01(trackID, index)
            let age = 1 - sample.alpha
            let angle = seed * .pi * 2
            let drift = age * 32
            let center = sample.position + unit(angle) * drift

            appendSprite(
                center: center,
                size: SIMD2(12 + seed * 11, 12 + seed * 11),
                color: withAlpha(white, sample.alpha * 0.85),
                style: .spark,
                rotation: angle + Float(now) * 2,
                seed: seed,
                age: age,
                geometry: &geometry
            )
        }
    }

    private func buildFire(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let red = rgba(UIColor(hex: 0xFF2A12))
        let orange = rgba(UIColor(hex: 0xFF9A24))
        let pale = rgba(UIColor(hex: 0xFFF1A8))

        appendRibbon(
            samples,
            width: 34,
            baseColor: red,
            usePointColor: false,
            style: .fire,
            alphaScale: 0.26,
            wobble: 6,
            phase: Float(now * 7),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 15,
            baseColor: orange,
            usePointColor: false,
            style: .fire,
            alphaScale: 0.72,
            wobble: 4,
            phase: Float(now * 10) + 1.7,
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 4,
            baseColor: pale,
            usePointColor: false,
            style: .fire,
            alphaScale: 0.8,
            wobble: 2,
            phase: Float(now * 12),
            offset: 0,
            geometry: &geometry
        )

        for index in stride(from: 1, to: samples.count, by: 2) {
            let sample = samples[index]
            let seed = random01(trackID * 13, index)
            let age = 1 - sample.alpha
            let center = sample.position + SIMD2(
                (seed - 0.5) * 26 * age,
                -age * (22 + seed * 38)
            )

            appendSprite(
                center: center,
                size: SIMD2(13 + seed * 15, 18 + seed * 22),
                color: withAlpha(
                    mix(red, orange, t: seed),
                    sample.alpha * 0.72
                ),
                style: .fireball,
                rotation: (seed - 0.5) * 0.8,
                seed: seed,
                age: age,
                geometry: &geometry
            )
        }
    }

    private func buildStardust(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        appendRibbon(
            samples,
            width: 14,
            baseColor: SIMD4(1, 1, 1, 1),
            usePointColor: true,
            style: .stardust,
            alphaScale: 0.30,
            wobble: 2,
            phase: Float(now * 5),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 3,
            baseColor: SIMD4(1, 1, 1, 1),
            usePointColor: true,
            style: .stardust,
            alphaScale: 0.88,
            wobble: 1,
            phase: Float(now * 8),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            guard index % 2 == 0 else { continue }

            let sample = samples[index]
            let seed = random01(trackID * 23, index)
            let age = 1 - sample.alpha
            let pointColor = rgba(sample.color)
            let angle = seed * .pi * 2
            let center = sample.position + unit(angle) * (8 + age * 30)

            appendSprite(
                center: center,
                size: SIMD2(repeating: 7 + seed * 13),
                color: withAlpha(
                    mix(pointColor, SIMD4(1, 1, 1, 1), t: 0.55),
                    sample.alpha * 0.9
                ),
                style: .star,
                rotation: Float(now) * 1.8 + angle,
                seed: seed,
                age: age,
                geometry: &geometry
            )
        }
    }

    private func buildWave(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let blue = rgba(UIColor(hex: 0x168CFF))
        let cyan = rgba(UIColor(hex: 0x8CEBFF))
        let white = SIMD4<Float>(1, 1, 1, 1)

        appendRibbon(
            samples,
            width: 40,
            baseColor: blue,
            usePointColor: true,
            style: .wave,
            alphaScale: 0.32,
            wobble: 8,
            phase: Float(now * 6),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 13,
            baseColor: cyan,
            usePointColor: false,
            style: .wave,
            alphaScale: 0.66,
            wobble: 5,
            phase: Float(now * 8) + 2.1,
            offset: -2,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 3,
            baseColor: white,
            usePointColor: false,
            style: .wave,
            alphaScale: 0.68,
            wobble: 3,
            phase: Float(now * 10),
            offset: -5,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 31, index)
            let age = 1 - sample.alpha

            if index % 2 == 0 {
                let angle = seed * .pi * 2
                let center = sample.position + unit(angle) * (8 + age * 26)

                appendSprite(
                    center: center,
                    size: SIMD2(repeating: 5 + seed * 9),
                    color: withAlpha(
                        mix(cyan, white, t: 0.35),
                        sample.alpha * 0.72
                    ),
                    style: .bubble,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }

            if index % 8 == 0 {
                appendSprite(
                    center: sample.position,
                    size: SIMD2(repeating: 24 + age * 88),
                    color: withAlpha(cyan, sample.alpha * 0.38),
                    style: .ring,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildMoney(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let deepGold = rgba(UIColor(hex: 0xB86B00))
        let gold = rgba(UIColor(hex: 0xFFD34E))
        let whiteGold = rgba(UIColor(hex: 0xFFF7C4))

        appendRibbon(
            samples,
            width: 29,
            baseColor: deepGold,
            usePointColor: false,
            style: .money,
            alphaScale: 0.25,
            wobble: 3,
            phase: Float(now * 5),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 10,
            baseColor: gold,
            usePointColor: false,
            style: .money,
            alphaScale: 0.82,
            wobble: 2,
            phase: Float(now * 8),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 2.5,
            baseColor: whiteGold,
            usePointColor: false,
            style: .money,
            alphaScale: 0.92,
            wobble: 1,
            phase: Float(now * 12),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 41, index)
            let age = 1 - sample.alpha

            if index % 3 == 0 {
                let angle = seed * .pi * 2
                let center = sample.position + SIMD2(
                    cos(angle) * (12 + age * 42),
                    sin(angle) * (12 + age * 28) + age * 18
                )

                appendSprite(
                    center: center,
                    size: SIMD2(16 + seed * 13, 10 + seed * 9),
                    color: withAlpha(gold, sample.alpha * 0.9),
                    style: .coin,
                    rotation: angle + Float(now) * (1.5 + seed),
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }

            if index % 9 == 0 {
                appendSprite(
                    center: sample.position,
                    size: SIMD2(repeating: 28 + age * 96),
                    color: withAlpha(gold, sample.alpha * 0.30),
                    style: .ring,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildBlade(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let steel = rgba(UIColor(hex: 0xD8E2EA))
        let blueSteel = rgba(UIColor(hex: 0x77C8FF))
        let white = SIMD4<Float>(1, 1, 1, 1)

        appendRibbon(
            samples,
            width: 31,
            baseColor: blueSteel,
            usePointColor: true,
            style: .blade,
            alphaScale: 0.22,
            wobble: 2.5,
            phase: Float(now * 9),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 9,
            baseColor: steel,
            usePointColor: false,
            style: .blade,
            alphaScale: 0.84,
            wobble: 1.4,
            phase: Float(now * 14),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 2,
            baseColor: white,
            usePointColor: false,
            style: .blade,
            alphaScale: 0.95,
            wobble: 0.5,
            phase: Float(now * 18),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 53, index)
            let age = 1 - sample.alpha
            let angle = seed * .pi * 2
            let center = sample.position + unit(angle) * (10 + age * 48)

            if index % 3 == 0 {
                appendSprite(
                    center: center,
                    size: SIMD2(22 + seed * 28, 5 + seed * 4),
                    color: withAlpha(steel, sample.alpha * 0.86),
                    style: .blade,
                    rotation: angle + Float(now) * 0.8,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            } else if index % 2 == 0 {
                appendSprite(
                    center: center,
                    size: SIMD2(repeating: 6 + seed * 10),
                    color: withAlpha(white, sample.alpha * 0.8),
                    style: .spark,
                    rotation: angle,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildIce(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let ice = rgba(UIColor(hex: 0x9DEBFF))
        let blue = rgba(UIColor(hex: 0x4EAAFF))
        let white = SIMD4<Float>(1, 1, 1, 1)

        appendRibbon(
            samples,
            width: 37,
            baseColor: blue,
            usePointColor: false,
            style: .ice,
            alphaScale: 0.22,
            wobble: 3,
            phase: Float(now * 5),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 13,
            baseColor: ice,
            usePointColor: false,
            style: .ice,
            alphaScale: 0.74,
            wobble: 2,
            phase: Float(now * 7),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 3,
            baseColor: white,
            usePointColor: false,
            style: .ice,
            alphaScale: 0.82,
            wobble: 1,
            phase: Float(now * 9),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 61, index)
            let age = 1 - sample.alpha
            let angle = seed * .pi * 2
            let center = sample.position + unit(angle) * (12 + age * 55)

            if index % 3 == 0 {
                appendSprite(
                    center: center,
                    size: SIMD2(9 + seed * 14, 18 + seed * 25),
                    color: withAlpha(
                        mix(ice, white, t: seed * 0.55),
                        sample.alpha * 0.84
                    ),
                    style: .shard,
                    rotation: angle + age * 2.4,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }

            if index % 8 == 0 {
                appendSprite(
                    center: sample.position + SIMD2(0, -age * 10),
                    size: SIMD2(repeating: 34 + age * 65),
                    color: withAlpha(ice, sample.alpha * 0.18),
                    style: .haze,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildCrimson(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let crimson = rgba(UIColor(hex: 0xC9082E))
        let orange = rgba(UIColor(hex: 0xFF5A18))
        let yellow = rgba(UIColor(hex: 0xFFE36B))

        appendRibbon(
            samples,
            width: 45,
            baseColor: crimson,
            usePointColor: false,
            style: .crimson,
            alphaScale: 0.28,
            wobble: 8,
            phase: Float(now * 7),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 18,
            baseColor: orange,
            usePointColor: false,
            style: .crimson,
            alphaScale: 0.78,
            wobble: 5,
            phase: Float(now * 10) + 1.1,
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 4,
            baseColor: yellow,
            usePointColor: false,
            style: .crimson,
            alphaScale: 0.9,
            wobble: 2,
            phase: Float(now * 13),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 71, index)
            let age = 1 - sample.alpha

            if index % 2 == 0 {
                let center = sample.position + SIMD2(
                    (seed - 0.5) * 42 * age,
                    -age * (30 + seed * 52)
                )

                appendSprite(
                    center: center,
                    size: SIMD2(16 + seed * 22, 22 + seed * 30),
                    color: withAlpha(
                        mix(crimson, orange, t: 0.45 + seed * 0.5),
                        sample.alpha * 0.88
                    ),
                    style: .fireball,
                    rotation: (seed - 0.5) * 0.8,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }

            if index % 7 == 0 {
                appendSprite(
                    center: sample.position,
                    size: SIMD2(repeating: 50 + age * 80),
                    color: withAlpha(crimson, sample.alpha * 0.15),
                    style: .haze,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildDeathRay(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let violet = rgba(UIColor(hex: 0x8A37FF))
        let magenta = rgba(UIColor(hex: 0xFF4DE3))
        let white = SIMD4<Float>(1, 1, 1, 1)

        appendRibbon(
            samples,
            width: 54,
            baseColor: violet,
            usePointColor: false,
            style: .deathRay,
            alphaScale: 0.20,
            wobble: 2,
            phase: Float(now * 4),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 22,
            baseColor: magenta,
            usePointColor: false,
            style: .deathRay,
            alphaScale: 0.72,
            wobble: 1.2,
            phase: Float(now * 8),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 5,
            baseColor: white,
            usePointColor: false,
            style: .deathRay,
            alphaScale: 0.98,
            wobble: 0.4,
            phase: Float(now * 13),
            offset: 0,
            geometry: &geometry
        )

        if let head = samples.last {
            let basePhase = Float(now.truncatingRemainder(dividingBy: 1.0))

            for ringIndex in 0..<3 {
                let phase = (basePhase + Float(ringIndex) / 3)
                    .truncatingRemainder(dividingBy: 1)
                let size = 26 + phase * 110

                appendSprite(
                    center: head.position,
                    size: SIMD2(repeating: size),
                    color: withAlpha(
                        mix(violet, magenta, t: Float(ringIndex) / 2),
                        (1 - phase) * 0.52
                    ),
                    style: .ring,
                    rotation: Float(now) + Float(ringIndex),
                    seed: Float(ringIndex) * 0.31,
                    age: phase,
                    geometry: &geometry
                )
            }
        }

        for index in stride(from: 0, to: samples.count, by: 5) {
            let sample = samples[index]
            let seed = random01(trackID * 83, index)
            let age = 1 - sample.alpha

            appendSprite(
                center: sample.position + unit(seed * .pi * 2) * (age * 25),
                size: SIMD2(repeating: 42 + age * 72),
                color: withAlpha(violet, sample.alpha * 0.14),
                style: .haze,
                rotation: 0,
                seed: seed,
                age: age,
                geometry: &geometry
            )
        }
    }

    private func buildEmerald(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let darkGreen = rgba(UIColor(hex: 0x0A6F42))
        let emerald = rgba(UIColor(hex: 0x24D77A))
        let lime = rgba(UIColor(hex: 0xB7FF77))

        appendRibbon(
            samples,
            width: 32,
            baseColor: darkGreen,
            usePointColor: false,
            style: .emerald,
            alphaScale: 0.26,
            wobble: 5,
            phase: Float(now * 4),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 10,
            baseColor: emerald,
            usePointColor: false,
            style: .emerald,
            alphaScale: 0.78,
            wobble: 3,
            phase: Float(now * 6),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 2,
            baseColor: lime,
            usePointColor: false,
            style: .emerald,
            alphaScale: 0.9,
            wobble: 1.5,
            phase: Float(now * 9),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 97, index)
            let age = 1 - sample.alpha

            if index % 3 == 0 {
                let angle = seed * .pi * 2
                let center = sample.position + unit(angle) * (10 + age * 42)

                appendSprite(
                    center: center,
                    size: SIMD2(12 + seed * 14, 22 + seed * 22),
                    color: withAlpha(
                        mix(emerald, lime, t: seed * 0.45),
                        sample.alpha * 0.88
                    ),
                    style: .leaf,
                    rotation: angle + age * 2,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }

            if index % 10 == 0 {
                appendSprite(
                    center: sample.position,
                    size: SIMD2(repeating: 20 + age * 76),
                    color: withAlpha(emerald, sample.alpha * 0.28),
                    style: .ring,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    private func buildInkWash(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        let ink = SIMD4<Float>(0.025, 0.025, 0.035, 1)
        let gray = SIMD4<Float>(0.36, 0.37, 0.40, 1)

        appendRibbon(
            samples,
            width: 43,
            baseColor: ink,
            usePointColor: false,
            style: .inkWash,
            alphaScale: 0.68,
            wobble: 10,
            phase: Float(now * 1.2) + Float(trackID),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 16,
            baseColor: gray,
            usePointColor: false,
            style: .inkWash,
            alphaScale: 0.45,
            wobble: 7,
            phase: Float(now * 1.5) + 2.4,
            offset: -7,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 7,
            baseColor: ink,
            usePointColor: false,
            style: .inkWash,
            alphaScale: 0.88,
            wobble: 4,
            phase: Float(now * 1.8) + 4.1,
            offset: 8,
            geometry: &geometry
        )

        for index in samples.indices {
            guard index % 3 == 0 else { continue }

            let sample = samples[index]
            let seed = random01(trackID * 101, index)
            let age = 1 - sample.alpha
            let center = sample.position + SIMD2(
                (seed - 0.5) * 44 * age,
                age * (8 + seed * 30)
            )

            appendSprite(
                center: center,
                size: SIMD2(repeating: 12 + seed * 24 + age * 18),
                color: withAlpha(
                    mix(ink, gray, t: seed * 0.25),
                    sample.alpha * 0.72
                ),
                style: .inkDrop,
                rotation: seed * .pi * 2,
                seed: seed,
                age: age,
                geometry: &geometry
            )
        }
    }

    private func buildSprayPaint(
        _ samples: [Sample],
        trackID: Int,
        now: TimeInterval,
        geometry: inout PicFrameGeometry
    ) {
        appendRibbon(
            samples,
            width: 39,
            baseColor: SIMD4(1, 1, 1, 1),
            usePointColor: true,
            style: .sprayPaint,
            alphaScale: 0.38,
            wobble: 8,
            phase: Float(now * 4),
            offset: 0,
            geometry: &geometry
        )

        appendRibbon(
            samples,
            width: 11,
            baseColor: SIMD4(1, 1, 1, 1),
            usePointColor: true,
            style: .sprayPaint,
            alphaScale: 0.82,
            wobble: 4,
            phase: Float(now * 7),
            offset: 0,
            geometry: &geometry
        )

        for index in samples.indices {
            let sample = samples[index]
            let seed = random01(trackID * 113, index)
            let age = 1 - sample.alpha
            let source = rgba(sample.color)
            let vivid = vividColor(source, seed: seed)
            let angle = seed * .pi * 2
            let center = sample.position + unit(angle) * (8 + age * 46)

            if index % 3 == 0 {
                appendSprite(
                    center: center,
                    size: SIMD2(repeating: 18 + seed * 28),
                    color: withAlpha(vivid, sample.alpha * 0.82),
                    style: .splat,
                    rotation: angle,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            } else if index % 2 == 0 {
                appendSprite(
                    center: center,
                    size: SIMD2(repeating: 5 + seed * 9),
                    color: withAlpha(vivid, sample.alpha * 0.58),
                    style: .softCircle,
                    rotation: 0,
                    seed: seed,
                    age: age,
                    geometry: &geometry
                )
            }
        }
    }

    // MARK: - Geometry

    private func makeSamples(
        _ points: [(TrailPoint, Float)],
        viewportSize: CGSize
    ) -> [Sample] {
        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)

        return points.map { point, alpha in
            Sample(
                position: SIMD2(
                    Float(point.center.x) * width,
                    Float(point.center.y) * height
                ),
                alpha: clamp(alpha, 0, 1),
                color: point.color,
                timestamp: point.timestamp
            )
        }
    }

    private func appendRibbon(
        _ samples: [Sample],
        width: Float,
        baseColor: SIMD4<Float>,
        usePointColor: Bool,
        style: PicRibbonStyle,
        alphaScale: Float,
        wobble: Float,
        phase: Float,
        offset: Float,
        geometry: inout PicFrameGeometry
    ) {
        guard samples.count >= 2 else { return }

        let start = geometry.ribbonVertices.count
        let positions = samples.map(\.position)
        var cumulative = [Float](repeating: 0, count: samples.count)

        for index in 1..<positions.count {
            cumulative[index] = cumulative[index - 1]
                + simd_length(positions[index] - positions[index - 1])
        }

        let totalLength = max(cumulative.last ?? 1, 1)

        for index in samples.indices {
            let normal = averagedNormal(positions, index: index)
            let alpha = samples[index].alpha
            let trailT = cumulative[index] / totalLength
            let animated = sin(
                Float(index) * 1.73
                    + trailT * 11.4
                    + phase
            )
            let displaced = positions[index]
                + normal * (offset + animated * wobble * (0.35 + alpha * 0.65))

            let halfWidth = width * 0.5 * (0.34 + alpha * 0.66)
            var color = usePointColor
                ? rgba(samples[index].color)
                : baseColor
            color.w *= alpha * alphaScale

            geometry.ribbonVertices.append(
                PicRibbonVertex(
                    position: displaced - normal * halfWidth,
                    color: color,
                    uv: SIMD2(-1, trailT),
                    style: style.rawValue,
                    seed: phase * 0.071 + Float(index) * 0.013
                )
            )

            geometry.ribbonVertices.append(
                PicRibbonVertex(
                    position: displaced + normal * halfWidth,
                    color: color,
                    uv: SIMD2(1, trailT),
                    style: style.rawValue,
                    seed: phase * 0.071 + Float(index) * 0.013
                )
            )
        }

        geometry.ribbonRanges.append(
            PicDrawRange(
                start: start,
                count: geometry.ribbonVertices.count - start
            )
        )
    }

    private func appendSprite(
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        color: SIMD4<Float>,
        style: PicSpriteStyle,
        rotation: Float,
        seed: Float,
        age: Float,
        geometry: inout PicFrameGeometry
    ) {
        let corners: [SIMD2<Float>] = [
            SIMD2(-1, -1),
            SIMD2(1, -1),
            SIMD2(-1, 1),
            SIMD2(-1, 1),
            SIMD2(1, -1),
            SIMD2(1, 1)
        ]

        for corner in corners {
            geometry.spriteVertices.append(
                PicSpriteVertex(
                    center: center,
                    corner: corner,
                    size: size,
                    color: color,
                    rotation: rotation,
                    style: style.rawValue,
                    seed: seed,
                    age: age
                )
            )
        }
    }

    private func appendDebugBoxes(
        _ boxes: [(CGRect, Int)],
        viewportSize: CGSize,
        geometry: inout PicFrameGeometry
    ) {
        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)
        let green = SIMD4<Float>(0.1, 1, 0.2, 1)

        for (rect, trackID) in boxes {
            let minX = Float(rect.minX) * width
            let minY = Float(rect.minY) * height
            let maxX = Float(rect.maxX) * width
            let maxY = Float(rect.maxY) * height

            let points = [
                SIMD2(minX, minY),
                SIMD2(maxX, minY),
                SIMD2(maxX, maxY),
                SIMD2(minX, maxY),
                SIMD2(minX, minY)
            ]

            let samples = points.map {
                Sample(
                    position: $0,
                    alpha: 1,
                    color: .green,
                    timestamp: 0
                )
            }

            appendRibbon(
                samples,
                width: 2,
                baseColor: green,
                usePointColor: false,
                style: .generic,
                alphaScale: 0.95,
                wobble: 0,
                phase: Float(trackID),
                offset: 0,
                geometry: &geometry
            )
        }
    }

    // MARK: - Math and color

    private func averagedNormal(
        _ positions: [SIMD2<Float>],
        index: Int
    ) -> SIMD2<Float> {
        let tangent: SIMD2<Float>

        if index == 0 {
            tangent = positions[1] - positions[0]
        } else if index == positions.count - 1 {
            tangent = positions[index] - positions[index - 1]
        } else {
            tangent = positions[index + 1] - positions[index - 1]
        }

        let length = max(simd_length(tangent), 0.0001)
        let unitTangent = tangent / length
        return SIMD2(-unitTangent.y, unitTangent.x)
    }

    private func unit(_ angle: Float) -> SIMD2<Float> {
        SIMD2(cos(angle), sin(angle))
    }

    private func random01(_ a: Int, _ b: Int) -> Float {
        var value = UInt32(truncatingIfNeeded: a)
            &* 747_796_405
            &+ UInt32(truncatingIfNeeded: b)
            &* 2_891_336_453
            &+ 2_772_803_943

        value = (value ^ (value >> 16)) &* 2_246_822_519
        value = (value ^ (value >> 13)) &* 3_266_489_917
        value ^= value >> 16

        return Float(value & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    private func rgba(_ color: UIColor) -> SIMD4<Float> {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1

        if !color.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) {
            var white: CGFloat = 1
            color.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }

        return SIMD4(
            Float(red),
            Float(green),
            Float(blue),
            Float(alpha)
        )
    }

    private func withAlpha(
        _ color: SIMD4<Float>,
        _ alpha: Float
    ) -> SIMD4<Float> {
        var output = color
        output.w = clamp(alpha, 0, 1)
        return output
    }

    private func mix(
        _ lhs: SIMD4<Float>,
        _ rhs: SIMD4<Float>,
        t: Float
    ) -> SIMD4<Float> {
        let amount = clamp(t, 0, 1)
        return lhs + (rhs - lhs) * amount
    }

    private func vividColor(
        _ color: SIMD4<Float>,
        seed: Float
    ) -> SIMD4<Float> {
        let maxComponent = max(color.x, max(color.y, color.z))
        let minComponent = min(color.x, min(color.y, color.z))
        let saturation = maxComponent - minComponent

        if saturation < 0.12 {
            let palette: [SIMD4<Float>] = [
                SIMD4(1.00, 0.16, 0.48, color.w),
                SIMD4(0.20, 0.86, 1.00, color.w),
                SIMD4(1.00, 0.82, 0.12, color.w),
                SIMD4(0.42, 1.00, 0.32, color.w)
            ]
            let index = min(
                Int(seed * Float(palette.count)),
                palette.count - 1
            )
            return palette[index]
        }

        let boost: Float = 1.18
        return SIMD4(
            clamp(color.x * boost, 0, 1),
            clamp(color.y * boost, 0, 1),
            clamp(color.z * boost, 0, 1),
            color.w
        )
    }

    private func clamp(
        _ value: Float,
        _ lower: Float,
        _ upper: Float
    ) -> Float {
        min(max(value, lower), upper)
    }
}
