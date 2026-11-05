// UNOFFICIAL 2026-11-05 G-buffer (core/GBuffer.h; ported from Vegas Shaders' CapturedNormals / MaterialBuffer / AlbedoBuffer for the
// deferred flashlight, core/FlashlightDeferred.h). While the world's main opaque list draws, NVR's lit templates write three extra
// targets; the draw hook binds them only for those templates' opaque draws (anything else has them masked or unbound), so COLOR1-3
// are discarded everywhere else. Compiled in with GBUFFER_ON (ShaderRecord::AppendGlobalDefines: the flashlight on at startup).
//   COLOR1 (TESR_GBufferAlbedo)   rgb the base colour the light is multiplied by, in the GAME's gamma space (the pass decodes it),
//                                 a the share of added light the draw's fog lets through (1 - fog), 0 = nothing written
//   COLOR2 (TESR_GBufferMaterial) r the material class (1 object, 4 land, 6 skin) + 0.49 x metal, g the specular weight (authored
//                                 materials) or the vanilla specular mask, b the roughness (authored, >= 0) or minus the vanilla
//                                 glossiness (< 0), a 1
//   COLOR3 (TESR_GBufferNormal)   rg the world normal facing the camera (octahedral), b the camera distance, a 1 (2 an actor's skin)
#ifndef NVR_GBUFFER_HLSL
#define NVR_GBUFFER_HLSL

#ifndef GBUFFER_ON
    #define GBUFFER_ON 0
#endif

float2 GBufferEncodeNormal(float3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    float2 o = n.xy;
    [flatten] if (n.z < 0.0f) o = (1.0f - abs(n.yx)) * (n.xy >= 0.0f ? 1.0f : -1.0f);
    return o;
}

float3 GBufferDecodeNormal(float2 o) {
    float3 n = float3(o, 1.0f - abs(o.x) - abs(o.y));
    [flatten] if (n.z < 0.0f) n.xy = (1.0f - abs(n.yx)) * (n.xy >= 0.0f ? 1.0f : -1.0f);
    return normalize(n);
}

#if GBUFFER_ON
    // n: a world normal (any length), worldPos: the camera-relative world position.
    float4 GBufferNormalOut(float3 n, float3 worldPos, float written) {
        const float len2 = dot(n, n);
        [flatten] if (len2 < 1.0e-6f) return 0.0f;
        n *= rsqrt(len2);
        n *= dot(n, worldPos) > 0.0f ? -1.0f : 1.0f;	// the side the camera sees (two-sided cards, cloth)
        return float4(GBufferEncodeNormal(n), length(worldPos), written);
    }
    #define GBufferAlbedoOut(gammaRgb, keep) float4(saturate(gammaRgb), saturate(keep))
    #define GBufferMaterialOut(materialClass, metal, specular, roughOrShine) float4((materialClass) + 0.49f * saturate(metal), (specular), (roughOrShine), 1.0f)
#endif

#endif
