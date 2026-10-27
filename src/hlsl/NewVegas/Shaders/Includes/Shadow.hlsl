// Forward sun-shadow lookup for GAME shaders (objects, parallax, terrain).
//
// All four cascades live in one 2x2 atlas (TESR_ShadowAtlas).
//
// Mirrors Effects/SunShadows.fx.hlsl. Cascade selection, bias and bleed-reduction constants
// must be changed in both.
//
// TESR_ShadowCameraToLightTransform* consume CAMERA-RELATIVE world space (no
// TESR_CameraPosition added). Build it with GetShadowWorldPos() in the VS.
//
//   VS:  OUT.shadowWorldPos = GetShadowWorldPos(OUT.sPosition);
//   PS:  sunLight *= GetSunShadow(IN.shadowWorldPos, worldNormal);

// ---------------------------------------------------------------------------
// Bound by name via ShaderRecord::CreateCT; registers only decide where the values live.
//
// EVERY constant must stay explicitly pinned. Unpinned, the compiler packs them into gaps
// between the host's declared constants -- registers the engine still writes for the vanilla
// shader -- and overwrites them mid-frame.
//
// c100-c133 is clear in both profiles: heaviest host is TerrainTemplate's PS at c93 and the
// skinned VS Bones[54] ending at c97; ps_3_0 allows 224 constants, vs_3_0 256.
//
// The VS matrices are relocatable: GRASS23x00*.vso indexes InstanceData from c20 well past
// c100.
//
// Not clear in SKINNED vertex shaders: the game's bone upload goes past Bones[54]'s c97 and
// overwrote c100-c107, so actors rebuilt their world position from bone data and read the sun
// shadow at the wrong place (in practice at the player's position: actors flipped light/dark as
// the player crossed a shadow edge). The object, parallax and skin vertex shaders and SM3003/
// SM3004.vso define SHADOW_INVPROJ_REG/SHADOW_INVVIEW_REG as c240/c244 before including this file
// (upstream PR #79); pixel shaders keep c100/c104.
// ---------------------------------------------------------------------------
// A host short of registers can define SHADOW_INVVIEWPROJ_REG instead: the two matrices folded into one, the inverse
// view-projection, in 4 registers. The grass vertex shaders do -- There Stands The Grass NVSE writes c248-c249 before
// every grass batch, so they keep only c252-c255.
#ifdef SHADOW_INVVIEWPROJ_REG
row_major float4x4 TESR_InvViewProjectionTransform : register(SHADOW_INVVIEWPROJ_REG);
#else
#ifndef SHADOW_INVPROJ_REG
    #define SHADOW_INVPROJ_REG c100
#endif
#ifndef SHADOW_INVVIEW_REG
    #define SHADOW_INVVIEW_REG c104
#endif

row_major float4x4 TESR_InvProjectionTransform : register(SHADOW_INVPROJ_REG);
row_major float4x4 TESR_InvViewTransform       : register(SHADOW_INVVIEW_REG);
#endif

row_major float4x4 TESR_ShadowCameraToLightTransformNear   : register(c108);
row_major float4x4 TESR_ShadowCameraToLightTransformMiddle : register(c112);
row_major float4x4 TESR_ShadowCameraToLightTransformFar    : register(c116);
row_major float4x4 TESR_ShadowCameraToLightTransformLod    : register(c120);

float4 TESR_ShadowNearCenter   : register(c124); // xyz: centre (camera-relative world), w: radius
float4 TESR_ShadowMiddleCenter : register(c125);
float4 TESR_ShadowFarCenter    : register(c126);
float4 TESR_ShadowLodCenter    : register(c127);

float4 TESR_ShadowData        : register(c128); // y: darkness (z is INTERIOR cube texel size only)
float4 TESR_ShadowFormatData  : register(c129); // z: 1 outdoors (x, y: unused since PCF is the only mode)
float4 TESR_ShadowFade        : register(c130); // x: sunrise/sunset fade, y: shadow maps active
float4 TESR_SmoothedSunDir    : register(c131);
float4 TESR_ShadowBlur        : register(c132);
float4 TESR_ShadowForwardData : register(c133); // x: 1 when the forward path is SUPPRESSED

