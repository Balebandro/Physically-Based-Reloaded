// Sandstorm: a dust storm's haze and the wind-blown grains in it, drawn over the scene in HDR before tonemapping
// and bloom, so the dust is lit and blooms like the rest of the frame. SandstormEffect (Sandstorm.cpp) works out
// how strong the storm is now, and the wind, light and gusts it is drawn with.
//
// Haze: each pixel is pulled toward the dust colour by the optical depth of its view ray through the dust. The dust
// is at full density at and below eye level and thins with height above it. The optical depth is the integral of that
// falloff along the ray, so a ray that climbs out of the dust picks up less of it: the far desert vanishes into the dust
// while the air near the camera stays clear. Sky pixels, beyond the far plane, take a strong but not total share of dust
// (SkyHaze) and are darkened toward SkyDarken, so the sun still glows through faintly.
//
// Grains: two layers of value noise, thin across the wind and long along it, scrolled along the wind at different
// speeds (the nearer, finer layer faster, for parallax). They fade out near the camera (NearStreakDistance), so the
// weapon and hands are never streaked, and they are lit brighter than the haze they sit in.
//
// Screen direction of the wind: a horizontal world vector w moves a point's image, to first order, along
//   (du, dv) proportional to (P00 * (w . right) - (2u - 1) * (w . forward), -P11 * (w . up) - (2v - 1) * (w . forward))
// with right, up and forward the camera basis that toWorld() reads from TESR_ViewTransform, and P00 and P11 the
// projection's scales (the point's own depth only scales the result, it does not change its direction). So the
// streaks lie along the way the wind carries things across the screen, however the camera is turned. Where that motion
// vanishes (its focus: the screen centre when the wind points straight at or away from the camera, where the motion is
// radial) the grains fade out.

float4 TESR_ReciprocalResolution;   // x: 1 / width, y: 1 / height, z: width / height
float4 TESR_SandstormData;          // x: storm strength 0-1 (animated), y: dust density per game unit (gust-scaled), z: height falloff (game units), w: sky darkening at full storm
float4 TESR_SandstormDust;          // xyz: dust colour, linear, scaled by the light; w: streak strength (gust-scaled)
float4 TESR_SandstormWind;          // x, y: wind direction in the world (unit length, XY); z: wind speed 0-1; w: unused
float4 TESR_SandstormGrains;        // x: streak scale (per screen height); y: near grain distance (game units); z: streak scroll (noise cells, within one period); w: grain scroll (noise cells, within one period)

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

#include "Includes/Depth.hlsl"

// A pixel at or beyond this fraction of the far plane is the sky dome (the same test as VolumetricFog's isSkyDome).
static const float SkyCutoff = 0.996f;
// The most dust any pixel takes, the sky included: the sun still glows through faintly, and the horizon blends into the sky.
static const float SkyHaze = 0.85f;
// The noise repeats every this many cells along the wind (the streak and grain scrolls are kept within one period).
static const float NoisePeriod = 256.0f;

