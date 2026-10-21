// Grass VS -- vanilla GRASS23x003.vso (BSSM_GRASS_DIRONLY_LVS), plus shadowWorldPos.
// GRASS23x002 except the sun term uses the vertex NORMAL through the billboard basis, not the
// card orientation. Used by grass-placed meshes with real normals, e.g. scatter rocks.
//
// REGISTER HAZARD
// As 002: InstanceData spans c20..c247, shadow matrices relocated to c248/c252.
// Only c252-c255 for the inverse view-projection: There Stands The Grass NVSE writes c248-c249 before every grass batch.
#define SHADOW_INVVIEWPROJ_REG c252
#include "includes/Shadow.hlsl"

float3 DiffuseDir   : register(c0);
float3 DiffuseColor : register(c1);
float3 ScaleMask    : register(c2);
float4 WindData     : register(c4);
float4 AlphaParam   : register(c5);
float4 AmbientColor : register(c6);
float4 AddlParams   : register(c7);
row_major float4x4 ModelViewProj : register(c9);
float4 FogColor     : register(c14);
float4 FogParam     : register(c15);
// The sandstorm's wind (SandstormEffect): x grass strength at the storm's height, z time (s), w how hard the storm
// blows, 0 with no storm. c16 is free in every grass shader (c20-c247 InstanceData).
float4 TESR_WindBoost : register(c16);
// The player walking through the grass (GrassShaders, as There Stands The Grass NVSE does it): xyz the bend origin in the
// frame GetShadowWorldPos rebuilds positions in, w 1 / reach; x of the params the push per unit of blade height, w 1 to
// tint the reached grass red.
// No room for more literal constants here: the compiler keeps them in c3, c8, c13 and c19, the only registers free, and
// one more spilled to c256, which does not exist (the shader then failed to create and the game crashed at startup).
float4 TESR_GrassBend       : register(c17);
float4 TESR_GrassBendParams : register(c18);
// Grass LOD: GrassBatch per draw from NVR's SetShaders hook (x the mesh's radius, y its detail factor, z 1 for a static shape); TESR_GrassLOD
// x pixels per unit at a depth of 1, y MinPixels, z FadePixels, w 1 when on. c250-c251: past TSTG's c248-c249.
float4 GrassBatch    : register(c250);
float4 TESR_GrassLOD : register(c251);

#ifndef GRASS_INSTANCE_COUNT
    #define GRASS_INSTANCE_COUNT 228
#endif
float4 InstanceData[GRASS_INSTANCE_COUNT] : register(c20);

struct VS_INPUT {
    float4 position : POSITION;
    float3 normal   : NORMAL;
    float4 color    : COLOR0;
    float2 uv       : TEXCOORD0;
    float4 instance : TEXCOORD1;   // .x = instance index
};

struct VS_OUTPUT {
    float4 position       : POSITION;
    float2 uv             : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;   // vanilla leaves TEXCOORD1 unused on this pair
    float4 lightNormal    : TEXCOORD2;   // xyz the normal the sun is lit by (vanilla's), w its N.L: the grass PS bends it by a normal map
    float3 sunDir         : TEXCOORD3;   // DiffuseDir, for the PS
    float4 ambient        : TEXCOORD4;
    float4 sun            : TEXCOORD5;   // .w = distance fade
    float4 fog            : COLOR0;      // .w = fog amount
};

// There Stands The Grass NVSE's grass patch (features/GrassBend.cpp, Into-The-Rough), the same arithmetic: each vertex
// is pushed away from the bend origin, horizontally, by (1 - distance / reach)^2 times the strength per unit of height
// times its own height above its tuft's root -- so the root stays planted and every blade leans by the same angle. The
// distance is measured at the vertex itself (with 1 added under the root, as TSTG does, so it never divides by zero).
// rootWorld: the tuft's root, camera-relative (GetShadowWorldPos); offset: the vertex from its root, after the wind.
float3 GrassBend(float3 rootWorld, float3 offset, out float reached) {
    float2 away = rootWorld.xy + offset.xy - TESR_GrassBend.xy;
    float inverse = rsqrt(dot(away, away) + 1.0f);
    float falloff = max(1.0f - TESR_GrassBend.w / inverse, 0.0f);
    falloff *= falloff;
    reached = falloff;
    float push = falloff * TESR_GrassBendParams.x * max(offset.z, 0.0f);
    return float3(away * inverse * push, 0.0f);
}