// Object templates top out at s7. Override BEFORE including for wider sampler arrays --
// TerrainTemplate's NormalMap[7] spans s7-s13.
#ifndef SHADOW_ATLAS_SAMPLER_REG
    #define SHADOW_ATLAS_SAMPLER_REG s9
#endif

// MUST stay on ONE line, closing brace included. ShaderTextureValue::GetSamplerStateString
// finds "register ( sN )" and reads only to the end of that line. Split, it silently falls
// back to TextureRecord's POINT/WRAP defaults. Game shaders only; Effects parse their own.
sampler2D TESR_ShadowAtlas : register(SHADOW_ATLAS_SAMPLER_REG) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };

#ifndef SUN_CROSSFADE
    #define SUN_CROSSFADE 0
#endif
#if SUN_CROSSFADE
// The cascades before the sun's last step. Not where NVR UNOFFICIAL Optimized has them (c146-c166: this build's
// skin, PBR and merged lamp constants), and without the Lod cascade (no room): the farthest shadows switch over.
// c93-c99 and c190-c198 are clear in every pixel shader that includes this (c89-c92 terrain, c100-c107 the inverse
// matrices above, c36-c88 the game's).
row_major float4x4 TESR_ShadowOldCameraToLightTransformNear   : register(c93);
row_major float4x4 TESR_ShadowOldCameraToLightTransformMiddle : register(c190);
row_major float4x4 TESR_ShadowOldCameraToLightTransformFar    : register(c194);
float4 TESR_ShadowOldNearCenter   : register(c97);
float4 TESR_ShadowOldMiddleCenter : register(c98);
float4 TESR_ShadowOldFarCenter    : register(c99);
float4 TESR_ShadowCrossFade       : register(c198);
// s10 in NVR UNOFFICIAL Optimized; ours holds the _rmaos map there (Includes/Object.hlsl).
#ifndef SHADOW_OLD_ATLAS_SAMPLER_REG
    #define SHADOW_OLD_ATLAS_SAMPLER_REG s15
#endif
sampler2D TESR_ShadowAtlasOld : register(SHADOW_OLD_ATLAS_SAMPLER_REG) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
#endif

// Normal-offset bias in SHADOW MAP TEXELS, not world units -- cascade texels span two orders
// of magnitude (~0.15 to ~3 world units at Distance 6000 / Lambda 0.95 / Resolution 2048).

#ifndef SHADOW_NORMAL_BIAS_TEXELS
    #define SHADOW_NORMAL_BIAS_TEXELS 0.0f
#endif

// Widens the depth bias at grazing incidence, where one texel spans a long run of receiver
// depth. 0 gives a constant bias.
#ifndef SHADOW_SLOPE_BIAS
    #define SHADOW_SLOPE_BIAS 1.0f
#endif

// VS presence sentinel. NVR replaces many more pixel than vertex shaders (objects ~134 vs 51,
// terrain 29 vs 2) and the game pairs them independently, so an NVR PS often runs against a
// vanilla VS whose interpolator holds undefined data. NVR vertex shaders stamp this; the PS
// checks it before shadowing.
#define SHADOW_VS_SENTINEL 1.0f
#define SHADOW_VS_PRESENT(w) (abs((w) - SHADOW_VS_SENTINEL) < 0.001f)

// D3DXMACRO from ShaderRecord::LoadShader, off [Shaders.ShadowsExteriors.Main]
// ForwardShadows. Compile-time gate; TESR_ShadowForwardData.x is the runtime one.
#ifndef FORWARD_SHADOWS
    #define FORWARD_SHADOWS 0
#endif

