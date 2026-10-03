// Decal vertex shader -- port of vanilla SM3004.vso, plus the camera-relative world position
// the forward shadow lookup and the hemisphere skylight need.
//
// Pairs with SM3007.pso (traced: "Pass 410 BSSM_3XLIGHTING_VcPxoSpc, Decal (SM3004.vso
// SM3007.pso) - Vertex: vanilla - Pixel: vanilla"). This is the bullet-hole / impact decal
// path. Vertex and pixel shaders are NOT paired by name; confirm any new pairing with a trace.
//
// Vanilla writes TEXCOORD0/3/4/5/6/7, so TEXCOORD1 is free -- the same slot SM3003.vso uses.
//
// NOTE ON SPACES: tangent, binormal, normal and position are passed through UNTRANSFORMED, so
// the pixel shader receives them in OBJECT space and EyePosition is object-space to match.
// That is why the skylight cannot weight off the interpolated normal and derives a world
// normal from shadowWorldPos instead.
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
    float3 tangent        : TEXCOORD3;
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

    OUT.uv       = IN.uv;
    OUT.color    = IN.color;
    OUT.tangent  = IN.tangent;
    OUT.binormal = IN.binormal;
    OUT.normal   = IN.normal;
    OUT.objPos   = IN.position.xyz;

    OUT.shadowWorldPos = float4(GetShadowWorldPos(OUT.position), SHADOW_VS_SENTINEL);

    return OUT;
};
