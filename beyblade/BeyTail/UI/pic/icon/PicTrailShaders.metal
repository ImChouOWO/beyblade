#include <metal_stdlib>
using namespace metal;

struct PicUniforms {
    float2 viewportSize;
    float time;
    float pixelScale;
};

struct PicRibbonVertex {
    float2 position;
    float4 color;
    float2 uv;
    float style;
    float seed;
};

struct PicSpriteVertex {
    float2 center;
    float2 corner;
    float2 size;
    float4 color;
    float rotation;
    float style;
    float seed;
    float age;
};

struct PicRibbonOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float style;
    float seed;
    float time;
};

struct PicSpriteOut {
    float4 position [[position]];
    float4 color;
    float2 local;
    float style;
    float seed;
    float age;
    float time;
};

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(
        mix(a, b, f.x),
        mix(c, d, f.x),
        f.y
    );
}

vertex PicRibbonOut picRibbonVertex(
    const device PicRibbonVertex *vertices [[buffer(0)]],
    constant PicUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    PicRibbonVertex input = vertices[vertexID];

    float2 clip = float2(
        input.position.x / max(uniforms.viewportSize.x, 1.0) * 2.0 - 1.0,
        1.0 - input.position.y / max(uniforms.viewportSize.y, 1.0) * 2.0
    );

    PicRibbonOut output;
    output.position = float4(clip, 0.0, 1.0);
    output.color = input.color;
    output.uv = input.uv;
    output.style = input.style;
    output.seed = input.seed;
    output.time = uniforms.time;
    return output;
}

fragment float4 picRibbonFragment(
    PicRibbonOut input [[stage_in]]
) {
    float side = abs(input.uv.x);
    float edge = 1.0 - smoothstep(0.56, 1.0, side);
    float core = 1.0 - smoothstep(0.0, 0.28, side);
    float n = valueNoise(
        float2(
            input.uv.y * 18.0 + input.seed * 19.0,
            input.uv.x * 4.0 + input.time * 0.7
        )
    );

    float3 color = input.color.rgb;
    float alpha = input.color.a * edge;
    int style = int(round(input.style));

    switch (style) {
        case 1: { // lightning
            float pulse = 0.72
                + 0.28 * sin(input.time * 23.0 + input.uv.y * 38.0);
            float broken = smoothstep(0.20, 0.58, n);
            color = mix(color, float3(1.0), core * 0.78);
            alpha *= max(core * 0.95, broken * 0.50) * pulse;
            break;
        }

        case 2: { // fire
            float tongue = smoothstep(
                0.15,
                0.88,
                n + (1.0 - side) * 0.30
            );
            color = mix(
                color * float3(0.95, 0.38, 0.10),
                float3(1.0, 0.92, 0.36),
                core * 0.72
            );
            alpha *= tongue * (0.64 + core * 0.46);
            break;
        }

        case 3: { // stardust
            float twinkle = 0.58
                + 0.42 * sin(input.time * 15.0 + input.seed * 91.0);
            color = mix(color, float3(1.0), core * 0.62);
            alpha *= 0.62 + twinkle * 0.38;
            break;
        }

        case 4: { // wave
            float wave = 0.72
                + 0.28 * sin(
                    input.uv.y * 34.0
                    - input.time * 9.0
                    + input.uv.x * 5.0
                );
            float foam = smoothstep(0.68, 0.96, n + core * 0.30);
            color = mix(
                color * float3(0.30, 0.68, 1.0),
                float3(0.82, 0.97, 1.0),
                foam * 0.78
            );
            alpha *= wave * (0.52 + foam * 0.55);
            break;
        }

        case 5: { // money
            float glint = pow(
                max(
                    0.0,
                    sin(input.uv.y * 42.0 - input.time * 11.0)
                ),
                10.0
            );
            color = mix(
                color * float3(0.90, 0.55, 0.08),
                float3(1.0, 0.97, 0.58),
                core * 0.55 + glint * 0.62
            );
            alpha *= 0.76 + glint * 0.36;
            break;
        }

        case 6: { // blade
            float bevel = smoothstep(0.78, 0.12, side);
            float glint = pow(
                max(
                    0.0,
                    sin(input.uv.y * 55.0 + input.time * 8.0)
                ),
                13.0
            );
            color = mix(
                color * float3(0.48, 0.73, 0.92),
                float3(1.0),
                bevel * 0.67 + glint
            );
            alpha *= 0.63 + bevel * 0.48;
            break;
        }

        case 7: { // ice
            float crystal = smoothstep(
                0.40,
                0.86,
                abs(
                    sin(
                        input.uv.y * 39.0
                        + input.uv.x * 8.0
                        + n * 4.0
                    )
                )
            );
            color = mix(
                color * float3(0.43, 0.76, 1.0),
                float3(0.92, 1.0, 1.0),
                core * 0.62 + crystal * 0.30
            );
            alpha *= 0.58 + crystal * 0.48;
            break;
        }

        case 8: { // crimson
            float flame = smoothstep(0.22, 0.84, n + core * 0.36);
            color = mix(
                color * float3(0.72, 0.06, 0.08),
                float3(1.0, 0.58, 0.12),
                flame * 0.72 + core * 0.26
            );
            alpha *= 0.60 + flame * 0.52;
            break;
        }

        case 9: { // death ray
            float scan = 0.78
                + 0.22 * sin(input.uv.y * 70.0 - input.time * 18.0);
            color = mix(
                color * float3(0.65, 0.28, 1.0),
                float3(1.0),
                core * 0.92
            );
            alpha *= scan * (0.50 + core * 0.70);
            break;
        }

        case 10: { // emerald
            float vein = pow(
                max(
                    0.0,
                    sin(input.uv.y * 31.0 + input.uv.x * 5.0)
                ),
                8.0
            );
            color = mix(
                color * float3(0.18, 0.75, 0.40),
                float3(0.72, 1.0, 0.46),
                core * 0.56 + vein * 0.42
            );
            alpha *= 0.68 + vein * 0.32;
            break;
        }

        case 11: { // ink wash
            float dry = smoothstep(0.26, 0.70, n + core * 0.18);
            float fibers = 0.60
                + 0.40 * abs(
                    sin(input.uv.y * 120.0 + input.seed * 27.0)
                );
            color = mix(
                color,
                float3(0.42),
                (1.0 - core) * 0.18
            );
            alpha *= dry * fibers * (0.58 + core * 0.50);
            break;
        }

        case 12: { // spray paint
            float porous = smoothstep(0.28, 0.72, n + core * 0.24);
            color = min(color * 1.22, float3(1.0));
            alpha *= porous * (0.56 + core * 0.46);
            break;
        }

        default: {
            color = mix(color, float3(1.0), core * 0.30);
            alpha *= 0.72 + core * 0.30;
            break;
        }
    }

    if (alpha < 0.002) {
        discard_fragment();
    }

    return float4(color, clamp(alpha, 0.0, 1.0));
}