// ---------------------------------------------------------------------------
// Atlas sampling. The four cascades occupy the four quadrants of one texture:
//   Near (0.0, 0.0)   Middle (0.5, 0.0)
//   Far  (0.0, 0.5)   Lod    (0.5, 0.5)
// ---------------------------------------------------------------------------
// tex2Dlod, not tex2D: gradients inside the dynamic cascade branch are illegal in ps_3_0
// (X3528). The atlas has no mipmaps, so LOD 0 is equivalent.
static float ShadowSlopeBias = 0.0f;

float ShadowPCF3x3(sampler2D atlas, float2 uv, float depth, float2 quadrantOffset) {
    float texel = TESR_ShadowBlur.x;
    float2 lo = quadrantOffset + texel * 0.5f;
    float2 hi = quadrantOffset + 0.5f - texel * 0.5f;
    [branch] if (TESR_ShadowBlur.z > 0.0f) {
        float2 q = uv / texel - 0.5f;
        float2 b = floor(q);
        float2 t = q - b;
        float2 t2 = t * t, t3 = t2 * t;
        float4 cx = float4((1.0f - t.x) * (1.0f - t.x) * (1.0f - t.x), 3.0f * t3.x - 6.0f * t2.x + 4.0f, -3.0f * t3.x + 3.0f * t2.x + 3.0f * t.x + 1.0f, t3.x) / 6.0f;
        float4 cy = float4((1.0f - t.y) * (1.0f - t.y) * (1.0f - t.y), 3.0f * t3.y - 6.0f * t2.y + 4.0f, -3.0f * t3.y + 3.0f * t2.y + 3.0f * t.y + 1.0f, t3.y) / 6.0f;
        float cubicDepth = depth - 0.5f * ShadowSlopeBias;
        float cubic = 0.0f;
        [unroll] for (int cyi = 0; cyi < 4; cyi++) {
            [unroll] for (int cxi = 0; cxi < 4; cxi++) {
                float2 tapUV = clamp((b + float2(cxi - 1, cyi - 1) + 0.5f) * texel, lo, hi);
                cubic += (cubicDepth <= tex2Dlod(atlas, float4(tapUV, 0.0f, 0.0f)).x ? 1.0f : 0.0f) * cx[cxi] * cy[cyi];
            }
        }
        return cubic;
    }
    float2 p = uv / texel - 0.5f;
    float2 c = floor(p + 0.5f);
    float2 f = p - c;
    float3 wx = float3(0.5f * (0.5f - f.x) * (0.5f - f.x), 0.75f - f.x * f.x, 0.5f * (0.5f + f.x) * (0.5f + f.x));
    float3 wy = float3(0.5f * (0.5f - f.y) * (0.5f - f.y), 0.75f - f.y * f.y, 0.5f * (0.5f + f.y) * (0.5f + f.y));
    float lit = 0.0f;
    [unroll] for (int y = 0; y < 3; y++) {
        [unroll] for (int x = 0; x < 3; x++) {
            float2 tapUV = clamp((c + float2(x - 1, y - 1) + 0.5f) * texel, lo, hi);
            lit += (depth <= tex2Dlod(atlas, float4(tapUV, 0.0f, 0.0f)).x ? 1.0f : 0.0f) * wx[x] * wy[y];
        }
    }
    return lit;
}

float SampleShadowAtlas(float4 lightSpace, float2 quadrantOffset, float bias, float bleedReduction) {
    lightSpace.xyz /= lightSpace.w;
    lightSpace.x = lightSpace.x * 0.5f + 0.5f;
    lightSpace.y = lightSpace.y * -0.5f + 0.5f;

    // Fold into the correct atlas quadrant.
    lightSpace.xy = lightSpace.xy * 0.5f + quadrantOffset;

    return ShadowPCF3x3(TESR_ShadowAtlas, lightSpace.xy, lightSpace.z - bias - 1.5f * ShadowSlopeBias, quadrantOffset);
}

#if SUN_CROSSFADE
float SampleShadowAtlasOld(float4 lightSpace, float2 quadrantOffset, float bias, float bleedReduction) {
    lightSpace.xyz /= lightSpace.w;
    lightSpace.x = lightSpace.x * 0.5f + 0.5f;
    lightSpace.y = lightSpace.y * -0.5f + 0.5f;
    lightSpace.xy = lightSpace.xy * 0.5f + quadrantOffset;

    return ShadowPCF3x3(TESR_ShadowAtlasOld, lightSpace.xy, lightSpace.z - bias - 1.5f * ShadowSlopeBias, quadrantOffset);
}