struct VSOUT
{
    float4 vertPos : POSITION;
    float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
    float4 vertPos : POSITION0;
    float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN)
{
    VSOUT OUT = (VSOUT)0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

// Hash in 0-1 for a 2D point. No sin: its precision falls off with the size of the argument.
float hash21(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return frac((p3.x + p3.y) * p3.z);
}

// Smooth value noise in 0-1, periodic in y with period NoisePeriod: the lattice wraps, so a scroll kept within one
// period shows no seam.
float valueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float y0 = i.y - NoisePeriod * floor(i.y / NoisePeriod);
    float y1 = y0 + 1.0f;
    y1 -= NoisePeriod * floor(y1 / NoisePeriod);
    float a = hash21(float2(i.x, y0));
    float b = hash21(float2(i.x + 1.0f, y0));
    float c = hash21(float2(i.x, y1));
    float d = hash21(float2(i.x + 1.0f, y1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float4 SandstormPS(VSOUT IN) : COLOR0
{
    float2 uv = IN.UVCoord;

    // Both fetches come before the early-out, so no texture is read inside the dynamic branch.
    float3 color = tex2D(TESR_RenderedBuffer, uv).rgb;
    float depth = readDepth(uv);   // planar distance to the pixel, game units

    float storm = TESR_SandstormData.x;
    [branch] if (storm <= 0.0f) return float4(color, 1.0f);

    float density = TESR_SandstormData.y;
    float heightFalloff = TESR_SandstormData.z;
    float skyDarken = TESR_SandstormData.w;
    float3 dust = TESR_SandstormDust.rgb;
    float streakStrength = TESR_SandstormDust.w;
    float windSpeed = TESR_SandstormWind.z;
    float streakScale = TESR_SandstormGrains.x;
    float nearDistance = TESR_SandstormGrains.y;
    float streakScroll = TESR_SandstormGrains.z;
    float grainScroll = TESR_SandstormGrains.w;

    // Haze. toWorld(uv) is the view ray per unit of planar depth, so the pixel lies at toWorld(uv) * depth from the eye.
    float isSky = step(SkyCutoff * farZ, depth);
    float3 ray = toWorld(uv);
    // By the pixel, the ray has climbed ray.z * depth game units above the eye: that is climb falloff lengths. The integral
    // of exp(-max(0, height) / falloff) along the ray is depth * (1 - exp(-climb)) / climb; a ray that never climbs (level
    // or down) gets depth.
    float climb = max(0.0f, ray.z) * depth / heightFalloff;
    float heightTerm = climb > 0.0001f ? (1.0f - exp(-climb)) / climb : 1.0f;
    float tau = density * depth * heightTerm;
    float haze = lerp(min(1.0f - exp(-tau), SkyHaze), SkyHaze, isSky) * storm;
    float skyKeep = lerp(1.0f, lerp(1.0f, skyDarken, storm), isSky);
    color = lerp(color * skyKeep, dust, haze);

    // Grains. The wind's direction on screen, from the derivation in the header; p is in screen heights, so x is
    // scaled by the aspect ratio, and the direction is taken in the same units.
    float aspect = TESR_ReciprocalResolution.z;
    float3 wind = float3(TESR_SandstormWind.xy, 0.0f);
    float3 camRight = float3(TESR_ViewTransform[0][0], TESR_ViewTransform[1][0], TESR_ViewTransform[2][0]);
    float3 camUp = float3(TESR_ViewTransform[0][1], TESR_ViewTransform[1][1], TESR_ViewTransform[2][1]);
    float3 camForward = float3(TESR_ViewTransform[0][2], TESR_ViewTransform[1][2], TESR_ViewTransform[2][2]);
    float2 flow = float2(TESR_ProjectionTransform[0][0] * dot(wind, camRight) - (2.0f * uv.x - 1.0f) * dot(wind, camForward),
                         -TESR_ProjectionTransform[1][1] * dot(wind, camUp) - (2.0f * uv.y - 1.0f) * dot(wind, camForward));
    flow.x *= aspect;
    float flowLength = length(flow);
    float2 windDir = flow / max(flowLength, 0.0001f);
    float2 windPerp = float2(-windDir.y, windDir.x);

    float2 p = float2(uv.x * aspect, uv.y);
    float along = dot(p, windDir);
    float across = dot(p, windPerp);

    // Long, thin streaks; then shorter, finer grains that move faster. Both scroll with the wind, by the scrolls
    // SandstormEffect has already wrapped to one noise period.
    float2 streakCoord = float2(across * streakScale, along * streakScale * 0.06f - streakScroll);
    float2 grainCoord = float2(across * streakScale * 2.5f, along * streakScale * 0.625f - grainScroll) + 17.0f;

    // A stronger wind lowers the threshold, so more of them show.
    float threshold = 0.7f - 0.1f * windSpeed;
    float streaks = smoothstep(threshold, threshold + 0.2f, valueNoise(streakCoord));
    float grains = smoothstep(threshold + 0.05f, threshold + 0.25f, valueNoise(grainCoord));
    float grainLight = saturate(streaks + 0.7f * grains);

    // None right at the camera (the weapon, the hands), and none where the wind has no direction on screen.
    float nearWeight = saturate(depth / nearDistance);
    float facing = saturate(flowLength * 3.0f);
    float amount = streakStrength * storm * nearWeight * facing;
    color += dust * 1.6f * grainLight * amount;

    return float4(color, 1.0f);
}

technique
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 SandstormPS();
    }
}
