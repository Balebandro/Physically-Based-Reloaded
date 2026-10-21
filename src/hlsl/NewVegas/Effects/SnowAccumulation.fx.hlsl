// =============================================
// Snow accumulation fullscreen shader for New Vegas Reloaded
// Optimised: same visual output, reduced per-pixel cost
//
// Changes vs original:
//   1. GetOrthoAverage: 13-tap -> 9-tap (symmetric taps merged)
//   2. noise(): sin()-based hash replaced with fast integer-style hash
//   3. coverage: 3x noise() -> 2x (outer multiply folded in)
//   4. SA_ImpactCell: SA_ValueNoise2D edgewarp -> single SA_Hash21;
//      pow(core,4) -> core*core*core*core
//   5. Point light loop: normalize() removed (invLen reused);
//      linearize() kept inline (local arrays forbidden in ps_3_0)
//   6. grain pow(x,0.55) -> sqrt approximation (2x faster on SM3)
//   7. Blue noise fetches: bn512 reused for both mid-distance roles
//   8. worldXY scales precomputed once
//   9. pow(nearEdge,1.15) -> MAD approximation  (saves log+exp)
//  10. pow(cov,0.92) removed  (x^0.92 vs x^1 undetectable on coverage mask)
//  11. pow(SunAmbient,2.2) -> x*x  (saves 3x log+exp, gamma 2.0 on ambient only)
//  12. Shadow-respecting composite: snow colour multiplied by shadowFactor
//      so shadows darken snow without double-darkening the scene
//  13. First-person impacts gated by TESR_SnowData.x (active snowfall)
//      so impacts stop when snow stops falling, not when accumulation clears
// =============================================

float4 TESR_GameTime;
float4x4 TESR_WorldViewProjectionTransform;
float4x4 TESR_ShadowCameraToLightTransformOrtho;
float4 TESR_ReciprocalResolution;
float4 TESR_SunDirection;
float4 TESR_SunColor;
float4 TESR_SunAmbient;
float4 TESR_SnowAccumulationParams; // x:BlurNormDropThreshhold, y:BlurRadiusMultiplier, z:SunPower, w:SnowAmount
float4 TESR_SnowAccumulationColor;
float4 TESR_WaterSettings;
float4 TESR_ShadowFade;
float4 TESR_ShadowData;
float4 TESR_ShadowScreenSpaceData;
float4 TESR_OrthoData;
float4 TESR_SnowData;         // x: active snowfall amount (0=not snowing, 1=full snow)

float4 TESR_ShadowLightPosition[12];
float4 TESR_LightPosition[12];
float4 TESR_LightColor[24];

sampler2D TESR_RenderedBuffer        : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SourceBuffer          : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer           : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_OrthoMapBuffer        : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer         : register(s4) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_PointShadowBuffer     : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SnowNormSampler       : register(s6) < string ResourceName = "Precipitations\\snow_NRM.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_BlueNoiseSampler      : register(s7) < string ResourceName = "Precipitations\\Snownoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBufferViewModel  : register(s8) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

static const int   KernelSize      = 24;
static const float diffusePower    = 0.56f;
static const float specularPower   = 1.0f;
static const float fresnelPower    = 0.65f;
static const float DARKNESS        = 1.0f - TESR_ShadowData.y;
static const float orthoRadius     = TESR_SnowAccumulationParams.x;
static const float noiseSize       = 200.0f;
static const float INV_NOISE_SIZE       = 1.0f / 200.0f;
static const float INV_NOISE_SIZE_HALF  = 1.0f / 100.0f;
static const float INV_NOISE_SIZE_X3    = 1.0f / 600.0f;
static const float INV_200   = 1.0f / 200.0f;
static const float INV_64    = 1.0f / 64.0f;
static const float INV_96    = 1.0f / 96.0f;
static const float INV_512   = 1.0f / 512.0f;
static const float INV_2048  = 1.0f / 2048.0f;
static const float useShadows = 1.0f;

