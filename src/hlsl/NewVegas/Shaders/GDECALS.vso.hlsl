// UNOFFICIAL lit blood decals (Shaders.Particles, off by default): vanilla GDECALS.vso, geometry decals on skinned
// meshes (BSSM_GEOMDECAL_S: blood on characters and creatures). The game's vs_1_1 shader ported as is -- four-bone
// skinning, the decal's texture coordinates and fade carried in NORMAL -- plus the camera-relative world position and
// the vertex light for the lit GDECAL.pso. Registers as in the game's shader: the engine sets them by number.

// Camera matrices out of c100-c107: the game's bone upload reaches past Bones[54] and overwrote them (see
// ObjectTemplate.hlsl). c240+ is taken by ParticleLight here, so c180-c187.
#define SHADOW_INVPROJ_REG c180
#define SHADOW_INVVIEW_REG c184
#include "includes/Shadow.hlsl"
#define PARTICLE_VS
#include "includes/ParticleLight.hlsl"

row_major float4x4 SkinModelViewProj : register(c1);
float4 DecalFade : register(c31); // x * y: fade
float4 Bones[54] : register(c44); // three rows per bone

struct VS_INPUT {
    float4 position : POSITION;
    float4 decal : NORMAL;          // xy: texture coordinates, z: fade
    float4 blendWeight : BLENDWEIGHT;
    float4 blendIndices : BLENDINDICES;
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;             // xy: texture, z: fade
    float4 shadowWorldPos : TEXCOORD1; // xyz: camera-relative world position, w: SHADOW_VS_SENTINEL
    float4 vertexLight : TEXCOORD2;    // rgb: ambient + point lights
};

float3 SkinPoint(float4 position, float index) {
    int bone = (int)(index + 0.5f);
    return float3(dot(Bones[bone], position), dot(Bones[bone + 1], position), dot(Bones[bone + 2], position));
}

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    // Indices come as a D3DCOLOR (hence zyx) scaled to the first of a bone's three rows; weights x, y, z and the rest.
    float4 indices = IN.blendIndices.zyxw * 765.01001f;
    float4 position = float4(IN.position.xyz, 1.0f);
    float3 skinned = SkinPoint(position, indices.y) * IN.blendWeight.y;
    skinned += SkinPoint(position, indices.x) * IN.blendWeight.x;
    skinned += SkinPoint(position, indices.z) * IN.blendWeight.z;
    skinned += SkinPoint(position, indices.w) * (1.0f - dot(IN.blendWeight.xyz, 1.0f));

    float4 clip = mul(SkinModelViewProj, float4(skinned, 1.0f));
    OUT.sPosition = clip;
    OUT.uv = float4(IN.decal.xy, DecalFade.x * DecalFade.y * IN.decal.z, 0.0f);

    float3 worldPos = GetShadowWorldPos(clip);
    OUT.shadowWorldPos = float4(worldPos, SHADOW_VS_SENTINEL);
    OUT.vertexLight = float4(ParticleVertexLight(worldPos), 1.0f);
    return OUT;
}
