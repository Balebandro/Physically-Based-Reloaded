// SpeedTree leaf PS -- BSSM_LEAVES_AD with fog. Port of vanilla STLEAF2001.pso, plus forward sun shadows.
// ps_2_x -> ps_3_0: Shadow.hlsl needs tex2Dlod, and D3D9 requires a matching vs_3_0.
//
// Vanilla: mad oC0.rgb, fog.w, (fog.rgb - lit), lit -- a lerp; oC0.a = albedo.a
#include "includes/Shadow.hlsl"
#include "includes/Leaf.hlsl"
#include "includes/AlphaAA.hlsl"

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float3 lighting = LeafLighting(IN);
    float4 albedo = tex2D(DiffuseMap, IN.uv);
    float3 lit = albedo.rgb * lighting;

    OUT.color.rgb = lerp(lit, IN.fog.rgb, IN.fog.w);
    OUT.color.a = AlphaAA(albedo.a);

    return OUT;
};
