#include <metal_stdlib>
using namespace metal;

struct BeyTailDrawUniforms {
    uint4 layout0;   // stride, position, color, uv
    int4 layout1;    // centerDist, trailDist, size, extra
    float4 scalar0;  // time, strandAlpha, lineWidth, unused
    float4 tint;
    uint4 meta;      // shaderKind, viewportWidth, viewportHeight, unused
};

struct BeyTailVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float centerDist;
    float trailDist;
    float extra;
    float pointSize [[point_size]];
};

inline float readFloat(
    const device float *raw,
    uint base,
    int offset,
    float fallback
) {
    return offset >= 0 ? raw[base + uint(offset)] : fallback;
}

inline float2 readFloat2(
    const device float *raw,
    uint base,
    uint offset,
    float2 fallback
) {
    return offset != 0xFFFFFFFFu
        ? float2(raw[base + offset], raw[base + offset + 1u])
        : fallback;
}

inline float4 readFloat4(
    const device float *raw,
    uint base,
    uint offset,
    float4 fallback
) {
    return offset != 0xFFFFFFFFu
        ? float4(
            raw[base + offset],
            raw[base + offset + 1u],
            raw[base + offset + 2u],
            raw[base + offset + 3u]
        )
        : fallback;
}

vertex BeyTailVertexOut beytailEffectVertex(
    const device float *raw [[buffer(0)]],
    constant BeyTailDrawUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    BeyTailVertexOut output;
    const uint base = vertexID * uniforms.layout0.x;
    const float2 position = readFloat2(
        raw,
        base,
        uniforms.layout0.y,
        float2(0.0)
    );

    output.position = float4(position, 0.0, 1.0);
    output.color = readFloat4(
        raw,
        base,
        uniforms.layout0.z,
        float4(1.0)
    );
    output.uv = readFloat2(
        raw,
        base,
        uniforms.layout0.w,
        float2(0.0)
    );
    output.centerDist = readFloat(
        raw,
        base,
        uniforms.layout1.x,
        0.0
    );
    output.trailDist = readFloat(
        raw,
        base,
        uniforms.layout1.y,
        0.0
    );
    output.pointSize = max(
        readFloat(raw, base, uniforms.layout1.z, 1.0),
        1.0
    );
    output.extra = readFloat(
        raw,
        base,
        uniforms.layout1.w,
        0.0
    );
    return output;
}

inline float beytailHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

inline float beytailNoise(float2 p) {
    const float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            beytailHash(i),
            beytailHash(i + float2(1.0, 0.0)),
            f.x
        ),
        mix(
            beytailHash(i + float2(0.0, 1.0)),
            beytailHash(i + float2(1.0, 1.0)),
            f.x
        ),
        f.y
    );
}

inline float beytailMod(float x, float y) {
    return x - y * floor(x / y);
}

