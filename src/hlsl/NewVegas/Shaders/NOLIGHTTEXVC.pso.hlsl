#include "includes/Shadow.hlsl"
#include "includes/ParticleLight.hlsl"

float4 MaterialColor : register(c0);
float4 Toggles : register(c1);
float4 FogColor : register(c2);

sampler2D DiffuseMap : register(s0);

struct PS_INPUT {
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 shadowWorldPos : TEXCOORD1;
    float4 vertexLight : TEXCOORD2;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float4 base = tex2D(DiffuseMap, IN.uv.xy) * IN.color * MaterialColor;
    const bool normallyBlended = Toggles.x < 0.5f && Toggles.y < 0.5f;
    [branch] if (SHADOW_VS_PRESENT(IN.shadowWorldPos.w) && (IN.vertexLight.w < 1.5f || normallyBlended))
        base.rgb *= ParticleLight(IN.vertexLight.rgb, IN.shadowWorldPos.xyz);

    float fog = IN.uv.w;
    float3 fogged = lerp(base.rgb, FogColor.rgb, fog);
    float3 premultiplied = base.rgb * (1.0f - fog);
    float3 additive = lerp(base.rgb, 1.0f, saturate(fog * 1.5f));
    OUT.color_0.rgb = lerp(lerp(fogged, premultiplied, Toggles.x), additive, Toggles.y);
    OUT.color_0.a = base.a * IN.uv.z;
    return OUT;
}
