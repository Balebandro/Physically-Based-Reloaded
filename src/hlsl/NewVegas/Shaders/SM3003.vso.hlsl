// Hair vertex shader -- port of vanilla SM3003.vso, plus the camera-relative world position
// the forward shadow lookup needs.
//
// This is the hair pass: traced as
//     Pass 400 BSSM_3XLIGHTING_HSpc, FaceGenHairNoHat (SM3003.vso SM3003.pso)
// Note it is the SM3 family, not HAIR*.vso -- those are used by a different, unlit pass.
//
// Translated instruction-for-instruction from the vanilla vs_3_0 disassembly. Everything is
// passed through in OBJECT space; the pixel shader builds its own TBN from TEXCOORD3/4/5 and
// uses TEXCOORD6 as the position. The only addition is shadowWorldPos on TEXCOORD1, which
// vanilla leaves unwritten.
//
// Vanilla registers: ModelViewProj c0-c3, FogParam c44, FogColor c45. No relative addressing,
// so Shadow.hlsl's default c100/c104 pins are clear.
// The camera matrices Shadow.hlsl rebuilds world positions with are moved out of c100-c107 in vertex
// shaders: the game's bone upload goes past Bones[54] (c97) and overwrote them in skinned ones, so actors
// read the sun shadow at the wrong place. c240-c247 is beyond any bone write. (Upstream PR #79.)
#define SHADOW_INVPROJ_REG c240
#define SHADOW_INVVIEW_REG c244
#include "includes/Shadow.hlsl"

row_major float4x4 ModelViewProj : register(c0);
float4 FogParam : register(c44);
float4 FogColor : register(c45);

struct VS_INPUT {
    float4 position : POSITION;
    float3 tangent  : TANGENT;
    float3 binormal : BINORMAL;
    float3 normal   : NORMAL;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
};

struct VS_OUTPUT {
    float4 position       : POSITION;
    float2 uv             : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;   // the only addition to vanilla
    float4 color          : COLOR0;
    float3 tangent        : TEXCOORD3;   // object space, unnormalised, as vanilla passes them
    float3 binormal       : TEXCOORD4;
    float3 normal         : TEXCOORD5;
    float3 objPos         : TEXCOORD6;
    float4 fog            : TEXCOORD7;   // rgb: fog colour, w: fog amount
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    OUT.position = mul(ModelViewProj, IN.position);

    // Fog, from the clip-space xyz distance.
    float fogDist = length(OUT.position.xyz);
    float fogStrength = saturate((FogParam.x - fogDist) / FogParam.y);
    OUT.fog.rgb = FogColor.rgb;
    OUT.fog.w = pow(1.0f - fogStrength, FogParam.z);

    OUT.uv = IN.uv;
    OUT.color = IN.color;
    OUT.tangent = IN.tangent;
    OUT.binormal = IN.binormal;
    OUT.normal = IN.normal;
    OUT.objPos = IN.position.xyz;

    OUT.shadowWorldPos = float4(GetShadowWorldPos(OUT.position), SHADOW_VS_SENTINEL);

    return OUT;
};