float GetOldSunShadow(float3 worldPos, float3 worldNormal, float offsetScale, float bias, out float covered) {
    float4 radii = float4(TESR_ShadowOldNearCenter.w, TESR_ShadowOldMiddleCenter.w, TESR_ShadowOldFarCenter.w, 0.0f);
    float4 texelWorld = 4.0f * radii * max(TESR_ShadowBlur.x, 1.0f / 16384.0f);
    float4 offsetDistance = offsetScale * SHADOW_NORMAL_BIAS_TEXELS * texelWorld;
    offsetDistance = max(offsetDistance, offsetScale * 1.5f * texelWorld);
    const float blend = 0.9f;
    float4 distances = float4(
        length(worldPos - TESR_ShadowOldNearCenter.xyz),
        length(worldPos - TESR_ShadowOldMiddleCenter.xyz),
        length(worldPos - TESR_ShadowOldFarCenter.xyz),
        1.0f);

#define OLD_TAP_NEAR   SampleShadowAtlasOld(mul(float4(worldPos + offsetDistance.x * worldNormal, 1.0f), TESR_ShadowOldCameraToLightTransformNear),   float2(0.0f, 0.0f), bias, 0.1f)
#define OLD_TAP_MIDDLE SampleShadowAtlasOld(mul(float4(worldPos + offsetDistance.y * worldNormal, 1.0f), TESR_ShadowOldCameraToLightTransformMiddle), float2(0.5f, 0.0f), bias, 0.2f)
#define OLD_TAP_FAR    SampleShadowAtlasOld(mul(float4(worldPos + offsetDistance.z * worldNormal, 1.0f), TESR_ShadowOldCameraToLightTransformFar),    float2(0.0f, 0.5f), bias, 0.6f)

    covered = 1.0f;
    float shadow = 1.0f;
    [branch] if (distances.x < radii.x) {
        [branch] if (distances.x < radii.x * blend)
            shadow = OLD_TAP_NEAR;
        else
            shadow = lerp(OLD_TAP_NEAR, OLD_TAP_MIDDLE, smoothstep(radii.x * blend, radii.x, distances.x));
    }
    else if (distances.y < radii.y) {
        [branch] if (distances.y < radii.y * blend)
            shadow = OLD_TAP_MIDDLE;
        else
            shadow = lerp(OLD_TAP_MIDDLE, OLD_TAP_FAR, smoothstep(radii.y * blend, radii.y, distances.y));
    }
    else if (distances.z < radii.z) {
        [branch] if (distances.z < radii.z * blend)
            shadow = OLD_TAP_FAR;
        else {
            // No old Lod cascade: hand over to the new shadows across the Far cascade's border.
            shadow = OLD_TAP_FAR;
            covered = 1.0f - smoothstep(radii.z * blend, radii.z, distances.z);
        }
    }
    else {
        covered = 0.0f;
    }

#undef OLD_TAP_NEAR
#undef OLD_TAP_MIDDLE
#undef OLD_TAP_FAR

    return saturate(shadow);
}
#endif

#ifndef CONTACT_HARDENING
    #define CONTACT_HARDENING 0
#endif
#if CONTACT_HARDENING
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
float4 TESR_ContactHardeningData : register(c187);   // theirs c167: our merged lamps

static const float2 ContactDisc[12] = {
    float2(0.2041f, 0.0000f), float2(-0.2607f, 0.2388f), float2(0.0399f, -0.4547f), float2(0.3286f, 0.4286f),
    float2(-0.6030f, -0.1067f), float2(0.5712f, -0.3634f), float2(-0.1911f, 0.7107f), float2(-0.3644f, -0.7016f),
    float2(0.7906f, 0.2887f), float2(-0.8224f, 0.3395f), float2(0.3965f, -0.8472f), float2(0.2930f, 0.9341f) };

