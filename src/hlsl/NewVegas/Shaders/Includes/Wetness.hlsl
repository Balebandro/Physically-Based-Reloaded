// Wetness Effects, ported from Community Shaders (features/Wetness Effects, GPL-3.0): surfaces getting
// wet in the rain and drying after it, as a water layer on the material.
//
//   - Rain wetness: open surfaces darken (porous ones more, metals not) and gain a water film, a
//     glossy layer over the material with its own highlight and reflection. Upward faces get
//     fully wet; walls and undersides MinRainWetness of it.
//   - Puddles: perlin noise over flat ground, filling as the rain goes on and lingering after it.
//     A puddle is a near-mirror film that flattens the surface's bumps.
//   - Shore wetness: ground near the water line of the cell's water.
//   - Raindrops (open, upward surfaces near the camera): splashes, wet spots that appear and fade,
//     and ripples, rings spreading on flat wet ground and puddles.
//   - Occlusion: nothing under a roof, a bridge or an overhang gets rained on (NVR's top-down ortho
//     depth map, as CS's precipitation occlusion map).
//
// The weather side (how wet, how puddled, how hard it rains) is in effects/WetnessEffects.cpp.
//
// Positions are camera-relative (GetShadowWorldPos), normals world-space. The including template
// defines WETNESS_ORTHO_REG (a free sampler) for occlusion, or leaves it undefined to go without.

#ifndef WETNESS_HLSL
#define WETNESS_HLSL

// Pinned past every register the game and the other NVR constants use (see TESR_PBRData in Object.hlsl
// for why constants are pinned).
float4 TESR_WetnessData    : register(c200);   // x: wetness, y: puddle wetness, z: raining, w: time (s)
float4 TESR_WetnessParams  : register(c201);   // x: MaxRainWetness, y: MaxPuddleWetness, z: MinRainWetness, w: PuddleRadius
float4 TESR_WetnessParams2 : register(c202);   // x: PuddleMaxAngle, y: PuddleMinWetness, z: MaxShoreWetness, w: ShoreRange
float4 TESR_WetnessDrops   : register(c203);   // x: 1 / grid size, y: 1 / interval, z: drop chance, w: interval / ripple lifetime
float4 TESR_WetnessSplash  : register(c204);   // x: splash strength, y: splash lifetime, z: min radius, w: max radius
float4 TESR_WetnessRipple  : register(c205);   // x: ripple strength, y: radius, z: breadth, w: raindrop range
float4 TESR_WetnessCamera  : register(c206);   // xyz: camera position, w: water height (-1e9: none)
float4 TESR_WetnessFlags   : register(c207);   // x: on, y: splashes, z: ripples, w: ortho map texel size (0: no map)
row_major float4x4 TESR_ShadowCameraToLightTransformOrtho : register(c208);   // c208-c211
float4 TESR_WetnessSun     : register(c212);   // xyz: direction to the sun (world), w: ShowCover debug view

#ifdef WETNESS_ORTHO_PER_DRAW
// Set per draw by the hook that binds the map (Hooks/Shaders.cpp, LandRainCover), not through the constant
// table: x is 1 while the ortho map is on the sampler, 0 when the sampler holds something else.
float4 WetnessMapBound     : register(c213);
#define WETNESS_MAP_READY (WetnessMapBound.x > 0.5f)
#else
#define WETNESS_MAP_READY true
#endif

#ifdef WETNESS_ORTHO_REG
sampler2D TESR_OrthoMapBuffer : register(WETNESS_ORTHO_REG) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
#endif

#define WETNESS_ON (TESR_WetnessFlags.x > 0.5f)