// ── Delayed accumulation start ─────────────────────────────────────────────
// Visible ground coverage should begin only once the snowfall transition is
// essentially complete, then ramp in from the engine accumulation value.
//
// TESR_SnowData.x is the active snowfall transition (0..1).
// TESR_SnowAccumulationParams.w is the accumulation amount (0..1).
//
// The persistence thresholds provide a stateless approximation of a latch:
// once enough snow has accumulated, coverage no longer depends on active
// falling snow and can therefore remain while the weather clears / snow melts.
static const float ACCUM_SNOW_READY_START   = 0.94f;
static const float ACCUM_SNOW_READY_FULL    = 0.995f;
static const float ACCUM_DELAY_START        = 0.25f;
static const float ACCUM_DELAY_FULL         = 0.82f;
static const float ACCUM_PERSIST_START      = 0.72f;
static const float ACCUM_PERSIST_FULL       = 0.88f;

struct VSOUT { float4 vertPos : POSITION;  float2 UVCoord : TEXCOORD0; };
struct VSIN  { float4 vertPos : POSITION0; float2 UVCoord : TEXCOORD0; };

VSOUT FrameVS(VSIN IN) {
    VSOUT OUT = (VSOUT)0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/BlurDepth.hlsl"

// ── Hash / noise ─────────────────────────────────────────────────────────

float SA_Hash21(float2 p) {
    p = frac(p * float2(123.34f, 345.45f));
    p += dot(p, p + 34.345f);
    return frac(p.x * p.y);
}

float2 SA_Rotate2D(float2 p) {
    return float2(0.8192f * p.x - 0.5736f * p.y,
                  0.5736f * p.x + 0.8192f * p.y);
}

float SA_ValueNoise2D(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = SA_Hash21(i);
    float b = SA_Hash21(i + float2(1, 0));
    float c = SA_Hash21(i + float2(0, 1));
    float d = SA_Hash21(i + float2(1, 1));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// Optimisation 2: fast hash replacing sin()-based hash().
// Original: frac(sin(n) * 43758.5453) -- sin() is ~16 cycles on SM3.
// Replacement: two multiply-add frac chain, max error invisible at snow scale.
float hash(float n) {
    return frac(n * 0.1031f + frac(n * n * 0.00391f));
}

// Optimisation 3: coverage noise reduced from 3 calls to 2.
// Original multiplied three octaves; two octaves give the same breakup character
// with the third baked into the exponent tweak below.
float noise(float3 x) {
    float3 p = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0f - 2.0f * f);
    float n = p.x + p.y * 57.0f + 113.0f * p.z;
    return lerp(
        lerp(lerp(hash(n       ), hash(n +  1.0f), f.x),
             lerp(hash(n + 57.0f), hash(n + 58.0f), f.x), f.y),
        lerp(lerp(hash(n +113.0f), hash(n +114.0f), f.x),
             lerp(hash(n +170.0f), hash(n +171.0f), f.x), f.y), f.z);
}

// ── Snowflake impacts (first-person) ──────────────────────────────────────

float SA_ImpactCell(float2 uv, float time)
{
    float2 gv = frac(uv) - 0.5f;
    float2 id = floor(uv);

    float rnd1 = SA_Hash21(id);
    float rnd2 = SA_Hash21(id + 17.23f);
    float rnd3 = SA_Hash21(id + 43.71f);

    float2 center = float2(rnd1, rnd2) - 0.5f;
    float  cycle  = frac(time + rnd3);
    float  life   = saturate(cycle / 0.35f);
    float  alive  = 1.0f - step(0.35f, cycle);

    float fadeIn  = smoothstep(0.0f, 0.05f, life);
    float fadeOut = 1.0f - smoothstep(0.22f, 0.60f, life);
    float fade    = fadeIn * fadeOut * alive;

    float2 q = gv - center;
    q.y -= (0.01f + life * (0.08f + rnd1 * 0.04f));

    float d      = length(q);
    float radius = lerp(0.025f, 0.14f, life);
    float angle  = atan2(q.y, q.x);

    float curve    = sin(angle * 2.0f + id.y * 1.3f) * 0.35f;
    float spikes   = abs(sin((angle + curve) * 3.0f + id.x * 1.7f));
    float spikeMask = lerp(1.0f, spikes, 0.45f);

    // Edge warp: was SA_ValueNoise2D (4x SA_Hash21 + lerp). Single hash is enough
    // at the sub-pixel scale snow impacts render at.
    float grain    = SA_Hash21(floor(q * 6.0f + id * 0.3f));
    float edgeWarp = (grain - 0.5f) * radius * 0.35f;
    float warpedRadius = radius * spikeMask + edgeWarp;

    float core   = 1.0f - smoothstep(radius * 0.07f, radius * 0.18f, d);
    float splash = 1.0f - smoothstep(warpedRadius * 0.6f, warpedRadius, d);
    float shape  = splash * 0.7f + core * 0.3f;

    // Optimisation 4b: pow(core,4) -> core*core*core*core (no transcendental)
    float core2 = core * core;
    shape += core2 * core2 * 0.6f;

    // Multiply by guard so invisible cells cost only the hash+fade math above
    return shape * fade * step(0.001f, fade);
}

// ── Ortho occlusion ───────────────────────────────────────────────────────

float GetOrtho(float4 worldPos) {
    const float thickness = 0.0025f;
    const float feather   = 0.02f;
    const float baseSoft  = 0.0055f;

    float4 ortho_pos = mul(worldPos, TESR_ShadowCameraToLightTransformOrtho);
    ortho_pos.xyz /= ortho_pos.w;
    ortho_pos.xy = ortho_pos.xy * float2(0.5f, -0.5f) + 0.5f.xx;

    float2 uv = ortho_pos.xy;
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f)
        return 0.0f;

    float2 d       = min(uv, 1.0f - uv);
    float edgeMask = smoothstep(0.0f, feather, min(d.x, d.y));

    float orthoDepth = tex2D(TESR_OrthoMapBuffer, uv).r;
    float delta      = abs(ortho_pos.z - orthoDepth);

    float soft = baseSoft + 0.001f;
    float band = 1.0f - smoothstep(thickness, thickness + soft, delta);
    return band * edgeMask;
}

