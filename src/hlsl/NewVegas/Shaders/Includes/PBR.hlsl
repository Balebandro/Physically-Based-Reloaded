// PBR calculations.
#if defined(__INTELLISENSE__)
    #include "Helpers.hlsl"
#endif

// Geometric specular AA
// http://www.jp.square-enix.com/tech/library/pdf/ImprovedGeometricSpecularAA.pdf
// https://www.jcgt.org/published/0010/02/02/paper.pdf
//
// Widens roughness where the NORMAL varies fast across a pixel's screen-space footprint --
// exactly what a high-frequency normal map (hair, being the sharpest example NVR ships) does.
// Without this, a GGX peak scales roughly as 1/roughness^4: two adjacent texels whose gloss
// differs by 10 points (0.85 vs 0.95) put out about an 80x difference in peak brightness, pure
// per-texel noise the material texture never intended anyone to resolve. In ObjectTemplate.hlsl
// that noise is the HAIR (ONLY_SPECULAR) pass's own alpha-blend weight, so it showed up as a
// splotchy, moth-eaten alpha pattern rather than as a shimmer in the highlight itself.
float SpecularAA(float3 normal, float roughness) {
    const float SIGMA2 = 0.15915494;
    const float KAPPA = 0.18;
    float3 dndu = ddx(normal);
    float3 dndv = ddy(normal);
    float variance = SIGMA2 * (dot(dndu, dndu) + dot(dndv, dndv));
    float kernel_roughness = min(KAPPA, variance);
    return sqrt(saturate(roughness * roughness + kernel_roughness));
}

// Fresnel
// Schlick approximation
float3 Fresnel(float3 f0, float3 f90, float cosine) {
    return f0 + (f90 - f0) * pow(1 - cosine, 5.f);
}

// Diffuse
// Lambert
float3 LambertianDiffuse(float3 albedo, float3 fresnel) {
    return (1 - fresnel) * albedo / PI;
}

float3 DisneyDiffuse(float3 albedo, float roughness, float NdotV, float NdotL, float LdotH) {
    const float linearRoughness = roughness * roughness;
    
    const float energyBias = lerp (0, 0.5 , linearRoughness);
    const float energyFactor = lerp (1.0, 1.0 / 1.51, linearRoughness);
    const float fd90 = energyBias + 2.0 * LdotH * LdotH * linearRoughness;
    const float3 f0 = float(1.0).xxx;
    const float lightScatter = Fresnel(f0, fd90, NdotL).r;
    const float viewScatter = Fresnel(f0, fd90, NdotV).r;

    return (albedo / PI) * lightScatter * viewScatter * energyFactor;
}

// Specular
// D (normal distribution function)
float GGX(float NdotH, float roughness) {
    float alpha = roughness * roughness;
    float a2 = pow(roughness, 4);
    float d = max((NdotH * a2 - NdotH) * NdotH + 1, 1e-5);
    return a2 / (PI * d * d);
}

// G1
float ShlickBeckmann(float NdotX, float roughness) {
    float k = pow(roughness + 1, 2) / 8.0;
    return NdotX/max(NdotX * (1 - k) + k, 0.00000001);
}

// Smith
float GeometryShadowing(float roughness, float NdotV, float NdotL) {
    return ShlickBeckmann(NdotV, roughness) * ShlickBeckmann(NdotL, roughness);
}

// F
float3 FresnelShlick(float3 reflectance, float3 halfway, float3 eyeDir) {
    return reflectance + (1 - reflectance) * pow(1 - shades(halfway, eyeDir), 5.0);
}

// BRDF
float3 BRDF(float roughness, float3 fresnel, float NdotV, float NdotL, float NdotH){
    float3 num = GGX(NdotH, roughness) * GeometryShadowing(roughness, NdotV, NdotL) * fresnel;
    float denom = 4.0 * NdotV * NdotL;
    return num/denom;
}

// --- Lighting space ---------------------------------------------------------------------------
// The game lights in GAMMA space: textures and light colours are gamma-encoded and multiplied
// as they are. Products survive that (sqrt(a) * sqrt(b) = sqrt(ab)), but the cosine, the BRDF
// and every sum of light do not: falloff toward the terminator comes out too soft and sums of
// lights too bright, which flattens everything a physically based model is meant to shape.
//
// With linear lighting on ([Shaders.PBR.Main] LinearLighting / [Shaders.Terrain.Main], set by
// the template through linearLighting), colours are decoded on the way in (x^2, the same
// encoding SkyAmbient.hlsl uses), all lighting is computed and summed linearly, and the result
// is encoded once at the end. Off, decode and encode do nothing and this is the old behaviour.
static bool linearLighting = false;