// "Hash without sine" (Dave Hoskins, MIT): stable for large inputs, unlike frac(sin()). CS hashes
// integers (pcg3d, murmur3); ps_3_0 has none.
float3 WetHash33(float3 p3) {
    p3 = frac(p3 * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yxz + 33.33f);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Perlin noise, as CS's Random::perlinNoise (gradients picked by hash, the wetness-specific fade).
float3 WetGradient(float3 cell) {
    float3 h = WetHash33(cell) * 2.0f - 1.0f;
    return normalize(h + 1e-4f);
}

float WetPerlin(float3 p) {
    float3 i = floor(p);
    float3 f = p - i;
    float v1 = dot(WetGradient(i), f);
    float v2 = dot(WetGradient(i + float3(1, 0, 0)), f - float3(1, 0, 0));
    float v3 = dot(WetGradient(i + float3(0, 1, 0)), f - float3(0, 1, 0));
    float v4 = dot(WetGradient(i + float3(1, 1, 0)), f - float3(1, 1, 0));
    float v5 = dot(WetGradient(i + float3(0, 0, 1)), f - float3(0, 0, 1));
    float v6 = dot(WetGradient(i + float3(1, 0, 1)), f - float3(1, 0, 1));
    float v7 = dot(WetGradient(i + float3(0, 1, 1)), f - float3(0, 1, 1));
    float v8 = dot(WetGradient(i + float3(1, 1, 1)), f - float3(1, 1, 1));
    float3 u = f * f * (3.0f - 2.0f * f);
    return lerp(lerp(lerp(v1, v2, u.x), lerp(v3, v4, f.x), u.y),
                lerp(lerp(v5, v6, u.x), lerp(v7, v8, f.x), u.y), u.z);
}

// Reoriented normal mapping: detail n2 laid onto base n1 (CS's ReorientNormal).
float3 WetReorient(float3 n1, float3 n2) {
    n1 += float3(0.0f, 0.0f, 1.0f);
    n2 *= float3(-1.0f, -1.0f, 1.0f);
    return normalize(n1 * dot(n1, n2) / n1.z - n2);
}

float WetSmoothstepDeriv(float x) { return 6.0f * x * (1.0f - x); }

float WetRainFade(float t) {
    const float stay = 0.5f;
    if (t < stay) return 1.0f;
    float v = 1.0f - (t - stay) / (1.0f - stay);
    return v * v;
}

// 1 where the camera-relative point is open to the sky, 0 under something.
//
// The ortho map is coarse (about 12 game units a texel at Resolution 2), so a hard test draws the edge
// of a roof's dry patch as a staircase of texels. Here the edge is smooth and irregular instead:
//   - a tent filter, a 3x3 texel box blended by the point's place inside its texel (4x4 taps with
//     weights 1-f, 1, 1, f per axis): the fade runs smoothly over about three texels, no steps;
//   - the lookup nudged by world-space noise of up to a texel, so the line wanders with the ground
//     instead of following the map's rows and columns, as a real drip line does.
float WetnessOcclusion(float3 position, float3 normal) {
#ifdef WETNESS_ORTHO_REG
    float texel = TESR_WetnessFlags.w;
    [branch] if (texel <= 0.0f || !WETNESS_MAP_READY) return 1.0f;
    // Lifted a little along the normal and up (CS jitters by the normal too), so a surface does not
    // occlude itself.
    float4 o = mul(float4(position + normal * 2.0f + float3(0.0f, 0.0f, 2.0f), 1.0f), TESR_ShadowCameraToLightTransformOrtho);
    o.xyz /= o.w;
    if (any(abs(o.xy) > 1.0f) || o.z < 0.0f || o.z > 1.0f) return 1.0f;
    float2 uv = float2(o.x * 0.5f + 0.5f, o.y * -0.5f + 0.5f);

    float3 worldPos = TESR_WetnessCamera.xyz + position;
    float2 wander = float2(WetPerlin(worldPos * 0.045f), WetPerlin(worldPos.yxz * 0.045f + 17.3f));
    uv += wander * texel * 1.6f;

    // Tent filter over the map's texels.
    float2 cell = uv / texel - 0.5f;
    float2 f = frac(cell);
    float2 base = (floor(cell) + 0.5f - 1.0f) * texel;   // centre of the first of the four taps per axis
    float4 wx = float4(1.0f - f.x, 1.0f, 1.0f, f.x);
    float4 wy = float4(1.0f - f.y, 1.0f, 1.0f, f.y);
    float depth = o.z - 0.0005f;
    float open = 0.0f;
    [unroll] for (int y = 0; y < 4; y++) {
        [unroll] for (int x = 0; x < 4; x++) {
            float2 tapUV = base + float2(x, y) * texel;
            float lit = tex2Dlod(TESR_OrthoMapBuffer, float4(tapUV, 0.0f, 0.0f)).r > depth ? 1.0f : 0.0f;
            open += lit * wx[x] * wy[y];
        }
    }
    return smoothstep(0.0f, 1.0f, open / 9.0f);
#else
    return 1.0f;
#endif
}

// [Shaders.WetnessEffects.Debug] ShowCover (TESR_WetnessSun.w): what the cover test sees. Green open to
// the sky, red covered, yellow outside the ortho map (counted open), blue no ortho map, dark blue a
// shader with no sampler for it (seven-texture land).
#define WETNESS_DEBUG_COVER (TESR_WetnessSun.w > 0.5f)
float3 WetnessCoverDebug(float3 position, float3 normal) {
#ifdef WETNESS_ORTHO_REG
    if (TESR_WetnessFlags.w <= 0.0f) return float3(0.0f, 0.0f, 1.0f);
    if (!WETNESS_MAP_READY) return float3(1.0f, 0.0f, 1.0f);   // magenta: the per-draw binding did not happen
    float4 o = mul(float4(position + normal * 2.0f + float3(0.0f, 0.0f, 2.0f), 1.0f), TESR_ShadowCameraToLightTransformOrtho);
    o.xyz /= o.w;
    if (any(abs(o.xy) > 1.0f) || o.z < 0.0f || o.z > 1.0f) return float3(1.0f, 1.0f, 0.0f);
    return lerp(float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f), WetnessOcclusion(position, normal));
#else
    return float3(0.0f, 0.0f, 0.3f);
#endif
}