fragment float4 beytailEffectFragment(
    BeyTailVertexOut input [[stage_in]],
    constant BeyTailDrawUniforms &uniforms [[buffer(0)]]
) {
    const uint shader = uniforms.meta.x;
    const float time = uniforms.scalar0.x;

    // flatColor
    if (shader == 1u) {
        return input.color;
    }

    // blade
    if (shader == 2u) {
        const float d = abs(input.centerDist);
        const float body = 1.0 - smoothstep(0.65, 1.0, d);
        const float core = exp(-d * d * 26.0);
        const float weight = body * 0.90 + core * 0.55;
        const float3 color = (
            input.color.rgb * body * 0.90 +
            float3(1.0) * core * 0.55
        ) / max(weight, 0.001);
        return float4(color, input.color.a * min(weight, 1.0));
    }

    // crimsonFire
    if (shader == 3u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float tail = 1.0 - life;
        const float2 uv = float2(
            input.trailDist * 16.0 - time * 8.0,
            input.centerDist * 1.6
        );
        const float n1 = beytailNoise(uv);
        const float n2 = beytailNoise(uv * 2.6 + 7.3);
        const float turbulence = n1 * 0.6 + n2 * 0.4;
        const float cut = 0.62 +
            (turbulence - 0.5) * (0.55 + 0.55 * tail);
        float body = 1.0 - smoothstep(cut - 0.25, cut + 0.08, d);
        const float burn = smoothstep(
            life * 1.15,
            life * 1.15 + 0.22,
            n1
        );
        body *= 1.0 - burn * 0.85;
        if (body <= 0.004) {
            discard_fragment();
        }

        const float heat = (1.0 - d * d) *
            (0.60 + 0.55 * turbulence) *
            (0.30 + 0.70 * life);
        const float3 base = input.color.rgb;
        float3 color = mix(
            base * 0.40,
            base,
            smoothstep(0.18, 0.58, heat)
        );
        color = mix(
            color,
            mix(base, float3(1.0), 0.72),
            smoothstep(0.66, 0.93, heat)
        );
        color = mix(color, base, burn * 0.6);
        const float alpha = body *
            (0.40 + 0.60 * life) *
            (0.70 + 0.30 * turbulence);
        return float4(color, min(alpha, 1.0));
    }

    // crimsonPolygon
    if (shader == 4u) {
        const float d = abs(input.centerDist);
        const float3 hot = mix(input.color.rgb, float3(1.0), 0.70);
        const float3 color = mix(
            hot,
            input.color.rgb,
            smoothstep(0.12, 0.72, d)
        );
        const float alpha = input.color.a *
            (1.0 - smoothstep(0.55, 1.0, d));
        return float4(color, alpha);
    }

    // deathBeam
    if (shader == 6u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float tail = 1.0 - life;
        const float2 uv = float2(
            input.trailDist * 22.0 - time * 3.0,
            input.centerDist * 3.0
        );
        const float n1 = beytailNoise(uv);
        const float n2 = beytailNoise(uv * 2.3 + 5.1);
        const float noiseValue = n1 * 0.6 + n2 * 0.4;
        const float core = 1.0 - smoothstep(0.18, 0.46, d);
        const float glow = exp(-d * d * 6.0);
        const float burn = smoothstep(
            life * 1.05,
            life * 1.05 + 0.20,
            noiseValue
        );
        const float rim = (
            1.0 - smoothstep(
                0.0,
                0.10,
                abs(noiseValue - life * 1.05)
            )
        ) * tail;
        float body = (core + glow * 0.55) * (1.0 - burn);
        body += rim * (0.5 + 0.5 * tail);
        if (body <= 0.004) {
            discard_fragment();
        }
        float3 color = mix(uniforms.tint.rgb, float3(1.0), core);
        color = mix(color, float3(1.0), rim * 0.7);
        const float intensity = body * (0.55 + 0.45 * life);
        return float4(color, min(intensity, 1.0));
    }

    // emeraldVine
    if (shader == 8u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float n = beytailNoise(float2(
            input.trailDist * 40.0,
            input.centerDist * 3.0
        ));
        const float cut = 0.80 + (n - 0.5) * 0.55;
        float body = 1.0 - smoothstep(cut - 0.12, cut + 0.04, d);
        const float wither = smoothstep(
            life * 1.1,
            life * 1.1 + 0.22,
            n
        );
        body *= 1.0 - wither * 0.7;
        if (body <= 0.004) {
            discard_fragment();
        }
        const float vein = 1.0 - smoothstep(0.0, 0.22, d);
        float3 color = mix(
            input.color.rgb * 0.55,
            input.color.rgb,
            smoothstep(0.0, 0.6, 1.0 - d)
        );
        color = mix(color, float3(1.0), vein * 0.40);
        return float4(color, min(body * (0.45 + 0.55 * life), 1.0));
    }

    // leaf
    if (shader == 9u) {
        const float u = input.uv.x;
        const float v = input.uv.y;
        const float profile = pow(max(0.0, 1.0 - u * u), 0.65);
        const float d = abs(v) / max(profile, 0.001);
        if (d > 1.0) {
            discard_fragment();
        }
        const float edge = 1.0 - smoothstep(0.72, 1.0, d);
        const float vein = 1.0 - smoothstep(0.0, 0.16, abs(v));
        const float3 color = mix(
            input.color.rgb,
            float3(1.0),
            vein * 0.6
        );
        return float4(color, input.color.a * edge);
    }

    // iceRibbon
    if (shader == 10u) {
        const float d = abs(input.centerDist);
        const float sheet = (1.0 - smoothstep(0.72, 1.0, d)) * 0.55;
        const float rim = smoothstep(0.55, 0.80, d) *
            (1.0 - smoothstep(0.90, 1.0, d)) * 0.85;
        const float core = exp(-d * d * 20.0) * 0.90;
        const float weight = sheet + rim + core;
        const float3 color = (
            input.color.rgb * sheet +
            mix(input.color.rgb, float3(1.0), 0.55) * rim +
            mix(input.color.rgb, float3(1.0), 0.90) * core
        ) / max(weight, 0.001);
        return float4(color, input.color.a * min(weight, 1.0));
    }

    // iceBlade
    if (shader == 11u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float core = exp(-d * d * 26.0);
        const float body = 1.0 - smoothstep(0.55, 1.0, d);
        const float edge = smoothstep(0.78, 0.93, d) *
            (1.0 - smoothstep(0.93, 1.0, d));
        const float sweep = sin(input.trailDist * 26.0 - time * 7.0);
        const float gloss = smoothstep(0.55, 1.0, sweep) *
            body * (0.4 + 0.6 * life);
        const float weight = body * 0.5 + core * 0.95 +
            edge * 0.6 + gloss * 0.55;
        if (weight <= 0.004) {
            discard_fragment();
        }
        const float3 base = input.color.rgb;
        float3 color = base * (body * 0.5) +
            mix(base, float3(1.0), 0.92) * core +
            mix(base, float3(1.0), 0.70) * edge +
            float3(1.0) * gloss * 0.55;
        color /= max(weight, 0.001);
        return float4(
            color,
            min(weight * (0.25 + 0.75 * life), 1.0)
        );
    }

    // ink
    if (shader == 13u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float tail = 1.0 - life;
        const float density = 1.0 - smoothstep(0.0, 1.0, d);
        const float3 jiao = input.color.rgb * 0.42;
        const float3 color = mix(
            input.color.rgb,
            jiao,
            smoothstep(0.25, 0.95, density)
        );
        const float fb = beytailNoise(float2(
            input.trailDist * 70.0,
            input.centerDist * 7.0
        )) * 0.6 + beytailNoise(float2(
            input.trailDist * 24.0,
            input.centerDist * 3.0
        )) * 0.4;
        const float fbAmount = 0.22 +
            smoothstep(0.0, 0.6, tail) * 0.55;
        const float feibai = 1.0 - smoothstep(
            1.0 - fbAmount,
            1.0,
            fb
        );
        const float fork = smoothstep(
            0.40,
            0.62,
            beytailNoise(float2(
                input.trailDist * 6.0,
                input.centerDist * 1.6
            ))
        );
        const float forkCut = 1.0 - fork *
            smoothstep(0.2, 0.85, tail) * 0.7;
        const float dissolve = smoothstep(
            life * 1.08,
            life * 1.08 + 0.10,
            fb
        );
        float body = density * (0.35 + 0.65 * density);
        body *= feibai * forkCut * (1.0 - dissolve);
        if (body <= 0.004) {
            discard_fragment();
        }
        const float alpha = body *
            (0.55 + 0.45 * life) *
            uniforms.scalar0.y;
        return float4(color, min(alpha, 1.0));
    }

    // gold
    if (shader == 15u) {
        const float d = abs(input.centerDist);
        const float body = (1.0 - smoothstep(0.55, 1.0, d)) * 0.55;
        const float core = exp(-d * d * 18.0);
        const float weight = body + core;
        const float3 color = (
            input.color.rgb * body +
            mix(input.color.rgb, float3(1.0), 0.75) * core
        ) / max(weight, 0.001);
        return float4(color, input.color.a * min(weight, 1.0));
    }

    // coin
    if (shader == 16u) {
        const float radius = length(input.uv);
        if (radius > 1.0) {
            discard_fragment();
        }
        const float3 gold = input.color.rgb;
        const float3 deep = gold * 0.55;
        float3 color = mix(
            gold,
            deep,
            smoothstep(0.70, 0.95, radius)
        );
        const float ring = 1.0 - smoothstep(
            0.0,
            0.05,
            abs(radius - 0.80)
        );
        color = mix(color, deep, ring * 0.5);

        const float pi = 3.14159265;
        const float2 glyph = input.uv / 0.42;
        const float2 topPoint = glyph - float2(0.0, 0.5);
        const float topDistance = abs(length(topPoint) - 0.5);
        const float topGap = abs(
            beytailMod(
                atan2(topPoint.y, topPoint.x) + 0.6 + pi,
                2.0 * pi
            ) - pi
        );
        const float topArc = (
            1.0 - smoothstep(0.11, 0.18, topDistance)
        ) * step(0.95, topGap);

        const float2 bottomPoint = glyph - float2(0.0, -0.5);
        const float bottomDistance = abs(length(bottomPoint) - 0.5);
        const float bottomGap = abs(
            beytailMod(
                atan2(bottomPoint.y, bottomPoint.x) - 2.4 + pi,
                2.0 * pi
            ) - pi
        );
        const float bottomArc = (
            1.0 - smoothstep(0.11, 0.18, bottomDistance)
        ) * step(0.95, bottomGap);

        const float bar = (
            1.0 - smoothstep(0.08, 0.13, abs(glyph.x))
        ) * (
            1.0 - smoothstep(1.08, 1.24, abs(glyph.y))
        );
        const float dollar = clamp(topArc + bottomArc + bar, 0.0, 1.0);
        color = mix(color, deep * 0.5, dollar);

        const float highlight = smoothstep(
            0.62,
            0.0,
            length(input.uv - float2(-0.32, 0.32))
        );
        color = mix(
            color,
            float3(1.0),
            highlight * 0.5 * (1.0 - dollar)
        );
        const float alpha = input.color.a *
            (1.0 - smoothstep(0.94, 1.0, radius));
        return float4(color, alpha);
    }

    // sprayPaint
    if (shader == 17u) {
        const float d = abs(input.centerDist);
        const float life = input.color.a;
        const float tail = 1.0 - life;
        const float core = (1.0 - smoothstep(0.48, 0.60, d)) *
            smoothstep(0.05, 0.35, life);
        const float grain = max(
            beytailNoise(float2(
                input.trailDist * 60.0,
                input.centerDist * 34.0
            )),
            beytailNoise(float2(
                input.trailDist * 130.0 + 3.0,
                input.centerDist * 72.0
            )) * 0.85
        );
        const float sprayZone = smoothstep(0.42, 1.05, d) + tail * 0.65;
        const float speck = step(sprayZone, grain);
        const float edgeCut = 1.0 - smoothstep(1.0, 1.12, d);
        const float body = max(core, speck) * edgeCut;
        if (body < 0.5) {
            discard_fragment();
        }
        return float4(
            input.color.rgb * (0.86 + 0.14 * grain),
            0.96
        );
    }

    // waveFluid
    if (shader == 19u) {
        const float d = abs(input.centerDist);
        const float2 uv = float2(
            input.trailDist * 14.0 - time * 6.0,
            input.centerDist * 2.2
        );
        const float n1 = beytailNoise(uv);
        const float n2 = beytailNoise(uv * 2.7 + 13.7);
        const float turbulence = n1 * 0.65 + n2 * 0.35;
        const float edgeCut = 0.74 + (turbulence - 0.5) * 0.40;
        const float body = 1.0 - smoothstep(
            edgeCut - 0.15,
            edgeCut + 0.10,
            d
        );
        if (body <= 0.004) {
            discard_fragment();
        }
        float3 color = input.color.rgb * (0.78 + 0.30 * turbulence);
        const float crest = smoothstep(0.72, 0.88, n2);
        color = mix(
            color,
            input.color.rgb * 0.5 + float3(0.5),
            crest * 0.45
        );
        const float alpha = body *
            (0.45 + 0.50 * input.color.a) *
            (0.85 + 0.15 * turbulence);
        return float4(color, alpha);
    }

    // waveTrail
    if (shader == 20u) {
        const float distance = abs(input.centerDist);
        const float glow = 1.0 - distance * distance;
        return float4(
            input.color.rgb,
            input.color.a * glow
        );
    }

    return input.color;
}

