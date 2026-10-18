// Grass PS -- vanilla GRASS23x000TMS.pso plus forward sun shadow.
// Shared by GRASS23x002.vso (LFS) and GRASS23x003.vso (LVS).
//
// The VS hands the lighting over already split, so only the sun is shadowed:
//   TEXCOORD4.xyz ambient    TEXCOORD5.xyz sun    TEXCOORD5.w fade    COLOR0 fog (.w amount)

#include "includes/Shadow.hlsl"
#include "includes/PBRScale.hlsl"

// The grass brightness setting (Shaders.Grass.Main Brightness): multiplies the lit colour, before fog. c146 is past
// PBRScale's sky irradiance (c137-c145).
float4 TESR_GrassBrightness : register(c146);

// Lamps on the grass (Shaders.Grass.Lights; effects/Grass.cpp UpdateLights): placed lights and the Pip-Boy light, never
// the sun. x: how many of the slots below are live (0 skips them all), y: Strength. Positions camera-relative, as
// shadowWorldPos, w the radius; colours with the dimmer applied.
#define GRASS_LIGHTS 8
float4 TESR_GrassLightData                     : register(c160);
float4 TESR_GrassLightPosition[GRASS_LIGHTS]   : register(c161);
float4 TESR_GrassLightColor[GRASS_LIGHTS]      : register(c169);

// The lamps' light on a blade: vanilla's falloff (1 - d^2 / r^2, as the object shaders' vanillaAtt), and a wrapped
// diffuse, as a thin blade lets light through to its back face.
float3 GrassLamps(float3 position, float3 normal) {
    float3 lamps = 0.0f;
    [loop] for (int i = 0; i < GRASS_LIGHTS; i++) {
        [branch] if (i >= TESR_GrassLightData.x) break;
        float3 toLight = TESR_GrassLightPosition[i].xyz - position;
        float radius = TESR_GrassLightPosition[i].w;
        float att = saturate(1.0f - dot(toLight, toLight) / (radius * radius));
        float wrap = 0.5f + 0.5f * abs(dot(normal, toLight * rsqrt(max(dot(toLight, toLight), 1.0f))));
        lamps += TESR_GrassLightColor[i].rgb * (att * wrap);
    }
    return lamps * TESR_GrassLightData.y;
}

sampler2D DiffuseMap : register(s0);

struct PS_INPUT {
    float2 uv             : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;
    float3 ambient        : TEXCOORD4_centroid;
    float4 sun            : TEXCOORD5_centroid;   // .w = distance fade
    float4 fog            : COLOR0;               // .w = fog amount
};

struct PS_OUTPUT {
    float4 color : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float3 sun = IN.sun.xyz;

    // Outside the guard: the skylight needs this normal whether or not forward shadows
    // are compiled in, and ForwardShadows is a live setting that can switch them off.
    float3 shadowNormal = GetShadowGeometricNormal(IN.shadowWorldPos.xyz);
#if FORWARD_SHADOWS
    // ddx/ddy must stay at top level, outside dynamic flow control.
    sun *= SHADOW_VS_PRESENT(IN.shadowWorldPos.w)
         ? GetSunShadow(IN.shadowWorldPos.xyz, shadowNormal)
         : 1.0f;
#endif

    // Same split getSunLighting/getAmbientLighting apply on the object path.
    float3 lighting = PBRLight(sun) + PBRAmbient(IN.ambient.xyz) + SkyAmbient(shadowNormal, SHADOW_VS_PRESENT(IN.shadowWorldPos.w) ? 1.0f : 0.0f);

    // Lamps: scaled as the object shaders scale their lights (PBRLight). The position is only valid under NVR's VS.
    [branch] if (TESR_GrassLightData.x > 0.0f && SHADOW_VS_PRESENT(IN.shadowWorldPos.w))
        lighting += GrassLamps(IN.shadowWorldPos.xyz, shadowNormal) * TESR_PBRData.z;

    float4 albedo = tex2D(DiffuseMap, IN.uv.xy);
    float3 litColor = lighting * albedo.rgb * TESR_GrassBrightness.x;

    OUT.color.rgb = lerp(litColor, IN.fog.rgb, IN.fog.w);
    OUT.color.a = saturate(albedo.a * 1.75f) * IN.sun.w;

    return OUT;
};
