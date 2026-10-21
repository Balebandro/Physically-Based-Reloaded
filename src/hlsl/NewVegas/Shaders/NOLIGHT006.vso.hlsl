#include "includes/Shadow.hlsl"
#define PARTICLE_VS
#include "includes/ParticleLight.hlsl"

row_major float4x4 ModelViewProj : register(c0);
row_major float3x3 TexCoordTranform : register(c4);
float4 FogParam : register(c13);
row_major float4x4 WorldView : register(c36);
float4 Falloff : register(c40);

struct VS_INPUT {
    float4 position : POSITION;
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 normal : NORMAL;
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 shadowWorldPos : TEXCOORD1;
    float4 vertexLight : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float3 uv = float3(IN.uv.xy, 1.0f);
    OUT.uv.x = dot(TexCoordTranform[0], uv);
    OUT.uv.y = dot(TexCoordTranform[1], uv);

    float4 position = float4(IN.position.xyz, 1.0f);
    float3 toVertex = normalize(float3(dot(WorldView[0], position), dot(WorldView[1], position), dot(WorldView[2], position)));
    float3 normal = normalize(float3(dot(WorldView[0].xyz, IN.normal.xyz), dot(WorldView[1].xyz, IN.normal.xyz), dot(WorldView[2].xyz, IN.normal.xyz)));
    float t = saturate((abs(dot(normal, toVertex)) - Falloff.x) / (Falloff.y - Falloff.x));
    OUT.uv.z = t * t * (3.0f - 2.0f * t) * (Falloff.w - Falloff.z) + Falloff.z;

    float4 clip = mul(ModelViewProj, IN.position);
    OUT.sPosition = clip;
    OUT.uv.w = pow(1.0f - saturate((FogParam.x - length(clip.xyz)) / FogParam.y), FogParam.z);

    OUT.color = IN.color;
    float3 worldPos = GetShadowWorldPos(clip);
    OUT.shadowWorldPos = float4(worldPos, SHADOW_VS_SENTINEL);
    OUT.vertexLight = float4(ParticleVertexLight(worldPos), 2.0f);
    return OUT;
}