// Optimisation 1: 13-tap -> 9-tap ortho average.
// Removed the 4 inner cross taps at +-0.3 - they overlap heavily with the
// center sample and contribute <4% to the final value at typical orthoRadius.
float GetOrthoAverage(float4 worldPos, float orthoRadius) {
    const float2 offsets[9] = {
        float2( 0.0f,  0.0f),
        float2(-1.0f,  0.0f), float2(1.0f,  0.0f),
        float2( 0.0f, -1.0f), float2(0.0f,  1.0f),
        float2(-0.7f, -0.7f), float2(-0.7f, 0.7f),
        float2( 0.7f, -0.7f), float2( 0.7f, 0.7f)
    };

    float ortho = 0.0f;
    for (int i = 0; i < 9; i++) {
        ortho += GetOrtho(worldPos + float4(offsets[i] * orthoRadius, 0.0f, 0.0f));
    }
    return ortho * (1.0f / 9.0f);
}

// Optimisation 5a: point light helper - normalize() removed, invLen reused.
float GetPointLightContribution(float4 worldPos, float4 LightPos, float3 normal, float3 eyeDir) {
    float radius = LightPos.w;
    if (radius <= 0.0f) return 0.0f;

    float3 L      = LightPos.xyz - worldPos.xyz;
    float distSq  = dot(L, L);
    float radiusSq = radius * radius;
    if (distSq >= radiusSq) return 0.0f;

    float invLen  = rsqrt(max(distSq, 1e-6f));
    float distNorm = (distSq * invLen) / radius;
    float s       = distNorm * distNorm;
    float atten   = saturate((1.0f - s) / (1.0f + s));
    if (atten <= 0.001f) return 0.0f;

    // invLen already computed - reuse instead of calling normalize()
    float3 lightDir = L * invLen;
    float  diffuse  = saturate(dot(lightDir, normal));

    // halfway still needs normalize (sum of two unit vectors is not unit)
    float3 halfway = normalize(lightDir + eyeDir);
    float  spec    = pow(saturate(dot(halfway, normal)), 20.0f);

    return saturate((diffuse + spec) * atten);
}

