// UNOFFICIAL lit blood decals (Shaders.Particles, off by default): vanilla GDECAL.vso, geometry decals on rigid
// meshes (BSSM_GEOMDECAL). The game's vs_1_1 shader ported as is -- the decal's texture coordinates and fade carried
// in NORMAL -- plus the camera-relative world position and the vertex light for the lit GDECAL.pso. Registers as in
// the game's shader: the engine sets them by number.

#include "includes/Shadow.hlsl"
#define PARTICLE_VS
#include "includes/ParticleLight.hlsl"

row_major float4x4 ModelViewProj : register(c0);
float4 DecalFade : register(c31); // x * y: fade

struct VS_INPUT {
    float4 position : POSITION;
    float4 decal : NORMAL; // xy: texture coordinates, z: fade
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;             // xy: texture, z: fade
    float4 shadowWorldPos : TEXCOORD1; // xyz: camera-relative world position, w: SHADOW_VS_SENTINEL
    float4 vertexLight : TEXCOORD2;    // rgb: ambient + point lights
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float4 clip = mul(ModelViewProj, IN.position);
    OUT.sPosition = clip;
    OUT.uv = float4(IN.decal.xy, DecalFade.x * DecalFade.y * IN.decal.z, 0.0f);

    float3 worldPos = GetShadowWorldPos(clip);
    OUT.shadowWorldPos = float4(worldPos, SHADOW_VS_SENTINEL);
    OUT.vertexLight = float4(ParticleVertexLight(worldPos), 1.0f);
    return OUT;
}
