#if defined(__INTELLISENSE__)
    #include "Pointlights.hlsl"
    #include "PBR.hlsl"
#else
    #include "includes/Pointlights.hlsl"
    #include "includes/PBR.hlsl"
#endif

#if defined(__INTELLISENSE__)
    #include "SkyAmbient.hlsl"
#else
    #include "includes/SkyAmbient.hlsl"
#endif

float4 TESR_PBRData : register(c32);
float4 TESR_PBRExtraData : register(c33);

float getRoughness(float gloss) {
    return saturate(max(0.043, 1 - gloss) * TESR_PBRData.y);
}

float getRoughness(float glossmap, float meshgloss){
    // return pow(glossmap, log(meshgloss));    
    // no gloss = 1
    // full gloss = 0

    return saturate(1 - log(meshgloss) / 4 * glossmap);
    // return 1 - saturate(log(meshgloss)/4 + glossmap);
    // return pow(1 - glossmap, meshgloss);
}

// Vanilla
float3 getVanillaLighting(float3 lightDir, float radius, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float gloss, float glossPower) {
    float att = vanillaAtt(lightDir, radius);
    
    lightDir = normalize(lightDir);
    viewDir = normalize(viewDir);
    float3 halfwayDir = normalize(lightDir + viewDir);
    
    float NdotL = shades(normal.xyz, lightDir.xyz);
    
    #if defined(ONLY_SPECULAR)
        float specStrength = gloss * pow(abs(shades(normal.xyz, halfwayDir.xyz)), glossPower);
        float3 lighting = saturate(((0.2 >= NdotL ? (specStrength * saturate(NdotL + 0.5)) : specStrength) * lightColor.rgb) * att);
    #elif defined(SPECULAR)
        float specStrength = gloss * pow(abs(shades(normal.xyz, halfwayDir.xyz)), glossPower);
        float3 lighting = albedo.rgb * NdotL * lightColor.rgb * att;
        lighting += saturate(((0.2 >= NdotL ? (specStrength * saturate(NdotL + 0.5)) : specStrength) * lightColor.rgb) * att);
    #else
        float3 lighting = albedo.rgb * NdotL * lightColor.rgb * att;
    #endif
    
    return lighting;
}

float3 getVanillaLightingAtt(float3 lightDir, float att, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float gloss, float glossPower) {
    lightDir = normalize(lightDir);
    viewDir = normalize(viewDir);
    float3 halfwayDir = normalize(lightDir + viewDir);
    
    float NdotL = shades(normal.xyz, lightDir.xyz);
    
    #if defined(ONLY_SPECULAR)
        float specStrength = gloss * pow(abs(shades(normal.xyz, halfwayDir.xyz)), glossPower);
        float3 lighting = saturate(((0.2 >= NdotL ? (specStrength * saturate(NdotL + 0.5)) : specStrength) * lightColor.rgb) * att);
    #elif defined(SPECULAR)
        float specStrength = gloss * pow(abs(shades(normal.xyz, halfwayDir.xyz)), glossPower);
        float3 lighting = albedo.rgb * NdotL * lightColor.rgb * att;
        lighting += saturate(((0.2 >= NdotL ? (specStrength * saturate(NdotL + 0.5)) : specStrength) * lightColor.rgb) * att);
    #else
        float3 lighting = albedo.rgb * NdotL * lightColor.rgb * att;
    #endif
    
    return lighting;
}

// PBR
float3 getPointLightLighting(float3 lightDir, float radius, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness) {
    lightColor = lightColor * TESR_PBRData.z;
    albedo = lerp(luma(albedo), albedo, TESR_PBRExtraData.x);
    
    float att = vanillaAtt(lightDir, radius);
    
    #if defined(ONLY_SPECULAR)
        return att * PBRSpecular(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #elif defined(SPECULAR)
        return att * PBR(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #else
        return att * PBRDiffuse(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #endif
}

float3 getPointLightLightingAtt(float3 lightDir, float att, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness) {
    lightColor = lightColor * TESR_PBRData.z;
    albedo = lerp(luma(albedo), albedo, TESR_PBRExtraData.x);
    
    #if defined(ONLY_SPECULAR)
        return att * PBRSpecular(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #elif defined(SPECULAR)
        return att * PBR(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #else
    return att * PBRDiffuse(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #endif
}

float3 getSunLighting(float3 lightDir, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness) {
    lightColor = lightColor * TESR_PBRData.z;
    albedo = lerp(luma(albedo), albedo, TESR_PBRExtraData.x);
    
    #if defined(ONLY_SPECULAR)
        return PBRSunSpecular(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #elif defined(SPECULAR)
        return PBRSun(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #else
        return PBRDiffuse(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #endif
}



// [_Main.Develop.Main], via Debug.cpp UpdateSettings. c135: c132 is TESR_ShadowBlur.
// Populated even with Shaders.Debug disabled -- Debug has no per-frame UpdateConstants.
float4 TESR_DebugVar : register(c135);

// --- Hemisphere skylight ------------------------------------------------------------------
// Additive upper-sky term on top of the weather ambient, weighted by w = (1 + N.up) / 2.
// w must stay linear in the dot product: that is the exact cosine-weighted form factor.
// [Shaders.PBR.*] SkylightingScale. No separate toggle: 0 disables the term.
#define SKY_AMBIENT_STRENGTH  (TESR_PBRExtraData.y)      // scale on skyUpper at w = 1

float3 getAmbientLighting(float3 ambient, float3 albedo) {
    return ambient * TESR_PBRData.w * albedo;
}

float3 getAmbientLighting(float3 ambient, float3 albedo, float3 worldNormal, float worldNormalValid) {
    float3 flatAmbient = ambient * TESR_PBRData.w;

    // AmbientScale (TESR_PBRData.w) scales the weather ambient above but not this: the sky is a
    // second, independent light source, so SkylightingScale is its only strength knob and it
    // survives AmbientScale = 0.
    float3 skyTerm = SkyAmbientRadiance(worldNormal, TESR_PBRExtraData.z) * SKY_AMBIENT_STRENGTH;

    // worldNormalValid is 0 under a vanilla VS, where the carried world position is undefined.
    return (flatAmbient + skyTerm * worldNormalValid) * albedo;
}
