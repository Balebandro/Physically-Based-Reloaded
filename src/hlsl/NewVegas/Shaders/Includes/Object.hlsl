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

// [Shaders.PBR.*], blended by weather and time (PBRShaders::UpdateConstants).
float4 TESR_PBRData : register(c32);        // x: specular strength, y: roughness scale, z: light scale, w: ambient scale
float4 TESR_PBRExtraData : register(c33);   // x: saturation, y: skylight strength, z: vanilla-matched highlights, w: linear lighting
// [Shaders.PBR.Main] specular: x default roughness (below 0: SpecularOnAll off),
// y sky reflection strength (0 off, and 0 in interiors), z specular occlusion on,
// w ambient normal detail.
float4 TESR_PBRSpecularData : register(c151);
// [Shaders.PBR.Main] x DebugView (0 off).
float4 TESR_PBRDebugData : register(c153);

// Per-object data written for every draw by SetShadersHook (Hooks/Render.cpp), NOT through
// the TESR_ constant table, hence the name: x is 1 when the mesh carries the engine's Specular
// flag (BSSP_SPECULAR). Such a mesh gets its highlight from the game's own specular shaders or
// passes; every other mesh has none unless we add one. y is the engine's specular distance
// fade for flagged meshes (1 otherwise), which vanilla applies to the whole highlight.
float4 ObjectMaterial : register(c150);

// --- Material ---------------------------------------------------------------------------------
// What the engine gives a lit mesh (ShadowLightShader::UpdateTogglesConstant): Toggles.z is the
// material's glossiness, NiMaterialProperty::m_fShine (30 without one), the Blinn-Phong
// exponent vanilla raises N.H to; the normal map alpha is the specular MASK, how strong the
// highlight is: vanilla's spec = mask * pow(N.H, shine).
//
// So the exponent gives the roughness (the Blinn-Phong to GGX mapping alpha = sqrt(2 / (n + 2)),
// roughness = sqrt(alpha)) and the mask scales the highlight and the reflection. The old code
// read the mask as gloss (roughness = 1 - mask), so unmasked areas got a broad full-strength
// highlight, masked ones a needle, and every mesh's own glossiness was ignored.
float getMaterialRoughness(float shine) {
    return clamp(shineToRoughness(shine) * TESR_PBRData.y, 0.04f, 1.0f);
}

// Hair and the parallax shaders keep the old mask-as-gloss reading.
float getRoughness(float gloss) {
    return saturate(max(0.043, 1 - gloss) * TESR_PBRData.y);
}

// --- Light-only passes ---------------------------------------------------------------------
// Meshes lit by several lights or casting projected shadows (actors especially) are drawn in
// two passes: an AD pass with the albedo forced to 1 (ONLY_LIGHT, AD), then a separate texture
// pass that MULTIPLIES the frame by the diffuse texture (BSShaderProperty::AddPass::Texture,
// BSSM_TEXTURE*). The engine still binds the diffuse texture to stage 0 for the AD pass
// (ShadowLightShader::UpdateDiffuseNormalStages), so the highlight and reflection this shader
// adds can be divided by it here; the texture pass multiplies them back to their true value,
// instead of tinting them with the albedo. Without this, such meshes got neither.
#if defined(ONLY_LIGHT) && !defined(DIFFUSE) && !defined(SPECULAR)
    #define AD_PASS
#endif

static float3 adCompensation = 1.0f;   // 1 / albedo in AD passes, 1 everywhere else

// albedo: the diffuse texture sample, gamma-encoded, before the AD pass forces it to 1. Call
// after setupMaterial (the divisor is the albedo in the lighting space). Capped at 8x: very dark
// texels lose some highlight rather than push huge values into the frame.
void setupADCompensation(float3 albedo) {
#ifdef AD_PASS
    adCompensation = 1.0f / max(decodeColor(albedo), 0.125f);
#endif
}

