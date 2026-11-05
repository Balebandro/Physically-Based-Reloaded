// UNOFFICIAL lit particles (Shaders.Particles, off by default): vanilla NOLIGHT006.vso, unlit mesh cards that fade
// when seen edge-on (BSSM_NOLIGHTING_TexVC_FALLOFF): blood spray and mist cards at a hit, but also muzzle flashes,
// sparks and impact flashes. The game's vs_2_0 shader ported as is, plus the world position and vertex light for the
// lit NOLIGHTTEXVC.pso. vertexLight.w = 2 tells that pixel shader to light only cards blended normally: the glowing
// ones are drawn additively (their fog fades to black, Toggles.x) and keep the game's look. First-person draws (the
// player's own muzzle flash) get the game's shaders in SetShadersHook. Registers as in the game's shader.

#include "includes/Shadow.hlsl"
#define PARTICLE_VS
#include "includes/ParticleLight.hlsl"

row_major float4x4 ModelViewProj : register(c0);
row_major float3x3 TexCoordTranform : register(c4); // the engine's spelling; rows 0 and 1 (c4, c5) are used
float4 FogParam : register(c13);                     // x: fog start, y: fog range, z: fog power
float4 NVR_SoftSize : register(c41);                 // UNOFFICIAL 2026-11-05 soft particles, set per draw (effects/Particles ForDraw): x: mesh size, y: 1 when alpha-blended
row_major float4x4 WorldView : register(c36);        // rows 0-2 (c36-c38) are used
float4 Falloff : register(c40);                      // x, y: edge-on .. face-on range of |N.V|, z, w: alpha there

struct VS_INPUT {
    float4 position : POSITION;
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 normal : NORMAL;
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;             // xy: texture, z: falloff alpha, w: fog
    float4 color : COLOR0;
    float4 shadowWorldPos : TEXCOORD1; // xyz: camera-relative world position, w: SHADOW_VS_SENTINEL
    float4 vertexLight : TEXCOORD2;    // rgb: ambient + point lights, w: 2 = light only if normally blended
    float2 depthSize : TEXCOORD3;      // UNOFFICIAL 2026-11-04: soft particles: x: view depth (clip w), y: the card's size (NVR_SoftSize)
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float3 uv = float3(IN.uv.xy, 1.0f);
    OUT.uv.x = dot(TexCoordTranform[0], uv);
    OUT.uv.y = dot(TexCoordTranform[1], uv);

    // Alpha by how squarely the card faces the camera: smoothstep over Falloff.xy, mapped to Falloff.zw.
    float4 position = float4(IN.position.xyz, 1.0f);
    float3 toVertex = normalize(float3(dot(WorldView[0], position), dot(WorldView[1], position), dot(WorldView[2], position)));
    float3 normal = normalize(float3(dot(WorldView[0].xyz, IN.normal.xyz), dot(WorldView[1].xyz, IN.normal.xyz), dot(WorldView[2].xyz, IN.normal.xyz)));
    float t = saturate((abs(dot(normal, toVertex)) - Falloff.x) / (Falloff.y - Falloff.x));
    OUT.uv.z = t * t * (3.0f - 2.0f * t) * (Falloff.w - Falloff.z) + Falloff.z;

    float4 clip = mul(ModelViewProj, IN.position);
    OUT.sPosition = clip;
    // UNOFFICIAL 2026-11-05 (user: far smoke not fogged): the fog distance as the scene's shaders take it (ObjectTemplate, TerrainTemplate):
    // the clip position, its z turned back with reversed depth (REVERSED_DEPTH, ShaderRecord::AppendGlobalDefines)
    float3 fogPos = clip.xyz;
#ifdef REVERSED_DEPTH
    fogPos.z = clip.w - clip.z;
#endif
    OUT.uv.w = pow(1.0f - saturate((FogParam.x - length(fogPos)) / FogParam.y), FogParam.z);

    OUT.color = IN.color;
    float3 worldPos = GetShadowWorldPos(clip);
    OUT.shadowWorldPos = float4(worldPos, SHADOW_VS_SENTINEL);
    OUT.vertexLight = float4(ParticleVertexLight(worldPos), 2.0f);
    OUT.depthSize = float2(clip.w, NVR_SoftSize.x);
    return OUT;
}
