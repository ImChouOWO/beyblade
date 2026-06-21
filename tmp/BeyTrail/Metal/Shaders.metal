#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// 共用結構 — 統一頂點格式（所有特效共用，stride 32 bytes）
// ═══════════════════════════════════════════════════════════════════════

struct TrailVertexIn {
    float2 position;     // NDC
    float4 color;        // rgb + 存活度/alpha
    float  centerDist;   // -1..+1 橫向
    float  trailDist;    // 距頭部弧長（不用時 0）
};

struct TrailVaryings {
    float4 position [[position]];
    float4 color;
    float  centerDist;
    float  trailDist;
};

struct PointVertexIn {
    float2 position;
    float4 color;
    float  size;
};

struct PointVaryings {
    float4 position [[position]];
    float4 color;
    float  size [[point_size]];
};

struct QuadVaryings {
    float4 position [[position]];
    float2 uv;
};

struct FrameUniforms {
    float  time;
    float2 cropScale;    // 相機裁切（1/quadScale）
    float2 pad;
};

// ═══════════════════════════════════════════════════════════════════════
// 相機 / Blit
// ═══════════════════════════════════════════════════════════════════════

// 全螢幕 quad：position + uv 由 vertex buffer 提供（float4: x,y,u,v）
vertex QuadVaryings quadVertex(const device float4 *verts [[buffer(0)]],
                               constant FrameUniforms &u [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    QuadVaryings out;
    float4 v = verts[vid];
    out.position = float4(v.xy, 0, 1);
    // 相機 center-crop：uv 以中心縮放
    out.uv = (v.zw - 0.5) * u.cropScale + 0.5;
    return out;
}

// 不做 crop 的版本（blit / 錄影旋轉 quad — uv 已含旋轉與裁切）
vertex QuadVaryings blitVertex(const device float4 *verts [[buffer(0)]],
                               uint vid [[vertex_id]]) {
    QuadVaryings out;
    float4 v = verts[vid];
    out.position = float4(v.xy, 0, 1);
    out.uv = v.zw;
    return out;
}

fragment float4 textureFragment(QuadVaryings in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}

// ═══════════════════════════════════════════════════════════════════════
// Trail 共用 vertex
// ═══════════════════════════════════════════════════════════════════════

vertex TrailVaryings trailVertex(const device TrailVertexIn *verts [[buffer(0)]],
                                 uint vid [[vertex_id]]) {
    TrailVaryings out;
    TrailVertexIn v = verts[vid];
    out.position = float4(v.position, 0, 1);
    out.color = v.color;
    out.centerDist = v.centerDist;
    out.trailDist = v.trailDist;
    return out;
}

// ── 通用（閃電/火炎/星塵 雙層 ribbon）：直接輸出頂點色 ──────────────────
fragment float4 genericTrailFragment(TrailVaryings in [[stage_in]]) {
    return in.color;
}

// ── 柔光環帶（漣漪/霜環） ────────────────────────────────────────────────
fragment float4 softBandFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float a = in.color.a * exp(-d * d * 6.0);
    return float4(in.color.rgb, a);
}

// ═══════════════════════════════════════════════════════════════════════
// 雜訊（浪潮 / 紅蓮共用）
// ═══════════════════════════════════════════════════════════════════════

static float vnHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
static float vnNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(vnHash(i),                vnHash(i + float2(1, 0)), f.x),
               mix(vnHash(i + float2(0, 1)), vnHash(i + float2(1, 1)), f.x), f.y);
}

// ── 滔天浪潮：流體水體（暗流/湍流/浪脊光澤、邊緣撕扯） ────────────────────
fragment float4 waveFluidFragment(TrailVaryings in [[stage_in]],
                                  constant FrameUniforms &u [[buffer(1)]]) {
    float d = fabs(in.centerDist);
    float2 uv = float2(in.trailDist * 14.0 - u.time * 6.0, in.centerDist * 2.2);
    float n1 = vnNoise(uv);
    float n2 = vnNoise(uv * 2.7 + 13.7);
    float turb = n1 * 0.65 + n2 * 0.35;

    float edgeCut = 0.74 + (turb - 0.5) * 0.40;
    float body = 1.0 - smoothstep(edgeCut - 0.15, edgeCut + 0.10, d);
    if (body <= 0.004) discard_fragment();

    float3 col = in.color.rgb * (0.78 + 0.30 * turb);
    float crest = smoothstep(0.72, 0.88, n2);
    col = mix(col, in.color.rgb * 0.5 + float3(0.5), crest * 0.45);

    float a = body * (0.45 + 0.50 * in.color.a) * (0.85 + 0.15 * turb);
    return float4(col, a);
}

// ── 不滅鋼盾：力場（平面填充 + 亮邊牆 + 白芯） ───────────────────────────
fragment float4 shieldFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float fill = (1.0 - smoothstep(0.80, 1.00, d)) * 0.22;
    float edge = smoothstep(0.50, 0.74, d) * (1.0 - smoothstep(0.88, 1.00, d));
    float core = exp(-d * d * 24.0);
    float w = fill + edge * 0.95 + core;
    float3 col = (in.color.rgb * fill
                + mix(in.color.rgb, float3(1.0), 0.45) * edge * 0.95
                + float3(core)) / max(w, 0.001);
    return float4(col, in.color.a * min(w, 1.0));
}

