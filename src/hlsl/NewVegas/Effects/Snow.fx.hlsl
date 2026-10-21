// Snow fullscreen shader for Fallout New Vegas (GameBryo / New Vegas Reloaded)
// v5 — sprite-sheet snowflakes via TESR_SnowFlakeBuffer (s3)
//
// Layers: 5 depth bands (96, 256, 512, 900, 1800)
// Each cell samples a random tile from a 4×4 DXT5 sprite sheet.
// Alpha channel = clean cutout mask. RGB = crystal detail tinted by snow colour.
// All previous systems preserved: drift, wobble, spin, size variation,
// 2×2 neighbour sampling, edge fade, progressive density, ortho occlusion,
// geometry depth fade, camera pitch suppression, day/night lighting.

#define SnowLayers 6

float4x4 TESR_WorldViewProjectionTransform;
float4x4 TESR_ShadowCameraToLightTransformOrtho;
float4 TESR_GameTime;
float4 TESR_SnowData;
float4 TESR_SunColor;
float4 TESR_SunAmbient;

sampler2D TESR_RenderedBuffer  : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer     : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_OrthoMapBuffer  : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SnowFlakeBuffer : register(s3) < string ResourceName = "Precipitations\\fx_weather_snow01.dds"; > = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

static const float PI       = 3.14159265f;
static const float timetick = TESR_GameTime.z;
static const float hscale   = 0.1f;
static const float SPEED    = TESR_SnowData.z;

// Wind and base flake size
static const float WIND_STRENGTH   = 0.3f;
static const float FLAKE_SIZE_NEAR = 0.18f;
static const float FLAKE_SIZE_FAR  = 0.18f;

// Progressive density onset
static const float SNOW_DENSITY_FEATHER  = 0.08f;
static const float SNOW_OPACITY_RAMP_END = 0.18f;

// Geometry depth fade
static const float SNOW_SURFACE_FADE_START = 4.0f;
static const float SNOW_SURFACE_FADE_END   = 30.0f;

// Camera pitch suppression
static const float LOOK_VERTICAL_FADE_START = 0.65f;
static const float LOOK_VERTICAL_FADE_END   = 0.98f;
static const float RAY_VERTICAL_FADE_START  = 0.82f;
static const float RAY_VERTICAL_FADE_END    = 0.98f;

// Snow lighting
static const float3 SNOW_TINT_DAY        = float3(0.80f, 0.80f, 0.88f);
static const float3 SNOW_TINT_NIGHT      = float3(0.76f, 0.80f, 0.88f);
static const float  SNOW_BRIGHTNESS_NIGHT = 0.42f;
static const float  SNOW_BRIGHTNESS_DAY   = 0.80f;
static const float  SNOW_LIGHT_TINT_AMOUNT = 0.25f;

// Hash seeds
static const float NOISE_K  = 30.323122f;
static const float NOISE_K2 = 19.198732f;
static const float NOISE_K3 = 47.536219f;

// Per-flake drift
static const float DRIFT_ANGLE_RANGE = 0.02f;
static const float DRIFT_SPEED_RANGE = 0.15f;
static const float DRIFT_WOBBLE      = 0.26f;
static const float DRIFT_WOBBLE_FREQ = 0.03f;

// Per-flake size and spin
static const float FLAKE_SIZE_VAR  = 0.75f;
static const float FLAKE_EDGE_FADE = 1.5f;
static const float SPIN_SPEED_MAX  = 1.8f;

// ---------------------------------------------------------------------------
// Sprite sheet — 4×4 grid, each tile is 0.25×0.25 UV
// ---------------------------------------------------------------------------
// SPRITE_FILL: fraction of the 128px tile the flake actually occupies.
// Flakes sit centred with padding; 0.72 maps the pixel to the flake region.
// Lower → smaller apparent flake; raise → may sample outside the flake.
static const float SPRITE_FILL = 0.72f;

// SPRITE_DETAIL: mix between flat snow colour (0) and textured crystal (1).
// 0.5 gives visible crystal detail while respecting the day/night tint.
static const float SPRITE_DETAIL = 0.5f;

// Depth layers and motion boosts
static const float LAYER_DEPTH[6]  = { 0.0f, 128.0f, 256.0f, 512.0f, 1024.0f, 2048.0f };
static const float MOTION_BOOST[6] = { 1.0f, 1.20f, 1.20f,  1.0f,   1.0f,   1.0f   };

struct VSOUT { float4 vertPos : POSITION;  float2 UVCoord : TEXCOORD0; };
struct VSIN  { float4 vertPos : POSITION0; float2 UVCoord : TEXCOORD0; };

