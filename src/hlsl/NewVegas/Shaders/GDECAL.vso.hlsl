#include "includes/Shadow.hlsl"
#define PARTICLE_VS
#include "includes/ParticleLight.hlsl"

row_major float4x4 ModelViewProj : register(c0);
float4 DecalFade : register(c31);

struct VS_INPUT {
    float4 position : POSITION;
    float4 decal : NORMAL;
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;
    float4 vertexLight : TEXCOORD2;
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