// How much of an instance shows by its size on screen (GrassShaders, after Community Shaders' Grass Optimizations): its
// height in pixels is the mesh's radius times its scale over its depth. Gone below MinPixels (raised for detailed
// meshes), full FadePixels above that. 1 when off, or for a draw whose size did not come (radius 0).
float GrassLODFade(float4 rootClip, float height) {
    float pixels = GrassBatch.x * height * TESR_GrassLOD.x / max(rootClip.w, 1.0f);
    float fade = saturate((pixels - TESR_GrassLOD.y * GrassBatch.y) / TESR_GrassLOD.z);
    return (TESR_GrassLOD.w > 0.5f && GrassBatch.x > 0.0f) ? fade : 1.0f;
}


VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    int idx = (int)(IN.instance.x - frac(IN.instance.x));
    float4 inst = InstanceData[idx];

    // Fade on the instance origin. 4-component length (dp4 r2, r2), not xyz.
    float4 instClip = mul(ModelViewProj, float4(inst.xyz, 1.0f));
    float instDist = length(float4(instClip.xy, instClip.w - instClip.z, instClip.w));
    OUT.sun.w = 1.0f - saturate((instDist - AlphaParam.z) / AlphaParam.w);

    float4 f = frac(inst);
    float3 orient = (f.xyz - 0.5f) * 2.0f;
    float lightScale = f.w * 0.75f + 0.25f;

    bool useAlt = (abs(orient.y) >= abs(orient.x)) && (abs(orient.z) >= abs(orient.x));
    float3 perp = useAlt ? float3(0.0f, -orient.z, orient.y)
                         : float3(-orient.z, 0.0f, orient.x);

    float3 tangent  = normalize(perp);
    float3 binormal = cross(tangent, orient);

    float3 scale = (0.01f * inst.w) * ScaleMask.xyz + 1.0f;
    float lodFade = GrassLODFade(instClip, scale.z);
    OUT.sun.w *= lodFade;
    float3 local = scale * IN.position.xyz;
    float3 pos = binormal * local.x + tangent * local.y + orient * local.z;

    // Vertex normal in the billboard basis.
    float3 N = binormal * IN.normal.x + tangent * IN.normal.y + orient * IN.normal.z;
    float NdotL = saturate(dot(DiffuseDir, N));

    float phase = (inst.x + inst.y) * 0.0078125f + WindData.w;
    phase = frac(phase * 0.159154937f + 0.5f) * 6.28318548f - 3.14159274f;
    // In a sandstorm the grass sways harder, leans downwind in gusts that travel across the field with the wind, and
    // flutters fast. With no storm this is the vanilla sway.
    float storm = TESR_WindBoost.w;
    float gust = 0.75f + 0.25f * sin(TESR_WindBoost.z * 2.1f - dot(inst.xy, WindData.xy) * 0.0078125f);
    float flutter = sin(TESR_WindBoost.z * 11.0f + (inst.x - inst.y) * 0.0078125f);
    float swing = sin(phase) * lerp(1.0f, TESR_WindBoost.x, storm) + storm * TESR_WindBoost.x * (0.75f * gust + 0.25f * flutter);
    float sway = swing * WindData.z * (IN.color.w * IN.color.w) * (1.0f - GrassBatch.z);   // GrassBatch.z 1: a static shape (rocks), no sway
    pos.xy += sway * WindData.xy;
    float bendReach;
    pos += GrassBend(GetShadowWorldPos(instClip), pos, bendReach) * (1.0f - GrassBatch.z);   // nor bending

    float4 worldPos = float4(pos + inst.xyz, 1.0f);
    OUT.position = mul(ModelViewProj, worldPos);

    OUT.ambient = lightScale * AmbientColor;
    // Debug (Shaders.Grass.Interaction): grass the bend reaches, in red.
    OUT.ambient.rgb = lerp(OUT.ambient.rgb, float3(1.0f, 0.0f, 0.0f), bendReach * TESR_GrassBendParams.w);
    OUT.sun.xyz = (lightScale * IN.color.rgb) * DiffuseColor * AddlParams.x;
    OUT.lightNormal = float4(N, NdotL);   // N.L is applied in the PS (GRASS23x000TMS), per pixel with a normal map
    OUT.sunDir = DiffuseDir;

    float fogDist = length(float3(OUT.position.xy, OUT.position.w - OUT.position.z));
    float fogStrength = 1.0f - saturate((FogParam.x - fogDist) / FogParam.y);
    OUT.fog.rgb = FogColor.rgb;
    OUT.fog.w = pow(fogStrength, FogParam.z);

    OUT.uv = IN.uv;

    OUT.shadowWorldPos = float4(GetShadowWorldPos(OUT.position), SHADOW_VS_SENTINEL);

    // Faded out by its size: off the screen whole, so none of it is drawn.
    if (lodFade <= 0.0f) OUT.position = float4(2.0f, 2.0f, 2.0f, 1.0f);

    return OUT;
};
