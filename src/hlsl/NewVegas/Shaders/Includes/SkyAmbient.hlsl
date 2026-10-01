// Sky-colour ambient for the lighting shaders (objects, parallax, terrain, skin, hair, grass,
// decals): the sky's irradiance as order-2 spherical harmonics.
//
// Returns a GAMMA-ENCODED value: the lighting shaders work in the game's gamma space unless
// linear lighting decodes it (see "Lighting space" in PBR.hlsl). The encode is sqrt(), i.e.
// gamma 2.0, not the sRGB curve: one instruction per channel against a pow.
//
// (There used to be a second, compile-time "SkylightingMode 1": one sky sample along a
// direction leaning from up toward the normal. A point sample cannot represent a hemisphere,
// and it pinned floors and terrain to the zenith colour; it was removed.)
#ifndef SKYAMBIENT_INCLUDED
#define SKYAMBIENT_INCLUDED

// SkyShaders::UpdateConstants projects the sky -- the same GetSkyColor that SKY.pso renders the
// dome with -- onto 9 coefficients once per frame and convolves them with the clamped-cosine
// kernel, so this evaluates
//
//     E(N) = INTEGRAL L(w) max(N.w, 0) dw
//
// rather than approximating it by a sample direction. The cosine kernel is a severe low-pass
// filter, so 9 coefficients carry that integral to within about 1% (Ramamoorthi & Hanrahan
// 2001).
//
// The projection runs on LINEAR radiance, which is what the integral is defined on; the
// reconstruction below is encoded.
//
// The cosine form factor, the wall/floor split and the sun-side azimuthal bias are all inherent
// to the convolution.
float4 TESR_SkyIrradiance[9] : register(c137);

// worldNormal must be the GEOMETRIC world normal, unit length.
float3 SkyAmbientRadiance(float3 worldNormal) {
    float3 n = worldNormal;

    // Reconstruction is LINEAR irradiance; encode it. max() first because an order-2 SH fit can
    // ring slightly negative, and sqrt of a negative is NaN.
    float3 irradiance = TESR_SkyIrradiance[0].rgb
         + TESR_SkyIrradiance[1].rgb * n.y
         + TESR_SkyIrradiance[2].rgb * n.z
         + TESR_SkyIrradiance[3].rgb * n.x
         + TESR_SkyIrradiance[4].rgb * (n.x * n.y)
         + TESR_SkyIrradiance[5].rgb * (n.y * n.z)
         + TESR_SkyIrradiance[6].rgb * (3.0f * n.z * n.z - 1.0f)
         + TESR_SkyIrradiance[7].rgb * (n.x * n.z)
         + TESR_SkyIrradiance[8].rgb * (n.x * n.x - n.y * n.y);

    return sqrt(max(irradiance, 0.0f));
}

// --- Sky reflections, shared by the object and terrain shaders ------------------------------
// Rebuilt from the same SH: dividing the cosine-lobe factors back out (A0/pi = 1, A1/pi = 2/3,
// A2/pi = 1/4) recovers the radiance as sharp as nine coefficients hold it, and roughness blends
// back toward the convolved, fully rough answer band by band. See getSkyReflection in Object.hlsl.
// Energy balance between the sky's two contributions: the fraction of the environment light a
// pixel reflects specularly (its sky reflection's environment BRDF x strength) is light its
// diffuse ambient must not also scatter. The reflection function sets it, the ambient multiplies
// by (1 - it), so the reflection has to be evaluated FIRST. 0 where nothing is reflected.
static float3 skyReflectedFraction = 0.0f;

#define SKY_REFLECTION_GROUND 0.15f      // albedo of the ground seen in downward reflections

// Karis' analytic fit to the split-sum environment BRDF (Unreal Engine 4 mobile).
float3 EnvBRDFApprox(float3 f0, float roughness, float NdotV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NdotV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// LINEAR sky radiance along a world direction, blurred toward the cosine-convolved sky by roughness.
float3 SkyReflectionRadiance(float3 r, float roughness) {
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
    // see black. Give it the ground: what an upward facing surface receives, times an albedo.
    float3 skyOnGround = TESR_SkyIrradiance[0].rgb + TESR_SkyIrradiance[2].rgb + 2.0f * TESR_SkyIrradiance[6].rgb;
    return max(radiance, 0.0f) + max(skyOnGround, 0.0f) * (SKY_REFLECTION_GROUND * saturate(-r.z));
}

#endif
