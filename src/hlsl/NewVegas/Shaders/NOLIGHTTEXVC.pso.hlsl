// UNOFFICIAL lit particles (Shaders.Particles, off by default): vanilla NOLIGHTTEXVC.pso, the unlit "texture x vertex
// colour" pixel shader, ported as is (fog modes included) with one addition: behind the particle vertex shaders
// (NOLIGHT016/017.vso, which write the sentinel) the colour is lit before the fog -- ambient and point lights from the
// vertex shader, the sun through its shadow here (Includes/ParticleLight.hlsl). Glows, muzzle flashes and lamp cards
// use this pixel shader with the game's own vertex shaders; SetShadersHook gives those draws the game's pixel shader
// back (D3D9 cannot pair this ps_3_0 shader with a vs_2_0 one), so they are untouched.

#include "includes/Shadow.hlsl"
#include "includes/ParticleLight.hlsl"

float4 MaterialColor : register(c0);
float4 Toggles : register(c1);  // x: fog fades to black (premultiplied), y: fog fades to white (additive)
float4 FogColor : register(c2);

sampler2D DiffuseMap : register(s0);

#include "includes/SoftParticle.hlsl"   // UNOFFICIAL 2026-11-04 soft particles

struct PS_INPUT {
    float4 uv : TEXCOORD0;             // xy: texture, z: alpha scale, w: fog
    float4 color : COLOR0;
    float4 shadowWorldPos : TEXCOORD1; // from NOLIGHT016/017.vso only
    float4 vertexLight : TEXCOORD2;
    float2 depthSize : TEXCOORD3;      // x: view depth, y: the particle's size (0: not soft)
    float2 screenPos : VPOS;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float4 base = tex2D(DiffuseMap, IN.uv.xy) * IN.color * MaterialColor;
    // Particles (vertexLight.w 1) always; falloff cards (NOLIGHT006, w 2) only when blended normally -- the glowing
    // ones (muzzle and impact flashes, sparks) are additive, which the game marks with the fade-to-black fog mode.
    const bool normallyBlended = Toggles.x < 0.5f && Toggles.y < 0.5f;
    [branch] if (SHADOW_VS_PRESENT(IN.shadowWorldPos.w) && (IN.vertexLight.w < 1.5f || normallyBlended))
        base.rgb *= ParticleLight(IN.vertexLight.rgb, IN.shadowWorldPos.xyz);

    float fog = IN.uv.w;
    float3 fogged = lerp(base.rgb, FogColor.rgb, fog);
    float3 premultiplied = base.rgb * (1.0f - fog);
    float3 additive = lerp(base.rgb, 1.0f, saturate(fog * 1.5f));
    OUT.color_0.rgb = lerp(lerp(fogged, premultiplied, Toggles.x), additive, Toggles.y);
    OUT.color_0.a = base.a * IN.uv.z;
    OUT.color_0.a *= SoftParticleFade(IN.screenPos, IN.depthSize);   // UNOFFICIAL 2026-11-04 soft particles
    return OUT;
}