static const float2 ContactDisc8[8] = {
    float2(0.2500f, 0.0000f), float2(-0.3193f, 0.2925f), float2(0.0489f, -0.5569f), float2(0.4025f, 0.5248f),
    float2(-0.7385f, -0.1306f), float2(0.6997f, -0.4451f), float2(-0.2340f, 0.8705f), float2(-0.4467f, -0.8590f) };

float ShadowPCF2x2Clamped(float2 uv, float depth, float2 lo, float2 hi) {
    float texel = TESR_ShadowBlur.x;
    float2 p = uv / texel - 0.5f;
    float2 base = floor(p);
    float2 f = p - base;
    float2 uv0 = (base + 0.5f) * texel;
    float4 d = float4(tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv0, lo, hi), 0.0f, 0.0f)).x,
                      tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv0 + float2(texel, 0.0f), lo, hi), 0.0f, 0.0f)).x,
                      tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv0 + float2(0.0f, texel), lo, hi), 0.0f, 0.0f)).x,
                      tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv0 + texel, lo, hi), 0.0f, 0.0f)).x);
    float4 lit = depth <= d ? 1.0f : 0.0f;
    return lerp(lerp(lit.x, lit.y, f.x), lerp(lit.z, lit.w, f.x), f.y);
}

float SampleShadowAtlasPCSS(float3 position, float4x4 lightTransform, float2 quadrantOffset, float bias, bool contact);
float SampleShadowAtlasContact(float3 position, float4x4 lightTransform, float2 quadrantOffset, float bias, float bleedReduction) {
    return SampleShadowAtlasPCSS(position, lightTransform, quadrantOffset, bias, true);
}
float SampleShadowAtlasPCSS(float3 position, float4x4 lightTransform, float2 quadrantOffset, float bias, bool contact) {
    float4 lightSpace = mul(float4(position, 1.0f), lightTransform);
    lightSpace.xyz /= lightSpace.w;
    float2 uv = float2(lightSpace.x * 0.5f + 0.5f, lightSpace.y * -0.5f + 0.5f) * 0.5f + quadrantOffset;
    float depth = lightSpace.z - bias;
    float worldPerDepth = 1.0f / length(float3(lightTransform[0][2], lightTransform[1][2], lightTransform[2][2]));
    float uvPerWorld = 0.25f * length(float3(lightTransform[0][0], lightTransform[1][0], lightTransform[2][0]));
    float texel = TESR_ShadowBlur.x;
    float maxRadius = TESR_ContactHardeningData.y * texel;
    float2 lo = quadrantOffset + texel * 0.5f;
    float2 hi = quadrantOffset + 0.5f - texel * 0.5f;

    static const float2 search[5] = { float2(0.0f, 0.0f), float2(0.73f, 0.20f), float2(-0.20f, 0.73f), float2(-0.73f, -0.20f), float2(0.20f, -0.73f) };
    float radius = 0.0f;
    [branch] if (contact) {
        float casterSum = 0.0f, casters = 0.0f;
        float searchDepth = depth - ShadowSlopeBias * (0.73f * TESR_ContactHardeningData.y + 1.0f);
        [unroll] for (int s = 0; s < 5; s++) {
            float d = tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + search[s] * maxRadius, lo, hi), 0.0f, 0.0f)).x;
            float blocks = d < searchDepth ? 1.0f : 0.0f;
            casterSum += d * blocks;
            casters += blocks;
        }
        float distance = max(depth - casterSum / max(casters, 1.0f), 0.0f) * worldPerDepth;
        radius = casters < 0.5f || casters > 4.5f ? 0.0f : min(0.5f * distance * TESR_ContactHardeningData.x * uvPerWorld, maxRadius);
    }
    float w3 = TESR_ContactHardeningData.z > 0.0f ? saturate(2.0f - radius / texel) : (radius <= texel ? 1.0f : 0.0f);
    float lit = 0.0f;
    [branch] if (w3 > 0.0f) lit = w3 * ShadowPCF3x3(TESR_ShadowAtlas, uv, depth - 1.5f * ShadowSlopeBias, quadrantOffset);
    [branch] if (w3 < 1.0f) {
        float discDepth = depth - ShadowSlopeBias * (radius / texel + 1.0f);
        float2 turn = float2(1.0f, 0.0f);
        [branch] if (TESR_ContactHardeningData.z > 0.0f)
            sincos(6.2831853f * frac(52.9829189f * frac(dot(floor(uv / texel * 3.0f), float2(0.06711056f, 0.00583715f)))), turn.y, turn.x);
        float disc = ShadowPCF2x2Clamped(uv, discDepth, lo, hi);
        [unroll] for (int i = 0; i < 8; i++) {
            float2 o = ContactDisc8[i];
            disc += ShadowPCF2x2Clamped(uv + float2(o.x * turn.x - o.y * turn.y, o.x * turn.y + o.y * turn.x) * radius, discDepth, lo, hi);
        }
        lit += (1.0f - w3) * disc / 9.0f;
    }
    return lit;
}

