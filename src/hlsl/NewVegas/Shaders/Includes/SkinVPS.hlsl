// Vanilla Plus Skin compatibility: lighting + bone-skinning helpers.
//
// Ported from pr0bability/fnv-vanilla-plus-skin (shaders/includes/Lighting.hlsli and
// shaders/includes/Skin.hlsli, GPLv3, used with the author's permission) so that
// SkinVPSTemplate.hlsl can reproduce VPS's own subsurface-scattering lighting model bit for
// bit. Relies on Includes/Helpers.hlsl (shades/sqr/etc.) already being included -- VPS's own
// Helpers.hlsli defines the identical macros, so there's no need to duplicate them here.
#ifndef SKINVPS_INCLUDED
#define SKINVPS_INCLUDED

// Vanilla pointlight attenuation. Defined in VPS's own Helpers.hlsli, not NVR's Includes/
// Helpers.hlsl -- every macro SkinVPSTemplate.hlsl needs from that file is shared between the
// two, but this one is an actual function unique to VPS's copy, so it has to be ported too.
float VanillaAttenuation(float3 lightDir, float radius) {
    const float3 att = lightDir / radius;
    return 1 - saturate(dot(att, att));
}

// Calculate directional curvature from light direction and curvature tensor.
// https://www.glowybits.com/talks/samurai_shading_in_ghost_of_tsushima/#/105
float CurvatureFromLight(
    float3 tangent,
    float3 bitangent,
    float3 curvTensor,
    float3 lightDir
) {
    float2 lightDirProj = float2(dot(lightDir, tangent), dot(lightDir, bitangent));

    float curvature = curvTensor.x * (lightDirProj.x * lightDirProj.x) +
                        2.0f * curvTensor.y * lightDirProj.x * lightDirProj.y +
                        curvTensor.z * (lightDirProj.y * lightDirProj.y);

    // Scale closer to the LUT level - proper value would be ~0.07 for millimeters, but that
    // produces barely any results, especially in gamma pipeline.
    return curvature * 0.5f;
}

// Calculate subsurface scattering modified NdotL. Simulates diffusion through tiny bumps with
// a softened normal that is blended, and three separate samples of the skin LUT are taken.
float3 CalculateSubsurfaceScattering(sampler2D skinLUT, float3 normal, float3 normalSoft, float3 lightDirection, float curvature) {
    float3 normalRed = lerp(normal, normalSoft, 1.0f);
    float3 normalGreen = lerp(normal, normalSoft, 0.6f);
    float3 normalBlue = lerp(normal, normalSoft, 0.3f);

    float3 NdotL = float3(
        dot(normalRed, lightDirection),
        dot(normalGreen, lightDirection),
        dot(normalBlue, lightDirection)
    );
    NdotL = NdotL * 0.5f + 0.5f;

    float3 SSS;
    SSS.r = tex2Dlod(skinLUT, float4(NdotL.r, 1.0f - curvature, 0.0f, 0.0f)).r;
    SSS.g = tex2Dlod(skinLUT, float4(NdotL.g, 1.0f - curvature, 0.0f, 0.0f)).g;
    SSS.b = tex2Dlod(skinLUT, float4(NdotL.b, 1.0f - curvature, 0.0f, 0.0f)).b;

    return SSS;
}

