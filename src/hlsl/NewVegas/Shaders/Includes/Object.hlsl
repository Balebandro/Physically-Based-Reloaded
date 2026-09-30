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

// --- Sky reflections ------------------------------------------------------------------------
// Specular counterpart of the hemisphere skylight above: what the sky contributes as a
// reflection rather than as diffuse light. Without it a glossy surface has nothing to reflect
// but the sun's own highlight, and reads as matte from every other angle.
//
// There is no environment map. The sky is low frequency, and TESR_SkyIrradiance already holds
// it as order-2 spherical harmonics convolved with the cosine lobe (A0/pi = 1, A1/pi = 2/3,
// A2/pi = 1/4, see SkyShaders::UpdateConstants). Dividing those factors back out recovers the
// radiance itself, as sharp as nine coefficients can hold it; leaving them in is the fully
// rough answer. Roughness blends between the two, band by band.
//
// The reflection DIRECTION uses the geometric normal: a world-space shading normal is not
// available here (the normal map is in tangent space) and the sky varies too slowly for it to
// matter. The Fresnel term does use the shading normal, so normal map detail still shows.
//
// [Shaders.PBR.*] SkyReflectionScale, 0 disables. Interiors default to 0: there is no sky
// occlusion, so indoors this would light every glossy surface from a sky it cannot see.
#define SKY_REFLECTION_STRENGTH  (TESR_PBRExtraData.w)
#define SKY_REFLECTION_GROUND    0.15f      // albedo of the ground seen in downward reflections

// Karis' analytic fit to the split-sum environment BRDF (Unreal Engine 4 mobile).
float3 EnvBRDFApprox(float3 f0, float roughness, float NdotV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NdotV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// worldPos is camera-relative, as GetShadowWorldPos builds it. normal and viewDir are in
// tangent space, as the templates carry them. valid is 0 under a vanilla vertex shader.
float3 getSkyReflection(float3 worldPos, float3 geometricNormal, float3 normal, float3 viewDir, float3 albedo, float roughness, float valid) {
#if SKYLIGHTING_MODE == 0
    float3 r = reflect(normalize(worldPos), geometricNormal);

    float band1 = lerp(1.5f, 1.0f, roughness);
    float band2 = lerp(4.0f, 1.0f, roughness);
    float3 radiance = TESR_SkyIrradiance[0].rgb
         + band1 * (TESR_SkyIrradiance[1].rgb * r.y
                  + TESR_SkyIrradiance[2].rgb * r.z
                  + TESR_SkyIrradiance[3].rgb * r.x)
         + band2 * (TESR_SkyIrradiance[4].rgb * (r.x * r.y)
                  + TESR_SkyIrradiance[5].rgb * (r.y * r.z)
                  + TESR_SkyIrradiance[6].rgb * (3.0f * r.z * r.z - 1.0f)
                  + TESR_SkyIrradiance[7].rgb * (r.x * r.z)
                  + TESR_SkyIrradiance[8].rgb * (r.x * r.x - r.y * r.y));

    // The projection holds no radiance below the horizon, so a reflection pointing down would
    // see black. Give it the ground instead: what an upward facing surface receives from the
    // sky, times an albedo.
    float3 skyOnGround = TESR_SkyIrradiance[0].rgb + TESR_SkyIrradiance[2].rgb + 2.0f * TESR_SkyIrradiance[6].rgb;
    radiance = max(radiance, 0.0f) + max(skyOnGround, 0.0f) * (SKY_REFLECTION_GROUND * saturate(-r.z));

    float NdotV = saturate(dot(normal, normalize(viewDir)));
    float3 f0 = lerp(float(0.04f).rrr, albedo, TESR_PBRData.x);

    // Encoded like the skylight, see SkyAmbient.hlsl. The select keeps an undefined worldPos
    // from reaching the output as NaN.
    float3 reflection = sqrt(radiance) * EnvBRDFApprox(f0, roughness, NdotV) * SKY_REFLECTION_STRENGTH;
    return valid > 0.0f ? reflection : 0.0f;
#else
    return 0.0f;
#endif
}

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