float SampleShadowCascade(float3 position, float4x4 lightTransform, float2 quadrantOffset, float bias, float bleedReduction) {
    [branch] if (TESR_ContactHardeningData.x > 0.0f)
        return SampleShadowAtlasContact(position, lightTransform, quadrantOffset, bias, bleedReduction);
    return SampleShadowAtlas(mul(float4(position, 1.0f), lightTransform), quadrantOffset, bias, bleedReduction);
}
#endif

// ---------------------------------------------------------------------------
// Camera-relative world position from clip space. Call in the VS and interpolate: it is exact
// under perspective-correct interpolation and costs one interpolator.
// ---------------------------------------------------------------------------
float3 GetShadowWorldPos(float4 clipPos) {
#ifdef SHADOW_INVVIEWPROJ_REG
    // The view is affine, so dividing after it is the same as dividing before.
    float4 worldPos = mul(clipPos, TESR_InvViewProjectionTransform);
    return worldPos.xyz / worldPos.w;
#else
    float4 viewPos = mul(clipPos, TESR_InvProjectionTransform);
    viewPos /= viewPos.w;
    return mul(viewPos, TESR_InvViewTransform).xyz;
#endif
}

// ---------------------------------------------------------------------------
// Camera-relative world DIRECTION from a clip-space direction (w = 0), e.g.
// mul(ModelViewProj, float4(objectNormal, 0)). The inverse projection and view undo the
// projection exactly, so this recovers the model-to-world rotation the vertex shader has no
// matrix for. No divide: a direction keeps w = 0.
// ---------------------------------------------------------------------------
float3 GetShadowWorldDir(float4 clipDir) {
#ifdef SHADOW_INVVIEWPROJ_REG
    return mul(clipDir, TESR_InvViewProjectionTransform).xyz;
#else
    return mul(mul(clipDir, TESR_InvProjectionTransform), TESR_InvViewTransform).xyz;
#endif
}

// ---------------------------------------------------------------------------
// Flat face normal from screen-space derivatives of the interpolated world position. Object
// shaders carry their normal in TANGENT space, so no world normal is available to the bias.
//
// MUST be called from the top level of the pixel shader: ddx/ddy are illegal inside dynamic
// flow control.
// ---------------------------------------------------------------------------
float3 GetShadowGeometricNormal(float3 worldPos) {
    float3 n = normalize(cross(ddx(worldPos), ddy(worldPos)));

    // worldPos is camera-relative, so the camera is at the origin and the outward normal is
    // the one facing it. Independent of winding.
    return n * sign(dot(n, -worldPos));
}

