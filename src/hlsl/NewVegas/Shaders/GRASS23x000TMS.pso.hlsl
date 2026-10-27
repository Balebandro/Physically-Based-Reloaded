// Grass PS -- vanilla GRASS23x000TMS.pso plus forward sun shadow.
// Shared by GRASS23x002.vso (LFS) and GRASS23x003.vso (LVS).
//
// The VS hands the lighting over already split, so only the sun is shadowed:
//   TEXCOORD4.xyz ambient    TEXCOORD5.xyz sun    TEXCOORD5.w fade    COLOR0 fog (.w amount)

#include "includes/Shadow.hlsl"
#include "includes/PBRScale.hlsl"
#include "includes/Helpers.hlsl"
#define LAMP_LOOK_PS
#include "includes/Pointlights.hlsl"   // the lamp look's falloff (TESR_LampLook)
#include "includes/AlphaAA.hlsl"

// The grass brightness settings (Shaders.Grass.Main): x Brightness multiplies the lit colour, before fog; y the night
// brightness (NightBrightness eased by the day/night transition) on the sun and ambient. c146 is past
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
        float att = lampFalloff(saturate(1.0f - dot(toLight, toLight) / (radius * radius)));
        float wrap = 0.5f + 0.5f * abs(dot(normal, toLight * rsqrt(max(dot(toLight, toLight), 1.0f))));
        lamps += TESR_GrassLightColor[i].rgb * (att * wrap);
    }
    return lamps * TESR_GrassLightData.y;
}

sampler2D DiffuseMap : register(s0);

// Normal maps and specular (Shaders.Grass.NormalMaps; effects/Grass.cpp OnGrassShape): a grass
// texture's "_n" companion on s1, set per shape with GrassMaterial: x 1 when the map is bound, y its strength, z specular
// strength (0 off), w glossiness. Not a TESR_ constant: written per shape, not per shader.
sampler2D NormalMap : register(s1);
float4 GrassMaterial : register(c147);

// The normal with the normal map: the grass meshes carry no tangents, so the frame comes from how the position and the
// UVs change across the screen (Schuler's cotangent frame), around the normal vanilla lights the grass by. The map's
// slope tilts that normal; at strength 0 or a flat map it is vanilla's normal again. w: the map's alpha, the specular mask.
float4 GrassMappedNormal(float3 N, float2 uv, float3 dp1, float3 dp2, float2 duv1, float2 duv2) {
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float frame = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-20f));
    float4 m = tex2D(NormalMap, uv);
    m.xyz = m.xyz * 2.0f - 1.0f;
    return float4(normalize(N + (T * m.x + B * m.y) * (frame * GrassMaterial.y)), m.a);
}

struct PS_INPUT {
    float2 uv             : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;
    float4 lightNormal    : TEXCOORD2;   // xyz the normal vanilla lights the grass by, w its N.L
    float3 sunDir         : TEXCOORD3;
    float3 ambient        : TEXCOORD4_centroid;
    float4 sun            : TEXCOORD5_centroid;   // .w = distance fade
    float4 fog            : COLOR0;               // .w = fog amount
};

struct PS_OUTPUT {
    float4 color : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    // The VS leaves N.L out of the sun: vanilla's, or per pixel through the normal map. The derivatives stay at top level,
    // outside dynamic flow control.
    float3 dp1 = ddx(IN.shadowWorldPos.xyz), dp2 = ddy(IN.shadowWorldPos.xyz);
    float2 duv1 = ddx(IN.uv), duv2 = ddy(IN.uv);
    float4 normal = float4(normalize(IN.lightNormal.xyz), 1.0f);   // w the specular mask
    float NdotL = IN.lightNormal.w;
    [branch] if (GrassMaterial.x > 0.0f) {
        normal = GrassMappedNormal(normal.xyz, IN.uv, dp1, dp2, duv1, duv2);
        NdotL = saturate(dot(IN.sunDir, normal.xyz));
    }
    float3 sun = IN.sun.xyz;   // the sun's light on the grass, before N.L

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
    float3 lighting = PBRLight(sun * NdotL) + PBRAmbient(IN.ambient.xyz) + SkyAmbient(shadowNormal, SHADOW_VS_PRESENT(IN.shadowWorldPos.w) ? 1.0f : 0.0f);

    // The sun's highlight (Blinn-Phong), masked by the normal map's alpha where there is one. The camera sits at the origin
    // of the camera-relative position, which only NVR's VS hands over.
    float3 specular = 0.0f;
    [branch] if (GrassMaterial.z > 0.0f && SHADOW_VS_PRESENT(IN.shadowWorldPos.w)) {
        float3 L = normalize(IN.sunDir);
        float3 H = normalize(L - normalize(IN.shadowWorldPos.xyz));
        float highlight = pow(saturate(dot(normal.xyz, H)), GrassMaterial.w) * saturate(dot(normal.xyz, L));
        specular = PBRLight(sun * (highlight * GrassMaterial.z * normal.w));
    }

    // The night brightness (Shaders.Grass.Main NightBrightness), on the sun/moon and ambient only: lamps keep theirs.
    lighting *= TESR_GrassBrightness.y;
    specular *= TESR_GrassBrightness.y;

    // Lamps: scaled as the object shaders scale their lights (PBRLight). The position is only valid under NVR's VS.
    [branch] if (TESR_GrassLightData.x > 0.0f && SHADOW_VS_PRESENT(IN.shadowWorldPos.w))
        lighting += GrassLamps(IN.shadowWorldPos.xyz, shadowNormal) * TESR_PBRData.z;

    float4 albedo = tex2D(DiffuseMap, IN.uv.xy);
    float3 litColor = (lighting * albedo.rgb + specular) * TESR_GrassBrightness.x;

    OUT.color.rgb = lerp(litColor, IN.fog.rgb, IN.fog.w);
    OUT.color.a = AlphaAA(saturate(albedo.a * 1.75f) * IN.sun.w);

    return OUT;
};