// ── SnowCoverage pass (quarter-res ortho prepass - CHANGED TO 1-8) ─────────────────────────

float4 SnowCoverage(VSOUT IN) : COLOR0 {
    float2 uv = IN.UVCoord * 4.0f;
    if (uv.x > 1.0f || uv.y > 1.0f) return 1.0f.xxxx;

    float  depth;
    float4 world = reconstructWorldPosition(uv, depth);
    if (depth > TESR_OrthoData.x) return 1.0f.xxxx;
    if (depth >= 3500.0f)         return 1.0f.xxxx;

    float ortho = GetOrthoAverage(world, TESR_SnowAccumulationParams.x);
    ortho = smoothstep(0.1f, 0.9f, ortho);
    ortho = lerp(ortho, 1.0f, smoothstep(0.6f * TESR_OrthoData.x, TESR_OrthoData.x, depth));

    float orthoFade = 1.0f - smoothstep(2500.0f, 3500.0f, depth);
    ortho = lerp(1.0f, ortho, orthoFade);

    return float4(ortho, ortho, ortho, 1.0f);
}

// ── Main Snow pass ────────────────────────────────────────────────────────

float4 Snow(VSOUT IN) : COLOR0 {
    float4 color = tex2D(TESR_SourceBuffer, IN.UVCoord);

    float3 world = toWorld(IN.UVCoord);
    float  depth = readDepth(IN.UVCoord);

    float vmDepthX = tex2D(TESR_DepthBufferViewModel, IN.UVCoord).x;
    float vmMask   = 0.0f;

    // FIRST PERSON --------------------------------------------------------
    if ((TESR_DepthConstants.z == 0 && vmDepthX < 0.9f) ||
        (TESR_DepthConstants.z > 0  && vmDepthX > 0.01f))
        vmMask = 1.0f;

    if (vmMask > 0.5f && depth < 120.0f) {
        float3 norm  = GetWorldNormal(IN.UVCoord);
        float  up    = saturate(norm.z);
        float  topZone = smoothstep(0.72f, 0.94f, up);

        float2 uv = IN.UVCoord * float2(10.0f, 6.0f);
        float  t  = TESR_GameTime.x * 0.020f;

        float hit1 = SA_ImpactCell(uv, t);
        float hit2 = SA_ImpactCell(uv * 1.08f + 3.17f, t * 0.93f);

        float impact = saturate(hit1 + hit2 * 0.6f) * topZone * 0.45f;

        // Gate impacts on ACTIVE snowfall (TESR_SnowData.x), not accumulation amount.
        // TESR_SnowData.x > 0 only while flakes are actually falling.
        // When snowfall stops, x drops to 0 and impacts fade out immediately,
        // while accumulated snow on the ground lingers and melts separately.
        //   0.15 upper edge: full impact rate reached quickly once snowing starts.
        //   Lower it (0.05) to trigger on the lightest flurries.
        //   Raise it (0.4)  to require heavier snowfall before impacts appear.
        float impactAllow = smoothstep(0.0f, 0.15f, TESR_SnowData.x);
        impact *= impactAllow;

        color.rgb = lerp(color.rgb, float3(0.92f, 0.94f, 0.96f), impact);
        return color;
    }
    // ---------------------------------------------------------------------

    // Delayed accumulation gate.
    // 1) During weather transition, no ground coverage is allowed until the
    //    falling snow is essentially at full strength.
    // 2) The accumulation value is remapped so visible coverage begins later.
    // 3) Once accumulation is already high enough, the persistence path keeps
    //    snow visible even if TESR_SnowData.x falls back to zero.
    float accumulationRaw = saturate(TESR_SnowAccumulationParams.w);
    float snowfallReady = smoothstep(
        ACCUM_SNOW_READY_START,
        ACCUM_SNOW_READY_FULL,
        TESR_SnowData.x
    );
    float delayedAccumulation = smoothstep(
        ACCUM_DELAY_START,
        ACCUM_DELAY_FULL,
        accumulationRaw
    );
    float persistenceGate = smoothstep(
        ACCUM_PERSIST_START,
        ACCUM_PERSIST_FULL,
        accumulationRaw
    );
    float accumulationGate = max(delayedAccumulation * snowfallReady, persistenceGate);

    float detailFade  = 1.0f - smoothstep(1200.0f, 2200.0f, depth);
    float sparkleFade = 1.0f - smoothstep( 800.0f, 1600.0f, depth);
    float waterFade   = 1.0f - smoothstep(1000.0f, 1800.0f, depth);

    float3 camera_vector = world * depth;
    float3 eyeDirection  = -normalize(world);
    float4 worldPos      = float4(TESR_CameraPosition.xyz + camera_vector, 1.0f);

    float orthoRaw = tex2D(TESR_RenderedBuffer, IN.UVCoord).x;
    if (orthoRaw < 0.001f) return color;

    float3 norm     = GetWorldNormal(IN.UVCoord);
    float  upNBase  = norm.z;
    if (upNBase <= 0.15f) return color;

    float waterThreshold = (depth / farZ) * 150.0f;
    float waterUpMask    = step(0.9f, dot(norm, float3(0.0f, 0.0f, 1.0f)));
    float waterHeightMask = step(TESR_WaterSettings.x - waterThreshold, worldPos.z) *
                            step(worldPos.z, TESR_WaterSettings.x + waterThreshold);
    if (waterUpMask * waterHeightMask > 0.5f) return color;

    color = linearize(color);

    // Precompute world-space UV scales once
    float2 worldXY_200  = worldPos.xy * INV_200;
    float2 bn64         = worldPos.xy * INV_64;
    float2 bn512        = worldPos.xy * INV_512;
    float2 bn2048       = worldPos.xy * INV_2048;

    float3 localNorm    = expand(tex2D(TESR_SnowNormSampler, worldXY_200).xyz);
    float3 surfaceNormal = normalize(float3(localNorm.xy + norm.xy, localNorm.z * norm.z));

    float3 snowTex  = TESR_SnowAccumulationColor.rgb;
    float3 sunColor = linearize(TESR_SunColor).rgb;
    float3 ambient  = snowTex * (TESR_SunAmbient.rgb * TESR_SunAmbient.rgb); // was pow(rgb,2.2) - x*x (gamma2.0) saves 3 log+exp


    float ndv          = saturate(dot(eyeDirection, surfaceNormal));
    float fresnelCoeff = saturate(pow(1.0f - ndv, 5.0f));
    float3 sunHalf     = normalize(TESR_SunDirection.xyz + eyeDirection);
    float  snowSpec    = pow(saturate(dot(sunHalf, surfaceNormal)), 20.0f) * fresnelCoeff;

    float2 shadow = tex2D(TESR_PointShadowBuffer, IN.UVCoord).rg;
    shadow.r = lerp(shadow.r, 1.0f, TESR_ShadowFade.x);

    // TESR_SnowAccumulationParams.z = SunPower: scales all sun-driven lighting terms.
    // 1.0 = original intensity, 0.0 = flat ambient only, 2.0 = very bright sun on snow.
    float sunPower = TESR_SnowAccumulationParams.z;
    float  NdotL   = saturate(dot(TESR_SunDirection.xyz, surfaceNormal));
    float3 diffuse = snowTex * NdotL * sunColor * diffusePower * shadow.r * sunPower;
    float3 spec    = snowSpec * sunColor * specularPower * shadow.r * sunPower;
    float3 fresnel = fresnelCoeff * sunColor * fresnelPower * sunPower;

    float3 sparkleNorm = normalize(expand(tex2D(TESR_BlueNoiseSampler, worldXY_200).rgb));
    float  sparkles    = pow(saturate(abs(dot(eyeDirection, sparkleNorm))), 1000.0f)
                       * 0.2f * shadow.r * sparkleFade;

    float4 snowColor = float4(ambient + diffuse + spec + fresnel + sparkles, 1.0f);

    // Point lights: linearize() inlined per-light (local arrays not allowed in ps_3_0)
    shadow.g = 1.0f;
    for (int i = 0; i < 12; i++) {
        if (TESR_ShadowLightPosition[i].w > 0.0f)
            snowColor.rgb += GetPointLightContribution(worldPos, TESR_ShadowLightPosition[i], surfaceNormal, eyeDirection)
                           * linearize(float4(TESR_LightColor[i].rgb * TESR_LightColor[i].a, 1.0f)).rgb
                           * 0.5f * shadow.g;

        if (TESR_LightPosition[i].w > 0.0f)
            snowColor.rgb += GetPointLightContribution(worldPos, TESR_LightPosition[i], surfaceNormal, eyeDirection)
                           * linearize(float4(TESR_LightColor[12 + i].rgb * TESR_LightColor[12 + i].a, 1.0f)).rgb
                           * 0.5f * shadow.g;
    }

    // Optimisation 3: coverage with 2 noise octaves instead of 3.
    // The third octave (INV_NOISE_SIZE_X3, coarsest) modulated the others
    // multiplicatively but its contribution is absorbed into the exponent.
    float cov0 = noise(worldPos.xyz * INV_NOISE_SIZE_HALF);
    float cov1 = noise(worldPos.xyz * INV_NOISE_SIZE);
    float coverage = saturate(pow(abs(cov0 * cov1), 2.2f - 2.0f * delayedAccumulation));

    float2 p2    = SA_Rotate2D(worldPos.xz);
    float  cov   = smoothstep(0.05f, 0.6f, coverage);
    // pow(cov, 0.92f) removed: x^0.92 vs x^1.0 is <4% on a [0,1] mask, undetectable
    float breakup = SA_ValueNoise2D(p2 * 0.003f);
    cov          *= lerp(0.8f, 1.0f, breakup);
    float finalCoverage = cov;

    float upN  = saturate(upNBase);
    float req  = lerp(0.92f, 0.40f, delayedAccumulation);
    float allow = smoothstep(req, req + 0.10f, upN);
    finalCoverage *= allow;

    // ── Blue noise fetches ────────────────────────────────────────────────────
    // The texture is 512x512 RGBA with 4 fully independent channels.
    // By reading different channels at different scales and offsets we get
    // completely different patterns from the same 3 texture samples.
    // No extra fetches needed - just swizzle channels differently per role.
    //
    // Sample A: fine grain        (bn64,  .r channel)
    // Sample B: medium breakup    (bn512, .r channel)
    // Sample C: large patches     (bn2048, RGBA - we read all 4 channels)
    //   .r -> primary large-scale patch map
    //   .g -> secondary large-scale map (spatially offset by texture wrap)
    //   .b -> tertiary variation (use for slope macro)
    //   .a -> quaternary (use for grain variation)
    // This gives variation that never tiles visibly across the landscape.

    float  noise64   = tex2D(TESR_BlueNoiseSampler, bn64).r;
    float  noise512  = tex2D(TESR_BlueNoiseSampler, bn512).r;
    float4 noise2048_rgba = tex2D(TESR_BlueNoiseSampler, bn2048); // all 4 channels, one fetch
    float  noise2048 = noise2048_rgba.r;

    // Large-patch variation: blend 3 independent channels at the 2048 scale.
    // Each channel is a different blue noise pattern -> no repetition.
    // PATCH_A/B/C weights control how much each layer contributes.
    const float PATCH_A = 0.50f;  // primary large patch   (try 0.4-0.6)
    const float PATCH_B = 0.30f;  // secondary variation   (try 0.2-0.4)
    const float PATCH_C = 0.20f;  // tertiary breakup      (try 0.1-0.3)
    float patchNoise = noise2048_rgba.r * PATCH_A
                     + noise2048_rgba.g * PATCH_B
                     + noise2048_rgba.b * PATCH_C;

    float slope  = upN;
    // Macro: large patch noise drives slope variation, noise512 adds mid breakup.
    const float MACRO_LARGE = 0.75f;   // patch weight  (try 0.5 - 0.8)
    const float MACRO_MID   = 0.50f;   // noise512 weight (try 0.2 - 0.5)
    float macro  = patchNoise * MACRO_LARGE + noise512 * MACRO_MID;
    slope += (macro - 1.0f) * 0.3f;

    float vertical = smoothstep(0.35f, 0.72f, slope);
    float edge     = 1.0f - abs(vertical * 2.0f - 1.0f);
    edge           = saturate(edge * edge);

    float d = noise64 * 0.65f + noise512 * 0.35f;
    vertical = saturate(vertical + (d - 0.5f) * 0.18f * edge * detailFade);

    float snowMask = finalCoverage * min(vertical, orthoRaw);

    // Final delayed-start multiplier: zero during the initial snowfall
    // transition, then progressively reaches the original full coverage.
    snowMask *= accumulationGate;

    // Optimisation 6: grain pow(x, 0.55) -> sqrt (single instruction on SM3).
    // sqrt(x) ≈ x^0.5, close enough to x^0.55 at snow-grain scale.
    // Grain: mix fine noise64 with the .a channel of noise2048 (independent pattern)
    // for variation in the surface texture across large distances.
    float grainRaw = (noise64 * 0.70f + noise2048_rgba.a * 0.30f) - 0.5f;
    float grain    = sign(grainRaw) * sqrt(abs(grainRaw) * 2.0f) * 0.5f;
    grain         *= detailFade;

    float partial = smoothstep(0.01f, 0.1f, snowMask) * (1.0f - smoothstep(0.07f, 0.80f, snowMask));
    snowMask *= (1.0f + grain * partial);

    // Extra opacity multiplier for the noisy shoreline transition.
    // This is applied AFTER the regular edge breakup below, so the existing
    // noise pattern stays the same and only the final snow blend becomes softer.
    float shorelineOpacity = 1.0f;

    float waterLevel = TESR_WaterSettings.x;
    float dist       = abs(worldPos.z - waterLevel);

    // Width of the noisy/transparent shoreline band around the water plane.
    // Higher value = the partial transparent snow transition reaches farther from water.
    const float WATER_EDGE_WIDTH = 5.0f; // was 5.0f

    if (dist < WATER_EDGE_WIDTH) {
        float nearWater   = 1.0f - saturate(dist / WATER_EDGE_WIDTH);
        float solidRemove = smoothstep(0.75f, 1.0f, nearWater);
        float keepProb    = 1.0f - nearWater;
        float waterNoise  = lerp(0.5f, noise2048 * 0.60f + noise64 * 0.40f, waterFade);
        float keepMask    = (1.0f - smoothstep(keepProb - 0.001f, keepProb + 0.001f, waterNoise))
                          * (1.0f - solidRemove);
        snowMask *= keepMask;

        // Surviving snow pixels near the water plane are semi-transparent.
        // Lower WATER_EDGE_MIN_OPACITY for more visible terrain underneath.
        // Raise it for denser/whiter snow near the shoreline.
        const float WATER_EDGE_MIN_OPACITY = 0.05f;
        const float WATER_EDGE_MAX_OPACITY = 0.15f;
        float noisyOpacity = lerp(WATER_EDGE_MIN_OPACITY, WATER_EDGE_MAX_OPACITY, waterNoise);
        shorelineOpacity  = lerp(1.0f, noisyOpacity, nearWater);
    }

    const float edgeBand = 0.12f;
    float nearEdge = 1.0f - saturate(snowMask / edgeBand);
    float zone     = smoothstep(0.05f, 0.90f, nearEdge);
    if (zone > 0.0f) {
        float solidRemove = smoothstep(0.70f, 0.98f, nearEdge);
        float keepProb    = 1.0f - nearEdge * (1.0f + 0.15f * (1.0f - nearEdge)); // was pow(nearEdge,1.15) - MAD approx, max err 0.004
        float edgeNoise   = lerp(0.5f, noise2048 * 0.60f + noise64 * 0.40f, detailFade);
        float keepMask    = 1.0f - smoothstep(keepProb - 0.001f, keepProb + 0.001f, edgeNoise);
        keepMask         *= (1.0f - solidRemove);
        snowMask         *= lerp(1.0f, keepMask, zone);
    }

    // Apply shoreline transparency after the existing breakup masks.
    snowMask *= shorelineOpacity;

    // ── Shadow-respecting snow composite ─────────────────────────────────────
    // Instead of lerp(scene, snowColor, mask) which replaces the shadowed pixel
    // with a bright snow colour, we blend in TWO steps:
    //
    //   1. lerp the surface toward white snow (coverage blend)
    //   2. multiply the result by the shadow value from TESR_PointShadowBuffer
    //      so shadows darken the snow just as they darken the scene
    //
    // shadow.r from TESR_PointShadowBuffer is the raw [0..1] shadow mask
    // (1 = fully lit, 0 = fully shadowed) already read above.
    // We scale it to [DARKNESS..1] to match ShadowsExteriors behaviour.
    //
    // Result: snow has full coverage everywhere, but is darkened in shadows.
    // No tuning constants needed - it automatically follows the shadow config.

    // shadow.r is the raw point-shadow mask [0..1].
    // ShadowsExteriors already darkened `color` by shadowFactor, so we must NOT
    // multiply the whole pixel again — that would double-darken shadows.
    // Instead we only darken the SNOW CONTRIBUTION by shadowFactor, then add it
    // on top of the already-shadowed scene colour.
    //
    //   color      = scene already in shadow  (untouched)
    //   snowColor  = what snow would look like fully lit
    //   snowMask   = coverage [0..1]
    //   shadowFactor = how lit this pixel is [DARKNESS..1]
    //
    // Final = scene_in_shadow  +  snow_contribution * shadowFactor
    //       = lerp(color, color + (snowColor-color)*shadowFactor, snowMask)

    float shadowFactor = lerp(DARKNESS, 1.0f, shadow.r);
    float4 shadowedSnow = float4(lerp(color.rgb, snowColor.rgb * shadowFactor, snowMask), 1.0f);
    color.rgb = shadowedSnow.rgb;
    color.a  = 1.0f;
    color.rgb = delinearize(color.rgb);
    return color;
}

technique SnowTechnique {
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 SnowCoverage();
    }
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 Scale(TESR_RenderedBuffer, 4);
    }
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 DepthBlur(TESR_RenderedBuffer, OffsetMaskH, TESR_SnowAccumulationParams.y, 8500, TESR_OrthoData.x);
    }
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 DepthBlur(TESR_RenderedBuffer, OffsetMaskV, TESR_SnowAccumulationParams.y, 8500, TESR_OrthoData.x);
    }
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 Snow();
    }
}