// Per pixel state, set by setupMaterial before any lighting call. Shaders that never call it
// (ParallaxTemplate) keep the defaults: gamma lighting, unscaled specular, no added highlight.
static float specularScale = 1.0f;     // direct specular lobe strength
static float reflectionScale = 1.0f;   // sky reflection strength
static float extraSpecular = 0.0f;     // 1 when this variant adds a highlight the game would not draw
static float extraRoughness = 1.0f;

// --- Highlights on every surface ([Shaders.PBR.Main] SpecularOnAll) ---------------------------
// The game only draws a highlight on meshes with its Specular flag; everything else goes
// through the diffuse-only shader variants, so most props, rocks and buildings never shine.
// Those variants add a highlight themselves, at DefaultRoughness and full strength: such meshes
// have no gloss data (the normal map alpha is not a specular mask there).
//
// Never for a mesh that HAS the flag: drawn with several lights, the game splits it into a
// diffuse-only pass plus its own specular passes (BSShaderPPLightingProperty::
// GetRenderPasses_2x), and adding one here would double it. Nor in the light-accumulation
// variants (ONLY_LIGHT, which DIFFUSE implies), whose output is later multiplied by the
// texture, nor for hair, which has its own specular pass.
#define DEFAULT_ROUGHNESS (clamp(TESR_PBRSpecularData.x, 0.05f, 1.0f))

// --- Vanilla-matched highlights ([Shaders.PBR.Main] VanillaMatchedHighlights) ---------------
// FNV's specular masks and glossiness were authored for vanilla's Blinn-Phong highlight,
// mask * pow(N.H, shine): its peak is mask x the light whatever the glossiness. A physically
// based GGX lobe for a dielectric (F0 0.04) peaks at F0 / (4 alpha^2) of the light, about 16% at
// vanilla's default glossiness of 30, so assets come out several times duller than their
// authors intended. This scales a flagged material's DIRECT highlight by 4 alpha^2 / F0, so its
// peak matches vanilla's for the same mask and glossiness while keeping the PBR shape (GGX,
// Fresnel, the sun's disc). 0 is physical, 1 is fully matched; capped at 12x for the very
// broad lobes of tiny glossiness values. Reflections stay physical: the sky is not a point light.
float vanillaMatchFactor(float roughness) {
    float alpha = roughness * roughness;
    float matched = clamp(4.0f * alpha * alpha / 0.04f, 1.0f, 12.0f);
    return lerp(1.0f, matched, saturate(TESR_PBRExtraData.z));
}

// specularMask: the normal map alpha. defaultRoughness: DEFAULT_ROUGHNESS after SpecularAA,
// computed at top level for its ddx/ddy. materialRoughness: the material's roughness BEFORE
// SpecularAA, for the vanilla match (matching the widened lobe would undo what the AA is for).
void setupMaterial(float specularMask, float defaultRoughness, float materialRoughness) {
    linearLighting = TESR_PBRExtraData.w > 0.0f;

#if defined(HAIR)
    specularScale = 1.0f;
    reflectionScale = 1.0f;
#else
    reflectionScale = specularMask * TESR_PBRData.x;
    // Matched against the material's own roughness, before the weather RoughnessScale: matching
    // the scaled one would hold the peak at vanilla's and cancel the brighter, tighter highlights
    // rain's lower roughness is meant to give.
    specularScale = reflectionScale * vanillaMatchFactor(saturate(materialRoughness / max(TESR_PBRData.y, 0.01f)));
#endif

    // The engine's specular distance fade (ObjectMaterial.y, 1 for unflagged meshes), so a
    // flagged mesh's highlight and reflection fade out where the game stops drawing its
    // specular pass instead of popping off. Not in the specular-only passes: the engine has
    // already multiplied their light colour by the same fade (BSShaderLightingProperty::SetLight1x2x).
#if !defined(ONLY_SPECULAR)
    specularScale *= saturate(ObjectMaterial.y);
    reflectionScale *= saturate(ObjectMaterial.y);
#endif

#if !defined(SPECULAR) && !defined(ONLY_SPECULAR) && (!defined(ONLY_LIGHT) || defined(AD_PASS)) && !defined(HAIR)
    extraSpecular = (TESR_PBRSpecularData.x >= 0.0f && ObjectMaterial.x < 0.5f) ? 1.0f : 0.0f;
    extraRoughness = defaultRoughness;
    // No gloss data and no vanilla highlight to match: physical strength.
    if (extraSpecular > 0.0f) {
        specularScale = TESR_PBRData.x;
        reflectionScale = TESR_PBRData.x;
    }
#endif
}