// CS's GetRainDrops: xyz the ripple normal (z up), w the splash wetness.
float4 WetRainDrops(float3 worldPos, float t, float3 normal, float rippleStrengthModifier) {
    float2 gridUV = worldPos.xy * TESR_WetnessDrops.x + normal.xy;
    float2 grid = floor(gridUV);
    gridUV -= grid;

    float3 rippleNormal = float3(0.0f, 0.0f, 1.0f);
    float wetness = 0.0f;
    float chance = TESR_WetnessDrops.z;
    bool splashes = TESR_WetnessFlags.y > 0.5f;
    bool ripples = TESR_WetnessFlags.z > 0.5f;

    [loop] for (int i = -1; i <= 1; i++) {
        [loop] for (int j = -1; j <= 1; j++) {
            float2 cell = grid + float2(i, j);
            float tOffset = WetHash33(float3(cell, 1.7f)).x;

            [branch] if (splashes) {
                float residual = t * TESR_WetnessDrops.y / TESR_WetnessSplash.y + tOffset + worldPos.z * 0.001f;
                float timestep = floor(residual);
                residual -= timestep;
                float3 h = WetHash33(float3(cell, timestep));
                [branch] if (h.z < chance) {
                    float2 toCentre = float2(i, j) + h.xy - gridUV;
                    float radius = lerp(TESR_WetnessSplash.z, TESR_WetnessSplash.w, WetHash33(h * 91.7f).x);
                    if (dot(toCentre, toCentre) < radius * radius)
                        wetness = max(wetness, WetRainFade(residual));
                }
            }

            [branch] if (ripples) {
                float residual = t * TESR_WetnessDrops.y + tOffset + worldPos.z * 0.001f;
                float timestep = floor(residual);
                residual -= timestep;
                float3 h = WetHash33(float3(cell, timestep + 0.5f));
                float rippleT = residual * TESR_WetnessDrops.w;
                [branch] if (h.z < chance && rippleT < 1.0f) {
                    float2 toCentre = float2(i, j) + h.xy - gridUV;
                    float size = lerp(0.7f, 1.3f, WetHash33(h * 53.1f).y);
                    float rippleR = TESR_WetnessRipple.y * size * rippleT;
                    float inner = rippleR - TESR_WetnessRipple.z;
                    float band = (length(toCentre) - inner) / TESR_WetnessRipple.z;
                    [branch] if (band > 0.0f && band < 1.0f) {
                        float deriv = (band < 0.5f ? WetSmoothstepDeriv(band * 2.0f) : -WetSmoothstepDeriv(2.0f - band * 2.0f))
                                    * lerp(TESR_WetnessRipple.x * rippleStrengthModifier, 0.0f, rippleT * rippleT);
                        float3 grad = float3(normalize(toCentre + 1e-5f), -deriv);
                        float3 bitangent = float3(-grad.y, grad.x, 0.0f);
                        rippleNormal = WetReorient(normalize(cross(grad, bitangent)), rippleNormal);
                    }
                }
            }
        }
    }
    return float4(rippleNormal, wetness * TESR_WetnessSplash.x);
}

// The water layer at a pixel, as CS computes it in Lighting.hlsl.
struct Wetness {
    float  darkening;   // wetnessGlossinessAlbedo: how much the albedo darkens (times porosity)
    float  gloss;       // wetnessGlossinessSpecular: how much water film there is
    float  roughness;   // the film's roughness
    float3 normal;      // the film's normal (world): ripples, flattened in puddles
};