fragment float4 beytailPointFragment(
    BeyTailVertexOut input [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant BeyTailDrawUniforms &uniforms [[buffer(0)]]
) {
    const uint shader = uniforms.meta.x;
    const float2 centered = pointCoord - float2(0.5);
    const float radiusSquared = dot(centered, centered) * 4.0;

    // crimsonHaze
    if (shader == 5u) {
        if (radiusSquared > 1.0) {
            discard_fragment();
        }
        return float4(
            input.color.rgb,
            input.color.a * exp(-radiusSquared * 2.5)
        );
    }

    // deathPoint
    if (shader == 7u) {
        if (radiusSquared > 1.0) {
            discard_fragment();
        }
        return float4(
            input.color.rgb,
            input.color.a * exp(-radiusSquared * 2.2)
        );
    }

    // iceFog
    if (shader == 12u) {
        if (radiusSquared > 1.0) {
            discard_fragment();
        }
        return float4(
            input.color.rgb,
            input.color.a * exp(-radiusSquared * 2.4)
        );
    }

    // inkDrop
    if (shader == 14u) {
        if (radiusSquared > 1.0) {
            discard_fragment();
        }
        const float base = exp(-radiusSquared * 2.0);
        const float noiseValue = beytailNoise(pointCoord * 9.0);
        if (noiseValue < input.extra) {
            discard_fragment();
        }
        const float alpha = input.color.a * base;
        if (alpha < 0.02) {
            discard_fragment();
        }
        return float4(input.color.rgb, alpha);
    }

    // splat
    if (shader == 18u) {
        const float angle = atan2(centered.y, centered.x);
        const float radius = length(centered) * 2.0;
        const float wobble = 0.80 +
            0.12 * sin(angle * 3.0 + input.extra) +
            0.08 * sin(angle * 5.0 - input.extra * 1.7) +
            0.05 * sin(angle * 8.0 + input.extra * 0.5);
        if (radius > wobble) {
            discard_fragment();
        }
        const float alpha = input.color.a *
            (1.0 - smoothstep(wobble - 0.12, wobble, radius));
        return float4(input.color.rgb, alpha);
    }

    // waveParticle
    if (shader == 21u) {
        const float radius = length(centered) * 2.0;
        if (radius > 1.0) {
            discard_fragment();
        }
        return float4(
            input.color.rgb,
            input.color.a * (1.0 - radius * radius)
        );
    }

    return input.color;
}