// --- Normal-mapped ambient ([Shaders.PBR.Main] AmbientNormalDetail) ------------------------
// The direct lights use the normal map in tangent space, but the sky light and reflections need
// to know which way each normal-mapped pixel faces in the WORLD: up toward the sky or down
// toward the ground. They used the smooth geometric normal, so on any surface the sun is not
// hitting, every fold, seam and panel line in the normal map vanished.
//
// The vertex shader expresses world UP in the normal map's own space, through the engine's own
// tangent frame (the world images of the mesh's tangent, binormal and normal, packed into spare
// interpolator channels). dot(normal map, that up) is then exactly how much each normal-mapped
// pixel faces the sky, with no tangent convention to match: it is the engine's frame.
//
// The ambient normal keeps the geometric normal's compass heading and takes its up/down from the
// normal map, which is what the sky and ground terms depend on most. AmbientNormalDetail blends
// the up/down toward the geometric normal's (0 is the old, flat behaviour). valid is 0 under a
// vanilla vertex shader, where the packed channels are undefined.
float3 getAmbientNormal(float3 normalTS, float3 upTS, float3 geometricNormal, float valid) {
    float mapUp = clamp(dot(normalTS, upTS), -1.0f, 1.0f);
    float detail = valid > 0.0f ? saturate(TESR_PBRSpecularData.w) : 0.0f;
    float up = lerp(geometricNormal.z, mapUp, detail);

    float2 heading = geometricNormal.xy;
    float headingLength = length(heading);
    heading = headingLength > 1e-4f ? heading / headingLength : float2(1.0f, 0.0f);
    return float3(heading * sqrt(saturate(1.0f - up * up)), up);
}