float3 decodeColor(float3 c) { return linearLighting ? c * c : c; }
float3 encodeColor(float3 c) { return linearLighting ? sqrt(max(c, 0.0f)) : c; }

// Blinn-Phong exponent (vanilla glossiness, NiMaterialProperty::m_fShine or a land layer's
// specular exponent) to GGX roughness: alpha = sqrt(2 / (n + 2)), roughness = sqrt(alpha).
float shineToRoughness(float shine) {
    return pow(2.0f / (max(shine, 0.0f) + 2.0f), 0.25f);
}

// --- Direct lighting --------------------------------------------------------------------------
// All of these return light in the caller's units with PI folded in: a Lambertian surface lit
// head-on returns albedo * lightColor. specScale scales the specular lobe only (a material's
// specular mask times the specular strength setting).
//
// Diffuse is plain Lambert in every variant. It used to be (1 - F(L.H)) * Lambert where a
// specular lobe existed and plain Lambert where it did not, so the same mesh changed
// brightness at grazing light depending on which shader variant the game drew it with (and
// it switches with distance and light count).

float3 PBRDiffuse(float metallicness, float roughness, float3 albedo, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor) {
    const float NdotL = shades(normalize(normal), normalize(lightDir));
    return (1 - metallicness) * albedo * NdotL * lightColor;
}

// GGX specular for one light direction, times N.L, PI and the light.
float3 SpecularLobe(float3 f0, float roughness, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor) {
    const float3 halfway = normalize(eyeDir + lightDir);
    const float NdotL = max(shades(normal, lightDir), 0.00001);
    const float NdotV = max(shades(normal, eyeDir), 0.00001);
    const float NdotH = shades(normal, halfway);
    const float LdotH = shades(lightDir, halfway);
    const float3 fresnel = Fresnel(f0, (1.0).xxx, LdotH);
    return BRDF(roughness, fresnel, NdotV, NdotL, NdotH) * NdotL * lightColor * PI;
}

float3 PBRSpecular(float metallicness, float roughness, float3 albedo, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor, float specScale = 1.0f) {
    const float3 f0 = lerp(float(0.04).rrr, albedo, metallicness);
    return SpecularLobe(f0, roughness, normalize(normal), normalize(eyeDir), normalize(lightDir), lightColor) * specScale;
}

float3 PBR(float metallicness, float roughness, float3 albedo, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor, float specScale = 1.0f) {
    return PBRDiffuse(metallicness, roughness, albedo, normal, eyeDir, lightDir, lightColor)
         + PBRSpecular(metallicness, roughness, albedo, normal, eyeDir, lightDir, lightColor, specScale);
}

// The sun is a disc, not a point: its angular radius in radians (the full disc is about 0.53
// degrees; this is generous, as the old value was).
#define SUN_RADIUS 0.00918043

// Karis' representative point (Real Shading in Unreal Engine 4, 2013): the point of the sun's
// disc nearest the VIEW reflection, plus the normalisation that keeps the lobe widened to cover
// the disc from gaining energy. The old version reflected the LIGHT direction instead of the
// view, which never lands on the disc, so the sun was effectively a point light and the
// normalisation was missing.
float3 SunSpecularDir(float3 normal, float3 eyeDir, float3 lightDir, float roughness, out float normalization) {
    const float3 r = reflect(-eyeDir, normal);
    const float3 centerToRay = dot(lightDir, r) * r - lightDir;
    const float3 closest = lightDir + centerToRay * saturate(SUN_RADIUS / max(length(centerToRay), 1e-5f));

    const float alpha = roughness * roughness;
    const float alphaPrime = saturate(alpha + SUN_RADIUS * 0.5f);
    normalization = (alpha / alphaPrime) * (alpha / alphaPrime);

    return normalize(closest);
}

float3 PBRSunSpecular(float metallicness, float roughness, float3 albedo, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor, float specScale = 1.0f) {
    const float3 f0 = lerp(float(0.04).rrr, albedo, metallicness);
    normal = normalize(normal);
    eyeDir = normalize(eyeDir);
    lightDir = normalize(lightDir);

    float normalization;
    const float3 sunDir = SunSpecularDir(normal, eyeDir, lightDir, roughness, normalization);
    return SpecularLobe(f0, roughness, normal, eyeDir, sunDir, lightColor) * normalization * specScale;
}

float3 PBRSun(float metallicness, float roughness, float3 albedo, float3 normal, float3 eyeDir, float3 lightDir, float3 lightColor, float specScale = 1.0f) {
    return PBRDiffuse(metallicness, roughness, albedo, normal, eyeDir, lightDir, lightColor)
         + PBRSunSpecular(metallicness, roughness, albedo, normal, eyeDir, lightDir, lightColor, specScale);
}