float SunCascadeTap(float c, float3 worldPos, float3 worldNormal, float4 offsetDistance, float bias) {
    float4x4 lightTransform = c < 0.5f ? TESR_ShadowCameraToLightTransformNear : c < 1.5f ? TESR_ShadowCameraToLightTransformMiddle :
                              c < 2.5f ? TESR_ShadowCameraToLightTransformFar : TESR_ShadowCameraToLightTransformLod;
    float2 quadrant = c < 0.5f ? float2(0.0f, 0.0f) : c < 1.5f ? float2(0.5f, 0.0f) : c < 2.5f ? float2(0.0f, 0.5f) : float2(0.5f, 0.5f);
    float offset = c < 0.5f ? offsetDistance.x : c < 1.5f ? offsetDistance.y : c < 2.5f ? offsetDistance.z : offsetDistance.w;
    float3 position = worldPos + offset * worldNormal;
#if CONTACT_HARDENING
    // Switched off in game (TESR_ContactHardeningData.x 0): the same lookup as shaders built without it.
    [branch] if (TESR_ContactHardeningData.x > 0.0f)
        return SampleShadowAtlasPCSS(position, lightTransform, quadrant, bias, c < 1.5f);
#endif
    return SampleShadowAtlas(mul(float4(position, 1.0f), lightTransform), quadrant, bias, 0.0f);
}