// Up in tangent space with z rebuilt from xy, for the variant with no channel spare for it. Its
// sign is the vertex normal's vertical sign, which the geometric normal shares.
float3 rebuildUpTS(float2 xy, float3 geometricNormal) {
    float z = sqrt(saturate(1.0f - dot(xy, xy)));
    return float3(xy, geometricNormal.z >= 0.0f ? z : -z);
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

// --- PBR direct lighting ----------------------------------------------------------------------
// lightColor arrives gamma-encoded, as the engine supplies it, with any GAMMA-space factor the
// vanilla pipeline applies already in (projected shadow maps, STBB's 0.85): decodeColor turns
// it linear when linear lighting is on. Point light attenuation is applied inside the decode,
// so lights keep the falloff the game was tuned with. visibility (the forward sun shadow) is a
// real visibility and is applied to the decoded light.

float3 getPointLightLightingAtt(float3 lightDir, float att, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness) {
    lightColor = decodeColor(lightColor * att) * TESR_PBRData.z;
    albedo = lerp(luma(albedo), albedo, TESR_PBRExtraData.x);

    #if defined(ONLY_SPECULAR)
        return PBRSpecular(0, roughness, albedo, normal, viewDir, lightDir, lightColor, specularScale);
    #elif defined(SPECULAR)
        return PBR(0, roughness, albedo, normal, viewDir, lightDir, lightColor, specularScale);
    #else
        [branch] if (extraSpecular > 0.0f)
            return PBRDiffuse(0, extraRoughness, albedo, normal, viewDir, lightDir, lightColor)
                 + PBRSpecular(0, extraRoughness, albedo, normal, viewDir, lightDir, lightColor, specularScale) * adCompensation;
        return PBRDiffuse(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #endif
}

float3 getPointLightLighting(float3 lightDir, float radius, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness) {
    return getPointLightLightingAtt(lightDir, vanillaAtt(lightDir, radius), lightColor, viewDir, normal, albedo, roughness);
}

float3 getSunLighting(float3 lightDir, float3 lightColor, float3 viewDir, float3 normal, float3 albedo, float roughness, float visibility = 1.0f) {
    lightColor = decodeColor(lightColor) * visibility * TESR_PBRData.z;
    albedo = lerp(luma(albedo), albedo, TESR_PBRExtraData.x);

    #if defined(ONLY_SPECULAR)
        return PBRSunSpecular(0, roughness, albedo, normal, viewDir, lightDir, lightColor, specularScale);
    #elif defined(SPECULAR)
        return PBRSun(0, roughness, albedo, normal, viewDir, lightDir, lightColor, specularScale);
    #else
        [branch] if (extraSpecular > 0.0f)
            return PBRDiffuse(0, extraRoughness, albedo, normal, viewDir, lightDir, lightColor)
                 + PBRSunSpecular(0, extraRoughness, albedo, normal, viewDir, lightDir, lightColor, specularScale) * adCompensation;
        return PBRDiffuse(0, roughness, albedo, normal, viewDir, lightDir, lightColor);
    #endif
}

// [_Main.Develop.Main], via Debug.cpp UpdateSettings. c135: c132 is TESR_ShadowBlur.
// Populated even with Shaders.Debug disabled -- Debug has no per-frame UpdateConstants.
float4 TESR_DebugVar : register(c135);

// --- Hemisphere skylight ------------------------------------------------------------------
// Additive upper-sky term on top of the weather ambient. [Shaders.PBR.*] SkylightingScale;
// no separate toggle, 0 disables the term.
#define SKY_AMBIENT_STRENGTH  (TESR_PBRExtraData.y)

// --- Sky reflections ([Shaders.PBR.Main] SkyReflectionScale) ------------------------------
// The specular counterpart of the skylight: what the sky contributes as a REFLECTION. Without
// it a surface reflects nothing but the sun's highlight and reads as matte from every other
// angle; with it, glancing angles pick up the sky (Fresnel) and rough surfaces a soft sheen.
//
// There is no environment map. The sky is TESR_SkyIrradiance, order-2 spherical harmonics
// convolved with the cosine lobe (A0/pi = 1, A1/pi = 2/3, A2/pi = 1/4, see
// SkyShaders::UpdateConstants): dividing those factors back out recovers the radiance as sharp
// as nine coefficients hold it, leaving them in is the fully rough answer, and roughness blends
// band by band.
//
// The reflection follows the per-pixel world normal (getAmbientNormal), so normal-map detail
// ripples through it; the horizon test uses the geometric normal.
//
// Interiors get 0 from the C++ side: nothing occludes this sky, so indoors it would light
// every surface from a sky it cannot see.
// SKY_REFLECTION_GROUND, EnvBRDFApprox and SkyReflectionRadiance live in SkyAmbient.hlsl, shared
// with the terrain shaders.

// worldPos is camera-relative, as GetShadowWorldPos builds it; normal is the world normal
// from getAmbientNormal. valid is 0 under a vanilla vertex shader.
float3 getSkyReflection(float3 worldPos, float3 geometricNormal, float3 normal, float roughness, float valid) {
    float3 v = -normalize(worldPos);
    float3 r = reflect(-v, normal);
    float3 radiance = SkyReflectionRadiance(r, roughness);
    float NdotV = saturate(dot(normal, v));

    // Specular occlusion ([Shaders.PBR.Main] SpecularOcclusion): a normal map can tilt the
    // reflection below the real surface, where it would see the inside of the object; fade it
    // out as it crosses the geometric horizon. Crevices are left to the ambient occlusion
    // effect, which darkens the final colour, reflections included.
    float horizon = 1.0f;
    [flatten] if (TESR_PBRSpecularData.z > 0.0f) {
        horizon = saturate(1.0f + 1.2f * dot(r, geometricNormal));
        horizon *= horizon;
    }

    // Radiance is linear: encode it for gamma lighting, as SkyAmbient.hlsl does for the
    // skylight. Dielectric F0 (metalness is 0 everywhere; nothing in FNV's data marks metal).
    // The select keeps an undefined worldPos from reaching the output as NaN.
    float3 sky = linearLighting ? radiance : sqrt(radiance);
    float3 reflected = EnvBRDFApprox(float(0.04f).rrr, roughness, NdotV) * horizon * reflectionScale * TESR_PBRSpecularData.y;
    skyReflectedFraction = valid > 0.0f ? saturate(reflected) : 0.0f;   // see SkyAmbient.hlsl
    return valid > 0.0f ? sky * reflected : 0.0f;
}

// Which surfaces reflect, and at what roughness. materialRoughness is the template's own; it
// is only meaningful on meshes with the Specular flag.
float3 getObjectSkyReflection(float3 worldPos, float3 geometricNormal, float3 normal, float materialRoughness, float valid) {
#if (defined(ONLY_LIGHT) && !defined(AD_PASS)) || defined(ONLY_SPECULAR) || defined(HAIR)
    return 0.0f;
#else
    #if defined(SPECULAR)
        float reflects = 1.0f;
        float roughness = materialRoughness;
    #else
        // A flagged mesh drawn as diffuse-only plus separate specular passes: those passes add
        // no ambient, so its reflection belongs here, at its own roughness. Unflagged meshes
        // reflect only with SpecularOnAll, at the default roughness.
        bool flagged = ObjectMaterial.x >= 0.5f;
        float reflects = flagged ? 1.0f : extraSpecular;
        float roughness = flagged ? materialRoughness : extraRoughness;
    #endif
    [branch] if (reflects * reflectionScale * TESR_PBRSpecularData.y <= 0.0f)
        return 0.0f;
    return getSkyReflection(worldPos, geometricNormal, normal, roughness, valid) * adCompensation;
#endif
}

// Both scaled by (1 - skyReflectedFraction): the energy balance with the sky reflection, which
// the templates evaluate first. See SkyAmbient.hlsl.
float3 getAmbientLighting(float3 ambient, float3 albedo) {
    return decodeColor(ambient) * TESR_PBRData.w * albedo * (1.0f - skyReflectedFraction);
}

float3 getAmbientLighting(float3 ambient, float3 albedo, float3 worldNormal, float worldNormalValid) {
    float3 flatAmbient = decodeColor(ambient) * TESR_PBRData.w;

    // AmbientScale (TESR_PBRData.w) scales the weather ambient above but not this: the sky is a
    // second, independent light source, so SkylightingScale is its only strength knob and it
    // survives AmbientScale = 0. Decoded on its own before the sum, as SkyAmbientRadiance
    // returns it encoded.
    float3 skyTerm = decodeColor(SkyAmbientRadiance(worldNormal)) * SKY_AMBIENT_STRENGTH;

    // worldNormalValid is 0 under a vanilla VS, where the carried world position is undefined.
    return (flatAmbient + skyTerm * worldNormalValid) * albedo * (1.0f - skyReflectedFraction);
}

// --- Material debug view ([Shaders.PBR.Main] DebugView) -------------------------------------
// 1 roughness, 2 highlight strength (mask x SpecularStrength x vanilla match x distance fade, /4), 3 flags (red: the
// mesh has the engine's Specular flag, green: its specular distance fade, blue: highlight added by
// SpecularOnAll), 4 ambient normal (how much each pixel faces the sky: white up, black down).
float3 getMaterialDebug(float mode, float roughness, float3 ambientNormal) {
    float r = extraSpecular > 0.0f ? extraRoughness : roughness;
    if (mode < 1.5f) return r.xxx;
    if (mode < 2.5f) return saturate(specularScale * 0.25f).xxx;
    if (mode < 3.5f) return float3(ObjectMaterial.x, saturate(ObjectMaterial.y), extraSpecular);
    return (ambientNormal.z * 0.5f + 0.5f).xxx;
}