// Calculates Blinn-Phong lighting with subsurface scattering. Vectors are assumed to be in the
// same space.
float3 CalculateLighting(
    sampler2D skinLUT,
    float3 diffuse,
    float3 normal,
    float3 normalSoft,
    float3 viewDir,
    float3 lightDir,
    float3 lightColor,
    float3 curvatureTensor,
    float3 vertexTangent,
    float3 vertexBinormal,
    float gloss,
    float specExponent
) {
    lightDir = normalize(lightDir);
    viewDir = normalize(viewDir);

    float curvature = CurvatureFromLight(vertexTangent, vertexBinormal, curvatureTensor.xyz, lightDir);
    float3 SSS = CalculateSubsurfaceScattering(skinLUT, normal, normalSoft, lightDir, curvature);

    // We could theoretically de-linearize the SSS here, however, that very noticeably changes
    // the vanilla shading. Decided to keep linear (same as NdotL in vanilla).

    #ifdef SPECULAR
        float3 halfwayDir = normalize(lightDir + viewDir);

        float NdotH = max(dot(normal.xyz, halfwayDir.xyz), 0.0f);

        float specStrength = gloss * pow(NdotH, specExponent);
        float3 lighting = (diffuse * SSS + specStrength) * lightColor.rgb;
    #else
        float3 lighting = diffuse * SSS * lightColor.rgb;
    #endif

    return lighting;
}

// Transform a position based on bones.
float3 BonesTransformPosition(float4 bones[54], float4 offset, float4 blend, float4 pos) {
    float3 result, helper;

    helper.x = dot(bones[offset.x].xyzw, pos.xyzw);
    helper.y = dot(bones[offset.x + 1].xyzw, pos.xyzw);
    helper.z = dot(bones[offset.x + 2].xyzw, pos.xyzw);
    result.xyz = helper.xyz * blend.x;

    helper.x = dot(bones[offset.y].xyzw, pos.xyzw);
    helper.y = dot(bones[offset.y + 1].xyzw, pos.xyzw);
    helper.z = dot(bones[offset.y + 2].xyzw, pos.xyzw);
    result.xyz += helper.xyz * blend.y;

    helper.x = dot(bones[offset.z].xyzw, pos.xyzw);
    helper.y = dot(bones[offset.z + 1].xyzw, pos.xyzw);
    helper.z = dot(bones[offset.z + 2].xyzw, pos.xyzw);
    result.xyz += helper.xyz * blend.z;

    helper.x = dot(bones[offset.w].xyzw, pos.xyzw);
    helper.y = dot(bones[offset.w + 1].xyzw, pos.xyzw);
    helper.z = dot(bones[offset.w + 2].xyzw, pos.xyzw);
    result.xyz += helper.xyz * blend.w;

    return result;
}

// Transform a vector based on bones.
float3 BonesTransformVector(float4 bones[54], float4 offset, float4 blend, float3 vec) {
    float3 result, helper;

    helper.x = dot(bones[offset.x].xyz, vec.xyz);
    helper.y = dot(bones[offset.x + 1].xyz, vec.xyz);
    helper.z = dot(bones[offset.x + 2].xyz, vec.xyz);
    result.xyz = helper.xyz * blend.x;

    helper.x = dot(bones[offset.y].xyz, vec.xyz);
    helper.y = dot(bones[offset.y + 1].xyz, vec.xyz);
    helper.z = dot(bones[offset.y + 2].xyz, vec.xyz);
    result.xyz += helper.xyz * blend.y;

    helper.x = dot(bones[offset.z].xyz, vec.xyz);
    helper.y = dot(bones[offset.z + 1].xyz, vec.xyz);
    helper.z = dot(bones[offset.z + 2].xyz, vec.xyz);
    result.xyz += helper.xyz * blend.z;

    helper.x = dot(bones[offset.w].xyz, vec.xyz);
    helper.y = dot(bones[offset.w + 1].xyz, vec.xyz);
    helper.z = dot(bones[offset.w + 2].xyz, vec.xyz);
    result.xyz += helper.xyz * blend.w;

    return result;
}

// Transform TBN with bones.
float3x3 BonesTransformTBN(float4 bones[54], float4 offset, float4 blend, float3 tangent, float3 binormal, float3 normal) {
    return float3x3(
        normalize(BonesTransformVector(bones, offset, blend, tangent)),
        normalize(BonesTransformVector(bones, offset, blend, binormal)),
        normalize(BonesTransformVector(bones, offset, blend, normal))
    );
}

#endif