VSOUT FrameVS(VSIN IN)
{
    VSOUT OUT = (VSOUT)0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

#include "Includes/Depth.hlsl"
#include "Includes/Helpers.hlsl"

float fast_atan2(float y, float x)
{
    float ax = abs(x), ay = abs(y);
    float mn = min(ax, ay), mx = max(ax, ay);
    float t  = mn / mx;
    float th = t * (1.0f + t * t * (-0.2447f + t * t * 0.0663f));
    th = (ax < ay) ? (0.5f * PI - th) : th;
    th = (x  < 0)  ? (PI - th)       : th;
    th = (y  < 0)  ? -th             : th;
    return th;
}

float2 cylindrical(float3 world)
{
    float u = -fast_atan2(world.y, world.x) / PI;
    float v = world.z / length(world.xy);
    return float2(0.5f * u + 0.5f, hscale * v);
}

float GetOrtho(float4 OrthoPos)
{
    OrthoPos.xyz /= OrthoPos.w;
    float oob = (OrthoPos.x < -1.0f || OrthoPos.x > 1.0f ||
                 OrthoPos.y < -1.0f || OrthoPos.y > 1.0f ||
                 OrthoPos.z <  0.0f || OrthoPos.z > 1.0f);
    OrthoPos.x =  OrthoPos.x * 0.5f + 0.5f;
    OrthoPos.y = -OrthoPos.y * 0.5f + 0.5f;
    float o = tex2D(TESR_OrthoMapBuffer, OrthoPos.xy).r;
    return (o > OrthoPos.z - 0.0001f) || oob;
}

float4 Snow(VSOUT IN) : COLOR0
{
    float4 color = tex2D(TESR_RenderedBuffer, IN.UVCoord);
    color.rgb = pows(color.rgb, 2.2f);

    float3 rayStart = toWorld(IN.UVCoord);

    // Camera pitch fades
    float3 camFwd         = normalize(toWorld(float2(0.5f, 0.5f)));
    float  lookVertFade   = 1.0f - smoothstep(LOOK_VERTICAL_FADE_START, LOOK_VERTICAL_FADE_END, abs(camFwd.z));
    float  rayVertFade    = 1.0f - smoothstep(RAY_VERTICAL_FADE_START,  RAY_VERTICAL_FADE_END,  abs(rayStart.z));
    float  verticalFade   = lookVertFade * rayVertFade;

    float  depth = readDepth(IN.UVCoord);
    float2 uv    = cylindrical(rayStart.xyz);
    float2 eastDrift = float2(WIND_STRENGTH, 0.0f) * timetick * 0.05f;

    // Snow lighting
    float3 ambLin    = pows(TESR_SunAmbient.rgb, 2.2f);
    float3 sunLin    = pows(TESR_SunColor.rgb,   2.2f);
    float3 lightMix  = ambLin * 0.75f + sunLin * 0.25f;
    float  lightLuma = dot(lightMix, float3(0.2126f, 0.7152f, 0.0722f));
    float  dayFactor = smoothstep(0.015f, 0.30f, lightLuma);
    float3 snowTint  = lerp(SNOW_TINT_NIGHT, SNOW_TINT_DAY,        dayFactor);
    float  snowBri   = lerp(SNOW_BRIGHTNESS_NIGHT, SNOW_BRIGHTNESS_DAY, dayFactor);
    float3 lightTint = saturate(lightMix / max(lightLuma, 0.0001f));
    float3 finalSnowRgb = lerp(snowTint * snowBri,
                               snowTint * snowBri * lightTint,
                               SNOW_LIGHT_TINT_AMOUNT);

    float snowIntensity = saturate(TESR_SnowData.x);
    float snowAmt       = 0.5f + 0.5f * snowIntensity;
    float snowOpacity   = smoothstep(0.0f, SNOW_OPACITY_RAMP_END, snowIntensity);

    float edgeStart = FLAKE_SIZE_NEAR * snowAmt;
    float edgeStep  = (FLAKE_SIZE_FAR - FLAKE_SIZE_NEAR) * snowAmt * (1.0f / (SnowLayers - 2.0f));

    float totalSnow = 0.0f;

    [unroll]
    for (int i = 1; i < SnowLayers; i++)
    {
        float fi         = (float)i;
        float layerDepth = LAYER_DEPTH[i];
        float motionBoost = MOTION_BOOST[i];
        float layerVar   = 0.6f + 0.4f * frac(fi * 0.31830988f);

        float2 nsp = uv * (1.0f + layerDepth);
        nsp += float2(
            -eastDrift.x * layerVar * (1.0f + layerDepth) * motionBoost,
             SPEED * timetick * motionBoost
        );

        float  edge     = edgeStart + edgeStep * (fi - 1.0f);
        float  flake    = 0.0f;
        float2 nspFrac  = frac(nsp);
        float2 nspFloor = floor(nsp);

        [unroll]
        for (int nx = 0; nx <= 1; nx++)
        {
            [unroll]
            for (int ny = 0; ny <= 1; ny++)
            {
                float2 cellOffset = float2((float)nx, (float)ny);
                float3 m     = float3(nspFloor + cellOffset, fi);

                // Non-linear hash — breaks diagonal banding
                float  mhash     = m.x * 127.1f + m.y * 311.7f + m.z * 74.7f;
                float3 mp        = m / frac(NOISE_K * mhash);
                float3 snowNoise = frac(mp);

                // Drift hash
                float3 driftHash  = frac(float3(mhash * NOISE_K2,
                                                 mhash * NOISE_K2 * 1.3764f,
                                                 mhash * NOISE_K2 * 2.6180f));
                float flakeDriftX = (driftHash.x * 2.0f - 1.0f) * DRIFT_ANGLE_RANGE;
                float flakeDriftY = driftHash.y * DRIFT_SPEED_RANGE;
                float wobblePhase = driftHash.z * 2.0f * PI;
                float wobble      = DRIFT_WOBBLE * sin(timetick * DRIFT_WOBBLE_FREQ + wobblePhase);

                float2 flakeCenter = frac(snowNoise.xy + float2(
                    (flakeDriftX + wobble) * timetick,
                    flakeDriftY * timetick * SPEED
                ));

                // Shape / size / spin hash
                float3 shapeHash = frac(float3(mhash * NOISE_K3,
                                               mhash * NOISE_K3 * 1.7153f,
                                               mhash * NOISE_K3 * 3.1247f));

                float sizeScale  = 1.0f + (shapeHash.x * 2.0f - 1.0f) * FLAKE_SIZE_VAR;
                float flakeEdge  = edge * sizeScale;
                float spinSpeed  = (shapeHash.z * 2.0f - 1.0f) * SPIN_SPEED_MAX;
                float spinAngle  = shapeHash.z * 2.0f * PI + spinSpeed * timetick;
                float cosA = cos(spinAngle), sinA = sin(spinAngle);

                // Local position rotated around flake center
                float2 localPos = nspFrac - cellOffset;
                float2 centered = localPos - (1.0f - flakeCenter);
                float2 rotated  = float2(cosA * centered.x - sinA * centered.y,
                                         sinA * centered.x + cosA * centered.y);

                // ---------------------------------------------------------------------------
                // Sprite tile sampling
                // ---------------------------------------------------------------------------
                float tileX = floor(shapeHash.x * 4.0f);
                float tileY = floor(shapeHash.y * 4.0f);
                float2 tileOrigin = float2(tileX, tileY) * 0.25f;

                float2 spriteUV = tileOrigin + 0.125f
                                + (rotated / max(flakeEdge, 0.0001f))
                                  * 0.25f * SPRITE_FILL * 0.5f;

                // Reject coordinates outside this tile. Keep half a texel of
                // clearance so bilinear filtering cannot read the next tile.
                // Never clamp: clamping would extend border pixels into a grid.
                static const float HALF_TEXEL = 0.5f / 512.0f;
                float2 tileUV = spriteUV - tileOrigin;
                float tileMask = step(HALF_TEXEL, tileUV.x)
                               * step(HALF_TEXEL, tileUV.y)
                               * step(tileUV.x, 0.25f - HALF_TEXEL)
                               * step(tileUV.y, 0.25f - HALF_TEXEL);

                // Sample: alpha = clean cutout, rgb = crystal detail
                float4 spr      = tex2D(TESR_SnowFlakeBuffer, spriteUV);
                // Alpha threshold removes transparent/background samples.
                static const float ALPHA_THRESHOLD = 0.01f;
                float  alpha    = spr.a * step(ALPHA_THRESHOLD, spr.a) * tileMask;
                float  detail   = dot(spr.rgb, float3(0.333f, 0.333f, 0.334f));

                // Combine: alpha is the hard mask; detail adds texture within it.
                // Multiplying keeps the black background at exactly zero.
                float spriteMask = alpha * (1.0f - SPRITE_DETAIL + SPRITE_DETAIL * detail);

                // Progressive density
                float densThresh = 1.0f - snowIntensity * (1.0f + SNOW_DENSITY_FEATHER);
                float densMask   = saturate((snowNoise.z - densThresh) / SNOW_DENSITY_FEATHER);

                float flakeCandidate = spriteMask * snowNoise.x * densMask;

                // Cell-edge fade — dissolves flakes before they hit the cell wall
                float2 edgeDist  = min(flakeCenter, 1.0f - flakeCenter);
                float  fadeWidth = flakeEdge * FLAKE_EDGE_FADE;
                float2 edgeFade2 = smoothstep(0.0f, fadeWidth, edgeDist);
                flakeCandidate  *= edgeFade2.x * edgeFade2.y;

                flake = max(flake, flakeCandidate);
            }
        }

        // Ortho occlusion and geometry depth fade
        float3 layerPos      = rayStart * layerDepth;
        float4 layerOrthoPos = mul(float4(layerPos, 1.0f),
                                   TESR_ShadowCameraToLightTransformOrtho);
        flake *= GetOrtho(layerOrthoPos);
        flake *= smoothstep(SNOW_SURFACE_FADE_START, SNOW_SURFACE_FADE_END,
                            depth - layerDepth);

        totalSnow += flake;
    }

    totalSnow *= snowOpacity * verticalFade;
    totalSnow  = saturate(totalSnow);

    color.rgb = lerp(color.rgb, finalSnowRgb, totalSnow);
    color.rgb = pows(color.rgb, 1.0f / 2.2f);
    return color;
}

technique
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader  = compile ps_3_0 Snow();
    }
}