vertex PicSpriteOut picSpriteVertex(
    const device PicSpriteVertex *vertices [[buffer(0)]],
    constant PicUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    PicSpriteVertex input = vertices[vertexID];

    float c = cos(input.rotation);
    float s = sin(input.rotation);
    float2 localPixels = input.corner * input.size * 0.5;
    float2 rotated = float2(
        localPixels.x * c - localPixels.y * s,
        localPixels.x * s + localPixels.y * c
    );
    float2 pixelPosition = input.center + rotated;

    float2 clip = float2(
        pixelPosition.x / max(uniforms.viewportSize.x, 1.0) * 2.0 - 1.0,
        1.0 - pixelPosition.y / max(uniforms.viewportSize.y, 1.0) * 2.0
    );

    PicSpriteOut output;
    output.position = float4(clip, 0.0, 1.0);
    output.color = input.color;
    output.local = input.corner;
    output.style = input.style;
    output.seed = input.seed;
    output.age = input.age;
    output.time = uniforms.time;
    return output;
}

fragment float4 picSpriteFragment(
    PicSpriteOut input [[stage_in]]
) {
    float2 p = input.local;
    float radius = length(p);
    float angle = atan2(p.y, p.x);
    float noise = valueNoise(
        p * 3.7
        + float2(input.seed * 17.0, input.time * 0.25)
    );

    float mask = 0.0;
    float3 color = input.color.rgb;
    int style = int(round(input.style));

    switch (style) {
        case 0: { // soft circle
            mask = 1.0 - smoothstep(0.42, 1.0, radius);
            break;
        }

        case 1: { // spark
            float crossA = 1.0 - smoothstep(
                0.04,
                0.22,
                min(abs(p.x), abs(p.y))
            );
            float crossB = 1.0 - smoothstep(
                0.04,
                0.18,
                min(abs(p.x + p.y), abs(p.x - p.y)) * 0.707
            );
            mask = max(crossA, crossB)
                * (1.0 - smoothstep(0.48, 1.0, radius));
            color = mix(color, float3(1.0), 0.62);
            break;
        }

        case 2: { // ring
            float thickness = 0.08 + input.age * 0.08;
            mask = 1.0 - smoothstep(
                thickness,
                thickness + 0.08,
                abs(radius - 0.72)
            );
            break;
        }

        case 3: { // bubble
            float ring = 1.0 - smoothstep(
                0.08,
                0.18,
                abs(radius - 0.68)
            );
            float highlight = 1.0 - smoothstep(
                0.0,
                0.20,
                length(p - float2(-0.30, -0.32))
            );
            mask = max(ring * 0.92, highlight);
            color = mix(color, float3(1.0), highlight * 0.75);
            break;
        }

        case 4: { // coin
            float disc = 1.0 - smoothstep(0.78, 1.0, radius);
            float rim = 1.0 - smoothstep(
                0.06,
                0.13,
                abs(radius - 0.72)
            );
            float mark = 1.0 - smoothstep(
                0.05,
                0.16,
                abs(p.x + 0.18 * sin(p.y * 8.0))
            );
            mask = disc;
            color = mix(
                color * float3(0.82, 0.50, 0.05),
                float3(1.0, 0.94, 0.45),
                clamp(rim + mark * 0.38, 0.0, 1.0)
            );
            break;
        }

        case 5: { // blade
            float diamond = abs(p.x) * 0.22 + abs(p.y);
            mask = 1.0 - smoothstep(0.62, 0.96, diamond);
            float edge = smoothstep(0.38, 0.82, diamond);
            color = mix(color, float3(1.0), 1.0 - edge);
            break;
        }

        case 6: { // shard
            float triangle = max(
                abs(p.x) * 0.92 + p.y * 0.30,
                -p.y * 0.78
            );
            mask = 1.0 - smoothstep(0.58, 0.93, triangle);
            float gleam = 1.0 - smoothstep(0.02, 0.20, abs(p.x + p.y * 0.22));
            color = mix(color, float3(1.0), gleam * 0.52);
            break;
        }

        case 7: { // fireball
            float raggedRadius = radius + (noise - 0.5) * 0.24;
            mask = 1.0 - smoothstep(0.52, 1.0, raggedRadius);
            float hot = 1.0 - smoothstep(0.0, 0.56, radius);
            color = mix(color, float3(1.0, 0.88, 0.24), hot * 0.72);
            break;
        }

        case 8: { // haze
            mask = pow(
                max(0.0, 1.0 - smoothstep(0.0, 1.0, radius)),
                2.0
            );
            mask *= 0.72 + noise * 0.28;
            break;
        }

        case 9: { // leaf
            float leaf = pow(abs(p.x), 1.45)
                + pow(abs(p.y), 2.35);
            mask = 1.0 - smoothstep(0.72, 1.0, leaf);
            float vein = 1.0 - smoothstep(
                0.03,
                0.11,
                abs(p.x + 0.12 * sin(p.y * 5.0))
            );
            color = mix(color, float3(0.80, 1.0, 0.52), vein * 0.48);
            break;
        }

        case 10: { // ink drop
            float raggedRadius = radius + (noise - 0.5) * 0.32;
            mask = 1.0 - smoothstep(0.62, 0.98, raggedRadius);
            mask *= 0.68 + 0.32 * noise;
            break;
        }

        case 11: { // splat
            float lobes = 0.68
                + 0.18 * sin(angle * 7.0 + input.seed * 19.0)
                + 0.10 * sin(angle * 13.0);
            mask = 1.0 - smoothstep(
                lobes - 0.12,
                lobes + 0.10,
                radius
            );
            mask = max(
                mask,
                (1.0 - smoothstep(0.0, 0.13, length(p - float2(0.72, 0.12))))
            );
            color = min(color * 1.18, float3(1.0));
            break;
        }

        case 12: { // star
            float radial = abs(cos(angle * 4.0));
            float starRadius = mix(0.34, 0.92, pow(radial, 4.0));
            mask = 1.0 - smoothstep(
                starRadius - 0.10,
                starRadius + 0.08,
                radius
            );
            color = mix(color, float3(1.0), 0.66);
            break;
        }

        default: {
            mask = 1.0 - smoothstep(0.58, 1.0, radius);
            break;
        }
    }

    float alpha = input.color.a * clamp(mask, 0.0, 1.0);

    if (alpha < 0.002) {
        discard_fragment();
    }

    return float4(color, alpha);
}
