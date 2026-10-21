#include "includes/Shadow.hlsl"
#include "includes/ParticleLight.hlsl"

float4 PSDecalOffset : register(c15);
sampler2D DecalMap : register(s1);

struct PS_INPUT {
    float4 uv : TEXCOORD0;
    float4 shadowWorldPos : TEXCOORD1;
    float4 vertexLight : TEXCOORD2;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float2 uv = saturate(IN.uv.xy);
    float4 decal = tex2D(DecalMap, float2(PSDecalOffset.y * uv.x + PSDecalOffset.x, PSDecalOffset.w * uv.y + PSDecalOffset.z));
    [branch] if (SHADOW_VS_PRESENT(IN.shadowWorldPos.w))
        decal.rgb *= ParticleLight(IN.vertexLight.rgb, IN.shadowWorldPos.xyz);

    float fade = IN.uv.z;
    OUT.color_0 = float4(decal.rgb * fade, decal.a * fade * fade);
    return OUT;
}