// 1.0 in full light, towards 0 in shadow. Multiply the SUN term by it, before ambient.
float GetSunShadow(float3 worldPos, float3 worldNormal) {
    // Nonzero SUPPRESSES the forward path; SunShadows.fx reads the same constant and takes
    // over deferred. A missing constant reads zero and leaves forward running.
    if (TESR_ShadowForwardData.x) return 1.0f;

    // Sun shadows never apply indoors. Dedicated flag, not ShadowFade.y below -- that one is
    // shared with ShadowsInteriors.fx's own darkness calc and means something else indoors
    // (interior point-shadows enabled), so it can't double as this gate. Without this check,
    // an interior object shader would fall through to stale exterior cascade data left over
    // from the last time the player was outside.
    if (!TESR_ShadowFormatData.z) return 1.0f;

    // Shadow maps switched off entirely (setting), or sun below horizon.
    if (!TESR_ShadowFade.y) return 1.0f;

    // Push the sample along the normal, scaled by how grazing the sun is.
    float NdotL = dot(worldNormal, TESR_SmoothedSunDir.xyz);
    float offsetScale = saturate(1.0f - NdotL);

    float4 radii = float4(TESR_ShadowNearCenter.w, TESR_ShadowMiddleCenter.w,
                          TESR_ShadowFarCenter.w,  TESR_ShadowLodCenter.w);

    // Texel world size per cascade. GetCascadeViewProj's ortho box is 2*radius across, and the
    // atlas is two cascades wide, so with TESR_ShadowBlur.x = 1/atlasResolution:
    //     cascadeResolution = 0.5 / TESR_ShadowBlur.x
    //     texelWorldSize    = 4 * radius * TESR_ShadowBlur.x
    // The floor keeps a zero constant from producing an infinite offset.
    float4 texelWorld = 4.0f * radii * max(TESR_ShadowBlur.x, 1.0f / 16384.0f);
    float4 offsetDistance = offsetScale * SHADOW_NORMAL_BIAS_TEXELS * texelWorld;
    offsetDistance = max(offsetDistance, offsetScale * 1.5f * texelWorld);
    ShadowSlopeBias = 2.0f * TESR_ShadowBlur.x * min(sqrt(saturate(1.0f - NdotL * NdotL)) / max(NdotL, 0.05f), 5.0f);

    const float baseBias = 0.0002f;

    // Slope-scaled variance floor: bias drives minVariance, the slack Chebyshev gets before
    // calling a texel occluded.
    float bias = baseBias * (1.0f + SHADOW_SLOPE_BIAS * offsetScale);

    // Fraction of the way to a cascade's border at which the cross-fade into the next begins.
    const float blend = 0.9f;

    // Distance to each cascade centre, cross-faded over the outer 10%. Circular boundaries,
    // matching SunShadows.fx: selecting on the square light-space NDC box steps visibly.
    float4 distances = float4(
        length(worldPos - TESR_ShadowNearCenter.xyz),
        length(worldPos - TESR_ShadowMiddleCenter.xyz),
        length(worldPos - TESR_ShadowFarCenter.xyz),
        length(worldPos - TESR_ShadowLodCenter.xyz));

    // Sample inside the branch, not before it. A pixel needs one cascade, or two in the outer
    // 10% where they cross-fade; sampling all four up front cost four atlas fetches and four
    // matrix transforms on every shadowed pixel, and the forward path pays that per object.
    // Legal here only because SampleShadowAtlas uses tex2Dlod -- a gradient instruction under
    // dynamic flow control is X3528 in ps_3_0. The atlas has no mipmaps, so LOD 0 is exact.
#if CONTACT_HARDENING
#define SHADOW_TAP_NEAR   SampleShadowCascade(worldPos + offsetDistance.x * worldNormal, TESR_ShadowCameraToLightTransformNear,   float2(0.0f, 0.0f), bias, 0.1f)
#define SHADOW_TAP_MIDDLE SampleShadowCascade(worldPos + offsetDistance.y * worldNormal, TESR_ShadowCameraToLightTransformMiddle, float2(0.5f, 0.0f), bias, 0.2f)
#else
#define SHADOW_TAP_NEAR   SampleShadowAtlas(mul(float4(worldPos + offsetDistance.x * worldNormal, 1.0f), TESR_ShadowCameraToLightTransformNear),   float2(0.0f, 0.0f), bias, 0.1f)
#define SHADOW_TAP_MIDDLE SampleShadowAtlas(mul(float4(worldPos + offsetDistance.y * worldNormal, 1.0f), TESR_ShadowCameraToLightTransformMiddle), float2(0.5f, 0.0f), bias, 0.2f)
#endif
#define SHADOW_TAP_FAR    SampleShadowAtlas(mul(float4(worldPos + offsetDistance.z * worldNormal, 1.0f), TESR_ShadowCameraToLightTransformFar),    float2(0.0f, 0.5f), bias, 0.6f)
#define SHADOW_TAP_LOD    SampleShadowAtlas(mul(float4(worldPos + offsetDistance.w * worldNormal, 1.0f), TESR_ShadowCameraToLightTransformLod),    float2(0.5f, 0.5f), bias, 0.8f)

    float cascade = -1.0f, fade = 0.0f;
    [flatten] if (distances.x < radii.x) { cascade = 0.0f; fade = smoothstep(radii.x * blend, radii.x, distances.x); }
    else if (distances.y < radii.y) { cascade = 1.0f; fade = smoothstep(radii.y * blend, radii.y, distances.y); }
    else if (distances.z < radii.z) { cascade = 2.0f; fade = smoothstep(radii.z * blend, radii.z, distances.z); }
    else if (distances.w < radii.w) { cascade = 3.0f; fade = smoothstep(radii.w * blend, radii.w, distances.w); }
    float3 hashP = frac(worldPos * 7.1031f);
    hashP += dot(hashP, hashP.yzx + 33.33f);
    float dither = frac((hashP.x + hashP.y) * hashP.z);
    cascade += fade > dither ? 1.0f : 0.0f;
    float shadow = 1.0f;
    [branch] if (cascade >= 0.0f && cascade < 3.5f)
        shadow = SunCascadeTap(cascade, worldPos, worldNormal, offsetDistance, bias);

#undef SHADOW_TAP_NEAR
#undef SHADOW_TAP_MIDDLE
#undef SHADOW_TAP_FAR
#undef SHADOW_TAP_LOD

    shadow = saturate(shadow);

#if SUN_CROSSFADE
    [branch] if (TESR_ShadowCrossFade.x > 0.0f) {
        float covered;
        float oldShadow = GetOldSunShadow(worldPos, worldNormal, offsetScale, bias, covered);
        shadow = lerp(shadow, oldShadow, TESR_ShadowCrossFade.x * covered);
    }
#endif

    // Fade out as the sun approaches the horizon, matching SunShadows.fx.
    shadow = lerp(shadow, 1.0f, saturate(TESR_ShadowFade.x));

    return shadow;
}