// ── 爆刃亂舞：柳葉刀（實心刀身 + 中軸白線；漸層由頂點色帶入） ────────────
fragment float4 bladeFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float body = 1.0 - smoothstep(0.65, 1.0, d);
    float core = exp(-d * d * 26.0);
    float w = body * 0.90 + core * 0.55;
    float3 col = (in.color.rgb * body * 0.90 + float3(1.0) * core * 0.55) / max(w, 0.001);
    return float4(col, in.color.a * min(w, 1.0));
}

// ── 狂暴冰裂：實心冰縫（冰層 + 霜邊 + 白芯） ─────────────────────────────
fragment float4 iceFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float sheet = (1.0 - smoothstep(0.72, 1.00, d)) * 0.55;
    float rim = smoothstep(0.55, 0.80, d) * (1.0 - smoothstep(0.90, 1.00, d)) * 0.85;
    float core = exp(-d * d * 20.0) * 0.90;
    float w = sheet + rim + core;
    float3 col = (in.color.rgb * sheet
                + mix(in.color.rgb, float3(1.0), 0.55) * rim
                + mix(in.color.rgb, float3(1.0), 0.90) * core) / max(w, 0.001);
    return float4(col, in.color.a * min(w, 1.0));
}

// ── 紅蓮破滅：火舌（雜訊撕邊 + 尾部燒蝕 + 熱度梯度，基底 = 陀螺色） ───────
fragment float4 fireFragment(TrailVaryings in [[stage_in]],
                             constant FrameUniforms &u [[buffer(1)]]) {
    float d = fabs(in.centerDist);
    float life = in.color.a;
    float tail = 1.0 - life;

    float2 uv = float2(in.trailDist * 16.0 - u.time * 8.0, in.centerDist * 1.6);
    float n1 = vnNoise(uv);
    float n2 = vnNoise(uv * 2.6 + 7.3);
    float turb = n1 * 0.6 + n2 * 0.4;

    float cut = 0.62 + (turb - 0.5) * (0.55 + 0.55 * tail);
    float body = 1.0 - smoothstep(cut - 0.25, cut + 0.08, d);
    float burn = smoothstep(life * 1.15, life * 1.15 + 0.22, n1);
    body *= 1.0 - burn * 0.85;
    if (body <= 0.004) discard_fragment();

    float heat = (1.0 - d * d) * (0.60 + 0.55 * turb) * (0.30 + 0.70 * life);
    float3 base = in.color.rgb;
    float3 col = mix(base * 0.40, base, smoothstep(0.18, 0.58, heat));
    col = mix(col, mix(base, float3(1.0), 0.72), smoothstep(0.66, 0.93, heat));
    col = mix(col, base, burn * 0.6);

    float a = body * (0.40 + 0.60 * life) * (0.70 + 0.30 * turb);
    return float4(col, min(a, 1.0));
}

// ── 火球多邊形（白熱核心 → 本體色 → 邊緣燒蝕） ───────────────────────────
fragment float4 fireballFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float3 hot = mix(in.color.rgb, float3(1.0), 0.70);
    float3 col = mix(hot, in.color.rgb, smoothstep(0.12, 0.72, d));
    float a = in.color.a * (1.0 - smoothstep(0.55, 1.0, d));
    return float4(col, a);
}

// ── 冰碎片多邊形（平面亮塊，d 固定 0.25 → 帶冷光） ───────────────────────
fragment float4 iceShardFragment(TrailVaryings in [[stage_in]]) {
    float d = fabs(in.centerDist);
    float sheet = (1.0 - smoothstep(0.72, 1.00, d)) * 0.55;
    float core = exp(-d * d * 20.0) * 0.90;
    float w = sheet + core;
    float3 col = (in.color.rgb * sheet
                + mix(in.color.rgb, float3(1.0), 0.85) * core) / max(w, 0.001);
    return float4(col, in.color.a * min(w, 1.0));
}

// ═══════════════════════════════════════════════════════════════════════
// 點粒子（point primitives）
// ═══════════════════════════════════════════════════════════════════════

vertex PointVaryings pointVertex(const device PointVertexIn *verts [[buffer(0)]],
                                 uint vid [[vertex_id]]) {
    PointVaryings out;
    PointVertexIn v = verts[vid];
    out.position = float4(v.position, 0, 1);
    out.color = v.color;
    out.size = v.size;
    return out;
}

// 實心圓點（浪潮水珠/泡泡核心）
fragment float4 pointSolidFragment(PointVaryings in [[stage_in]],
                                   float2 pc [[point_coord]]) {
    float2 c = pc - 0.5;
    float dist = length(c) * 2.0;
    if (dist > 1.0) discard_fragment();
    float a = in.color.a * (1.0 - dist * dist);
    return float4(in.color.rgb, a);
}

// 中空圓環（水氣泡）
fragment float4 pointHollowFragment(PointVaryings in [[stage_in]],
                                    float2 pc [[point_coord]]) {
    float2 c = pc - 0.5;
    float dist = length(c) * 2.0;
    if (dist > 1.0) discard_fragment();
    float ring = smoothstep(0.50, 0.72, dist) * (1.0 - smoothstep(0.85, 1.0, dist));
    return float4(in.color.rgb, in.color.a * ring * 1.2);
}

// 高斯光斑（熱浪殘影/餘燼）
fragment float4 pointGaussFragment(PointVaryings in [[stage_in]],
                                   float2 pc [[point_coord]]) {
    float2 c = pc - 0.5;
    float r2 = dot(c, c) * 4.0;
    if (r2 > 1.0) discard_fragment();
    float a = in.color.a * exp(-r2 * 2.5);
    return float4(in.color.rgb, a);
}