// position: camera-relative; vertexNormal: the geometric normal (world); normal: the normal-mapped
// world normal.
Wetness GetWetness(float3 position, float3 vertexNormal, float3 normal) {
    Wetness w;
    w.darkening = 0.0f;
    w.gloss = 0.0f;
    w.roughness = 1.0f;
    w.normal = normal;
    [branch] if (!WETNESS_ON) return w;

    float3 worldPos = TESR_WetnessCamera.xyz + position;
    float distance = length(position);

    // Shore: near the water line of the cell's water.
    float waterHeight = TESR_WetnessCamera.w;
    float shoreFactor = saturate(1.0f - abs(worldPos.z - waterHeight) / TESR_WetnessParams2.w);
    float shoreFactorAlbedo = worldPos.z < waterHeight ? 1.0f : shoreFactor;

    float minWetnessAngle = saturate(max(TESR_WetnessParams.z, vertexNormal.z));
    float occlusion = WetnessOcclusion(position, vertexNormal);
    float flatness = smoothstep(TESR_WetnessParams2.x, 1.0f, minWetnessAngle);

    float4 raindrop = float4(0.0f, 0.0f, 1.0f, 0.0f);
    [branch] if (vertexNormal.z > 0.0f && TESR_WetnessData.z > 0.0f && occlusion > 0.5f && distance < TESR_WetnessRipple.w)
        raindrop = WetRainDrops(worldPos, TESR_WetnessData.w, vertexNormal, flatness);

    float rainWetness = TESR_WetnessData.x * minWetnessAngle * TESR_WetnessParams.x;
    rainWetness = max(rainWetness, raindrop.w);
    float wetness = max(shoreFactor * TESR_WetnessParams2.z, rainWetness);

    // Puddles.
    float puddleWetness = TESR_WetnessData.y * minWetnessAngle;
    float puddle = wetness;
    [branch] if (wetness > 0.0f || puddleWetness > 0.0f) {
        float3 coords = (worldPos * 0.5f + 0.5f) * 0.01f / TESR_WetnessParams.w;
        puddle = WetPerlin(coords) * 0.5f + 0.5f;
        puddle = puddle * ((minWetnessAngle / TESR_WetnessParams2.x) * TESR_WetnessParams.y * 0.25f) + 0.5f;
        puddle *= lerp(wetness, puddleWetness, saturate(puddle - 0.25f));
    }

    // Under cover nothing gets rained on; far away, none (CS's nearFactor).
    float nearFactor = smoothstep(4096.0f * 2.5f, 0.0f, distance);
    puddle *= saturate(occlusion * 2.0f) * nearFactor;

    float3 wetNormal = normalize(lerp(normal, vertexNormal, saturate(puddle)));

    float glossAlbedo = max(puddle, shoreFactorAlbedo * TESR_WetnessParams2.z);
    glossAlbedo *= glossAlbedo;

    float glossSpecular = puddle;
    if (worldPos.z < waterHeight) glossSpecular *= shoreFactor;

    flatness *= smoothstep(TESR_WetnessParams2.y, 1.0f, glossSpecular);
    float3 rippleNormal = normalize(lerp(float3(0.0f, 0.0f, 1.0f), raindrop.xyz, lerp(flatness, 1.0f, 0.5f)));
    wetNormal = WetReorient(wetNormal, rippleNormal);

    w.darkening = glossAlbedo;
    w.gloss = saturate(glossSpecular);
    w.roughness = max(saturate(1.0f - glossSpecular), 0.05f);   // CS's floor: real water is never optically perfect
    w.normal = wetNormal;
    return w;
}

// Wet albedo (CS): lerp(albedo, albedo^(1 + porosity x darkening), 0.5). Linear albedo.
float3 WetAlbedo(float3 albedo, float darkening, float porosity) {
    float d = porosity * darkening;
    return lerp(albedo, pow(max(albedo, 0.0f), 1.0f + d), 0.5f);
}

// The water film's highlight from one light (CS's GetWetnessSpecular: GGX, F0 0.02), N.L included.
float3 WetSpecular(float3 N, float3 V, float3 L, float3 light, float roughness) {
    float3 H = normalize(L + V);
    float NdotL = saturate(dot(N, L));
    float NdotV = saturate(dot(N, V)) + 1e-4f;
    float NdotH = saturate(dot(N, H));
    float VdotH = saturate(dot(V, H));
    float a = roughness * roughness;
    float a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    float D = a2 / (3.14159265f * d * d);
    float k = a * 0.5f;
    float vis = 0.25f / ((NdotL * (1.0f - k) + k) * (NdotV * (1.0f - k) + k));
    float F = 0.02f + 0.98f * pow(1.0f - VdotH, 5.0f);
    return light * (D * vis * F * NdotL);
}

// The water film's reflection weight (split sum for F0 0.02), times how much film there is.
float WetReflectance(float NdotV, float roughness, float gloss) {
    // Karis' EnvBRDFApprox, for F0 0.02.
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NdotV)) * r.x + r.y;
    float2 AB = float2(-1.04f, 1.04f) * a004 + r.zw;
    return (0.02f * AB.x + AB.y) * gloss;
}

#endif
