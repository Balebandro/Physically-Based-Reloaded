// PBR light/ambient scales for the hand-ported game shaders (skin, hair, grass).
// Object.hlsl applies the same .z and .w in getSunLighting / getPointLightLighting /
// getAmbientLighting.
//
// c134, past Shadow.hlsl's c100-c133. Object.hlsl must not be included here: it declares
// TESR_PBRData at c32.
//
// DEPENDENCY: ShaderManager::UpdateConstants refreshes PBRShaders unconditionally. A zero
// scale renders everything below black.
#ifndef PBRSCALE_INCLUDED
#define PBRSCALE_INCLUDED

#if defined(__INTELLISENSE__)
    #include "SkyAmbient.hlsl"
#else
    #include "includes/SkyAmbient.hlsl"
#endif

float4 TESR_PBRData : register(c134);

// rgb only: skin carries flags in AmbientColor.a and PSLightColor.a.
float3 PBRLight(float3 lightColor) { return lightColor * TESR_PBRData.z; }
float4 PBRLight(float4 lightColor) { return float4(lightColor.rgb * TESR_PBRData.z, lightColor.a); }

float3 PBRAmbient(float3 ambient) { return ambient * TESR_PBRData.w; }
float4 PBRAmbient(float4 ambient) { return float4(ambient.rgb * TESR_PBRData.w, ambient.a); }

// Hemisphere skylight, matching getAmbientLighting in Object.hlsl. Strength is
// [Shaders.PBR.*] SkylightingScale; there is no toggle, 0 disables it.
//
// Registers above TESR_PBRData's c134. Every shader including this file tops out well below
// c100, and Shadow.hlsl pins c100-c133.
float4 TESR_PBRExtraData : register(c135);

// worldNormal must be the GEOMETRIC world normal, not a tangent-space shading normal --
// GetShadowGeometricNormal gives it. valid is 0 where the carried world position is undefined,
// i.e. under a vanilla vertex shader. w = (1 + N.up) / 2 stays linear in the dot product: that
// is the exact cosine-weighted form factor.
//
// AmbientScale (TESR_PBRData.w) is deliberately absent: this is a second, independent light
// source rather than a tint on the weather ambient, so SkylightingScale is its only strength
// knob and it survives AmbientScale = 0.
float3 SkyAmbient(float3 worldNormal, float valid) {
    return SkyAmbientRadiance(worldNormal) * TESR_PBRExtraData.y * valid;
}

#endif
