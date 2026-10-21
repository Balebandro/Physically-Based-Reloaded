// Pointlight helper functions.

#if defined(__INTELLISENSE__)
    #include "Helpers.hlsl"
#endif

#ifndef POINTLIGHTS_INCLUDED
#define POINTLIGHTS_INCLUDED

// The look of path-traced lamps, without tracing anything ([Shaders.PBR.Lamps]; PBRShaders::UpdateConstants):
//   x  HotCore F: the falloff's shape, att' = N (1 - u) / (1 + F u), u = (distance / radius)^2. 0 is vanilla's 1 - u;
//      higher is brighter near the lamp and softer toward its edge, a hot core with a long tail
//   y  N: keeps a lit surface's total light as vanilla's (worked out for F on the CPU)
//   z  Bounce: a lamp's light coming back off what is around it, a soft fill in its colour, more on the sides turned
//      away from it
//   w  Softness: the lamp's N.L wrapped by this much, so normal maps shade softer under lamps
// Applied where each lamp is lit (getPointLightLightingAtt and the others), never to the sun.
#if defined(PS) || defined(LAMP_LOOK_PS)   // pixel shaders; the grass one has no PS define
float4 TESR_LampLook : register(c189);
#else
static const float4 TESR_LampLook = float4(0.0f, 1.0f, 0.0f, 0.0f);
#endif

// A lamp's attenuation as vanilla works it out (1 - u, 0 beyond the radius) given the hot-core shape.
float lampFalloff(float att) {
    return att * TESR_LampLook.y / (1.0f + TESR_LampLook.x * (1.0f - att));
}

// The lamp's N.L, wrapped by Softness.
float lampNdotL(float NdotL) {
    return saturate((NdotL + TESR_LampLook.w) / (1.0f + TESR_LampLook.w));
}

// The bounce's share of a lamp's light on a surface: its N.L (-1 to 1) facing away gets more.
float lampBounce(float NdotL) {
    return TESR_LampLook.z * (0.6f - 0.4f * NdotL);
}

#endif

// Vanilla attenuation, lightVector not normalized.
float vanillaAtt(float3 lightVector, float radius) {
    const float3 att = lightVector / radius;
    return 1 - shades(att, att);
}

// Same formula as vanillaAtt, but from a precomputed object-space squared distance rather than
// a light vector. vanillaAtt(lightVector, radius) == 1 - saturate(dot(lightVector, lightVector)
// / radius^2), so this is exact, not an approximation -- it just lets the caller supply
// dot(light, light) computed in object space instead of a vector that may have been carried
// through a (possibly non-orthonormal) TBN transform, where length is not preserved.
float vanillaAttSq(float distSq, float radius) {
    return 1 - saturate(distSq / (radius * radius));
}

// https://lisyarus.github.io/blog/posts/point-light-attenuation.html
float lisyarusAtt(float3 lightVector, float radius, float falloff=5.0) {
    const float3 normalized = lightVector / radius;
    const float s2 = shades(normalized, normalized);

    return sqr(1 - s2) / (1 + falloff * s2);
}

// Modified Frostbite attenuation (UE4), lightVector not normalized.
float frostbiteAtt(float3 lightVector, float radius) {
    const float squaredDistance = dot(lightVector, lightVector);
    const float invSqrRadius = 1.f / (radius * radius);
    const float factor = squaredDistance * invSqrRadius;
    const float smoothFactor = saturate(1.f - factor * factor);
    const float smoothDistanceAtt = smoothFactor * smoothFactor;
    
    return smoothDistanceAtt / (squaredDistance + 1);
}
