// UNOFFICIAL lit blood decals (Shaders.Particles, off by default): vanilla GDECAL.pso, geometry decals (blood on
// characters, creatures and objects). The game's shader ported as is -- a window of the decal texture, faded -- with
// the colour lit by the ambient and point lights from GDECAL(S).vso and the sun through its shadow
// (Includes/ParticleLight.hlsl), so blood no longer stays at full brightness in shade, at night or indoors.

#include "includes/Shadow.hlsl"
#include "includes/ParticleLight.hlsl"

float4 PSDecalOffset : register(c15); // the decal's window in DecalMap: x + y * u, z + w * v
sampler2D DecalMap : register(s1);

struct PS_INPUT {
    float4 uv : TEXCOORD0;             // xy: texture, z: fade
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

    // As the game's: colour times the fade, alpha times the fade twice.
    float fade = IN.uv.z;
    OUT.color_0 = float4(decal.rgb * fade, decal.a * fade * fade);
    return OUT;
}
