// Template for object lighting shaders.
//
// VS
//
// AD
// SLS2028 - LIGHTS = 2 (ONLY_LIGHT)
// SLS2029 - LIGHTS = 2, SKIN (ONLY_LIGHT)
// SLS2030 - LIGHTS = 2, PROJ_SHADOW (ONLY_LIGHT)
// SLS2031 - LIGHTS = 2, PROJ_SHADOW, SKIN (ONLY_LIGHT)
// SLS2032 - LIGHTS = 3 (ONLY_LIGHT)
// SLS2033 - LIGHTS = 3, SKIN (ONLY_LIGHT)
// SLS2034 - LIGHTS = 3, PROJ_SHADOW (ONLY_LIGHT)
// SLS2035 - LIGHTS = 3, PROJ_SHADOW, SKIN (ONLY_LIGHT)
//
// ADTS
// SLS2000 - Base
// SLS2001 - LOD
// SLS2003 - SKIN
// SLS2004 - PROJ_SHADOW
// SLS2006 - PROJ_SHADOW, SKIN
// SLS2007 - STBB
// SLS2008 - LIGHTS = 2
// SLS2009 - LIGHTS = 2, SKIN
// SLS2010 - LIGHTS = 2, PROJ_SHADOW
// SLS2011 - LIGHTS = 2, PROJ_SHADOW, SKIN
// SLS2012 - SPECULAR
// SLS2013 - SPECULAR, SKIN
// SLS2014 - SPECULAR, PROJ_SHADOW
// SLS2015 - SPECULAR, PROJ_SHADOW, SKIN
// SLS2016 - SPECULAR, LIGHTS = 2
// SLS2017 - SPECULAR, LIGHTS = 2, SKIN
// SLS2018 - SPECULAR, LIGHTS = 2, PROJ_SHADOW
// SLS2019 - SPECULAR, LIGHTS = 2, PROJ_SHADOW, SKIN
// (ignored) SLS2102 - LIGHTS = 0
//
// ADTS10
// SLS2020 - LIGHTS = 9
// SLS2021 - LIGHTS = 9, SKIN
// SLS2022 - LIGHTS = 4
// SLS2023 - LIGHTS = 4, OPT
// SLS2024 - LIGHTS = 4, SKIN
// SLS2025 - LIGHTS = 4, SPECULAR
// SLS2026 - LIGHTS = 4, SPECULAR, OPT
// SLS2027 - LIGHTS = 4, SPECULAR, SKIN
//
// DiffusePt
// SLS2036 - LIGHTS = 2 (DIFFUSE)
// SLS2037 - LIGHTS = 2, SKIN (DIFFUSE)
// SLS2038 - LIGHTS = 3 (DIFFUSE)
// SLS2039 - LIGHTS = 3, SKIN (DIFFUSE)
//
// Specular
// SLS2040 - Base (ONLY_SPECULAR)
// SLS2041 - SKIN (ONLY_SPECULAR)
// SLS2042 - PROJ_SHADOW (ONLY_SPECULAR)
// SLS2043 - PROJ_SHADOW, SKIN (ONLY_SPECULAR)
// SLS2044 - POINT (ONLY_SPECULAR)
// SLS2045 - POINT, SKIN (ONLY_SPECULAR)
// SLS2046 - POINT, NUM_PT_LIGHTS = 2 (ONLY_SPECULAR)
// SLS2047 - POINT, NUM_PT_LIGHTS = 2, SKIN (ONLY_SPECULAR)
// SLS2048 - POINT, NUM_PT_LIGHTS = 3 (ONLY_SPECULAR)
// SLS2049 - POINT, NUM_PT_LIGHTS = 3, SKIN (ONLY_SPECULAR)
//
// PS
//
// AD
// SLS2037 - LIGHTS = 2 (ONLY_LIGHT, OPT)
// SLS2038 - LIGHTS = 2, SI (ONLY_LIGHT, OPT)
// SLS2039 - LIGHTS = 2, PROJ_SHADOW (ONLY_LIGHT, OPT)
// SLS2040 - LIGHTS = 2, SI, PROJ_SHADOW (ONLY_LIGHT, OPT)
// SLS2041 - LIGHTS = 3 (ONLY_LIGHT, OPT)
// SLS2042 - LIGHTS = 3, SI (ONLY_LIGHT, OPT)
// SLS2043 - LIGHTS = 3, PROJ_SHADOW (ONLY_LIGHT, OPT)
// SLS2044 - LIGHTS = 3, SI, PROJ_SHADOW (ONLY_LIGHT, OPT)
//
// ADTS
// SLS2000 - Default
// SLS2001 - OPT
// SLS2002 - OPT, LOD
// SLS2004 - SI 
// SLS2005 - PROJ_SHADOW
// SLS2007 - SI, PROJ_SHADOW 
// SLS2008 - STBB
// SLS2009 - HAIR
// SLS2010 - HAIR, PROJ_SHADOW
// SLS2011 - LIGHTS = 2
// SLS2012 - LIGHTS = 2, SI
// SLS2013 - LIGHTS = 2, HAIR
// SLS2014 - LIGHTS = 2, PROJ_SHADOW
// SLS2015 - LIGHTS = 2, SI, PROJ_SHADOW
// SLS2016 - LIGHTS = 2, HAIR, PROJ_SHADOW
// SLS2017 - SPECULAR
// SLS2018 - SPECULAR, SI
// SLS2019 - SPECULAR, HAIR
// SLS2020 - SPECULAR, PROJ_SHADOW
// SLS2021 - SPECULAR, SI, PROJ_SHADOW
// SLS2022 - SPECULAR, HAIR, PROJ_SHADOW
// SLS2023 - SPECULAR, LIGHTS = 2
// SLS2024 - SPECULAR, LIGHTS = 2, SI
// SLS2026 - SPECULAR, LIGHTS = 2, PROJ_SHADOW
// SLS2027 - SPECULAR, LIGHTS = 2, SI, PROJ_SHADOW
// (ignored) SLS2151 - LIGHTS = 0, SILHOUETTE
//
// ADTS10
// SLS2029 - LIGHTS = 9
// SLS2030 - LIGHTS = 9, SI
// SLS2031 - LIGHTS = 4
// SLS2032 - LIGHTS = 4, OPT 
// SLS2033 - LIGHTS = 4, SI
// SLS2034 - LIGHTS = 4, SPECULAR
// SLS2035 - LIGHTS = 4, SPECULAR, OPT
// SLS2036 - LIGHTS = 4, SPECULAR, SI
//
// DiffusePt
// SLS2045 - LIGHTS = 2 (DIFFUSE)
// SLS2046 - LIGHTS = 3 (DIFFUSE)
//
// Specular
// SLS2047 - Base (ONLY_SPECULAR)
// SLS2048 - HAIR (ONLY_SPECULAR)
// SLS2049 - PROJ_SHADOW (ONLY_SPECULAR)
// SLS2050 - PROJ_SHADOW, HAIR (ONLY_SPECULAR)
// SLS2051 - POINT (ONLY_SPECULAR)
// SLS2052 - POINT, HAIR (ONLY_SPECULAR)
// SLS2053 - NUM_PT_LIGHTS = 2, POINT (ONLY_SPECULAR)
// SLS2054 - NUM_PT_LIGHTS = 2, POINT, HAIR (ONLY_SPECULAR)
// SLS2055 - NUM_PT_LIGHTS = 3, POINT (ONLY_SPECULAR)
// SLS2056 - NUM_PT_LIGHTS = 3, POINT, HAIR (ONLY_SPECULAR)

#if defined(__INTELLISENSE__)
    #define VS
    #define DIFFUSE
    #define LIGHTS 2
#endif

#if defined(DIFFUSE)
    #define ONLY_LIGHT
    #define OPT
#endif

#if defined(ONLY_SPECULAR)
    #define ONLY_LIGHT
    #define SPECULAR
#endif

#ifdef ONLY_LIGHT
    #define NO_FOG
    #define NO_VERTEX_COLOR
#endif

#include "includes/Helpers.hlsl"
#include "includes/Object.hlsl"
#include "includes/Shadow.hlsl"

// Forward sun shadows. Enabled at COMPILE TIME via FORWARD_SHADOWS in Includes/Shadow.hlsl,
// deliberately not via a runtime constant -- see the note there.

#ifdef SKIN
    #include "includes/SkinHelpers.hlsl"
#endif

// Toggles.
#define useVertexColor Toggles.x
#define useFog Toggles.y
#define glossPower Toggles.z
#define alphaTestRef Toggles.w

struct VS_INPUT {
    float4 position : POSITION;
    float3 tangent : TANGENT;
    float3 binormal : BINORMAL;
    float3 normal : NORMAL;
    float4 uv : TEXCOORD0;
#ifndef NO_VERTEX_COLOR
    float4 vertexColor : COLOR0;
#endif
#ifdef SKIN
    float3 blendWeight : BLENDWEIGHT;
    float4 blendIndices : BLENDINDICES;
#endif
};

#if defined(VS) && LIGHTS < 4

struct VS_OUTPUT {
#ifndef NO_VERTEX_COLOR
    float4 vertexColor : COLOR0;
#endif
#ifndef NO_FOG
    float4 fogColor : COLOR1;
#endif
    float4 sPosition : POSITION;
    float2 uv : TEXCOORD0;
    float4 lightDir : TEXCOORD1;

#if LIGHTS > 1 || NUM_PT_LIGHTS > 1
    float4 light2Dir : TEXCOORD2;
#endif
    
#if LIGHTS > 2 || NUM_PT_LIGHTS > 2
    float4 light3Dir : TEXCOORD3;
#endif
    
    float3 viewDir : TEXCOORD6;

    // Object-space squared distances for point-light attenuation (vanillaAttSq), bypassing
    // lightDir/light2Dir/light3Dir above -- those are tangent-space (TBN-transformed) and their
    // length is only correct if the TBN basis is orthonormal. .x = light0 (DIFFUSE/POINT only,
    // where light0 is itself a point light rather than the sun), .y = light2, .z = light3.
    float3 lightDistSq : TEXCOORD5;

    // TEXCOORD4 is free at LIGHTS < 4. .w carries SHADOW_VS_SENTINEL.
    float4 shadowWorldPos : TEXCOORD4;

#ifdef PROJ_SHADOW
    float4 shadowUVs : TEXCOORD7;
#endif
};

#ifndef NO_FOG
    float3 FogColor : register(c15);
    float4 FogParam : register(c14);
#endif

float4 LightData[10] : register(c25);

#ifndef SKIN
    row_major float4x4 ModelViewProj : register(c0);
#else
    row_major float4x4 SkinModelViewProj : register(c1);
    float4 Bones[54] : register(c44);
#endif

float4 EyePosition : register(c16);

#ifdef PROJ_SHADOW
    row_major float4x4 ShadowProj : register(c18);
    float4 ShadowProjData : register(c22);
    float4 ShadowProjTransform : register(c23);
#endif


VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    // Zeroed unconditionally: the DIFFUSE/POINT (.x) and LIGHTS>1/LIGHTS>2 (.y/.z) blocks below
    // only overwrite the components they actually use, and vs_3_0 requires every component of
    // OUT to be written before return -- a component that stays at this default is simply never
    // read by the PS either (same macro guards on both sides).
    OUT.lightDistSq = 0;

    OUT.uv = IN.uv.xy;
    
    float4 position = IN.position.xyzw;
    
    #ifndef SKIN
        float3x3 tbn = float3x3(IN.tangent.xyz, IN.binormal.xyz, IN.normal.xyz);
    
        OUT.sPosition.xyzw = mul(ModelViewProj, position.xyzw);
    #else
        float4 offset = IN.blendIndices.zyxw * 765.01001;
        float4 blend = IN.blendWeight.xyzz;
        blend.w = 1 - weight(IN.blendWeight.xyz);
        float3x3 tbn = BonesTransformTBN(Bones, offset, blend, IN.tangent, IN.binormal, IN.normal);
    
        position.w = 1;
        position.xyz = BonesTransformPosition(Bones, offset, blend, position);
    
        OUT.sPosition.xyzw = mul(SkinModelViewProj, position.xyzw);
    #endif
    
    #if defined(DIFFUSE) || defined(POINT)
        float3 light = LightData[0].xyz - position.xyz;
        OUT.lightDistSq.x = dot(light, light);
    #else
        float3 light = LightData[0].xyz;
    #endif

    OUT.lightDir.w = LightData[0].w;
    OUT.lightDir.xyz = mul(tbn, light);

    OUT.viewDir.xyz = mul(tbn, EyePosition.xyz - position.xyz);

    #if LIGHTS > 1 || NUM_PT_LIGHTS > 1
        light = LightData[1].xyz - position.xyz;
        OUT.light2Dir.w = LightData[1].w;
        OUT.light2Dir.xyz = mul(tbn, light);
        OUT.lightDistSq.y = dot(light, light);
    #endif

    #if LIGHTS > 2 || NUM_PT_LIGHTS > 2
        light = LightData[2].xyz - position.xyz;
        OUT.light3Dir.w = LightData[2].w;
        OUT.light3Dir.xyz = mul(tbn, light);
        OUT.lightDistSq.z = dot(light, light);
    #endif
    
    #ifndef NO_VERTEX_COLOR
        OUT.vertexColor = clamp(IN.vertexColor, 0.0f, 1.0f);
    #endif

    #ifndef NO_FOG
        float3 fogPos = OUT.sPosition.xyz;
    
        #ifdef REVERSED_DEPTH
            fogPos.z = OUT.sPosition.w - fogPos.z;
        #endif
    
        float fogStrength = 1 - saturate((FogParam.x - length(fogPos)) / FogParam.y);
        fogStrength = log2(fogStrength);
        OUT.fogColor.a = exp2(fogStrength * FogParam.z);
        OUT.fogColor.rgb = FogColor.rgb;
    #endif
    
    #ifdef PROJ_SHADOW
        float shadowParam = dot(ShadowProj[3].xyzw, position.xyzw);
        float2 shadowUV;
        shadowUV.x = dot(ShadowProj[0].xyzw, position.xyzw);
        shadowUV.y = dot(ShadowProj[1].xyzw, position.xyzw);
        OUT.shadowUVs.xy = ((shadowParam * ShadowProjTransform.xy) + shadowUV) / (shadowParam * ShadowProjTransform.w);
        OUT.shadowUVs.zw = ((shadowUV.xy - ShadowProjData.xy) / ShadowProjData.w) * float2(1, -1) + float2(0, 1);
    #endif

    // Model-space shaders: recover a camera-relative world position from the clip position.
    // Written unconditionally, or the interpolator is left undefined.
    OUT.shadowWorldPos = float4(GetShadowWorldPos(OUT.sPosition), SHADOW_VS_SENTINEL);

    return OUT;
};

#elif defined(VS) && LIGHTS >= 4

#if LIGHTS > 4
    #define MAX_LIGHTS 6
#elif LIGHTS > 3 && !defined(SPECULAR)
    #define MAX_LIGHTS 4
#else
    #define MAX_LIGHTS 3
#endif

// Camera-relative world position carrier. At MAX_LIGHTS 6 every TEXCOORD is taken, so it
// rides in light4/5/6's .w -- a light radius the PS never reads, since attenuation uses
// PSLightPosition[i].w. Below that, a free interpolator.
#if MAX_LIGHTS > 4
    // No fourth channel spare here, so the sentinel rides in lPosition.w. The vertex shader
    // normally puts LightData[0].w there and this pixel shader never reads it.
    #define SHADOW_WP_STORE(O, v) O.light4.w = (v).x; O.light5.w = (v).y; O.light6.w = (v).z; O.lPosition.w = SHADOW_VS_SENTINEL
    #define SHADOW_WP_LOAD(I)     float3((I).light4.w, (I).light5.w, (I).light6.w)
    #define SHADOW_WP_VALID(I)    SHADOW_VS_PRESENT((I).lPosition.w)
#else
    #define SHADOW_WP_DEDICATED
    #define SHADOW_WP_STORE(O, v) O.shadowWorldPos = float4((v), SHADOW_VS_SENTINEL)
    #define SHADOW_WP_LOAD(I)     (I).shadowWorldPos.xyz
    #define SHADOW_WP_VALID(I)    SHADOW_VS_PRESENT((I).shadowWorldPos.w)
#endif

struct VS_OUTPUT {
    float4 vertexColor : COLOR0;
    float4 fogColor : COLOR1;
    float4 sPosition : POSITION;
    float2 uv : TEXCOORD0;
    float4 lPosition : TEXCOORD1;
    float4 lightDir : TEXCOORD2;  // .w = .x of viewDir
    float4 light2 : TEXCOORD3;   // .w = .y of viewDir
    float4 light3 : TEXCOORD4;  // .w = .z of viewDir
#if MAX_LIGHTS > 3
    float4 light4 : TEXCOORD5;
#endif
#if MAX_LIGHTS > 4
    float4 light5 : TEXCOORD6;
    float4 light6 : TEXCOORD7;
#endif
#ifdef SHADOW_WP_DEDICATED
    #if MAX_LIGHTS > 3
        float4 shadowWorldPos : TEXCOORD6;
    #else
        float4 shadowWorldPos : TEXCOORD5;
    #endif
#endif
};

float3 FogColor : register(c15);
float4 FogParam : register(c14);
float4 LightData[10] : register(c25);
#ifndef SKIN
row_major float4x4 ModelViewProj : register(c0);
#else
    row_major float4x4 SkinModelViewProj : register(c1);
    float4 Bones[54] : register(c44);
#endif
float4 EyePosition : register(c16);
#ifndef OPT
    float4 fvars0 : register(c17);

    #define lightOffset 0
#else
    #define lightOffset 1
#endif

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;
    
    OUT.uv = IN.uv.xy;
    
    float4 position = IN.position.xyzw;
    
    #ifndef SKIN
    float3x3 tbn = float3x3(IN.tangent.xyz, IN.binormal.xyz, IN.normal.xyz);
    
    OUT.sPosition.xyzw = mul(ModelViewProj, position.xyzw);
    #else
        float4 offset = IN.blendIndices.zyxw * 765.01001;
        float4 blend = IN.blendWeight.xyzz;
        blend.w = 1 - weight(IN.blendWeight.xyz);
        float3x3 tbn = BonesTransformTBN(Bones, offset, blend, IN.tangent, IN.binormal, IN.normal);
    
        position.w = 1;
        position.xyz = BonesTransformPosition(Bones, offset, blend, position);
        OUT.sPosition.xyzw = mul(SkinModelViewProj, position.xyzw);
    #endif
    
    float3 viewDir = mul(tbn, EyePosition.xyz - position.xyz);
    
    OUT.lPosition.xyz = position.xyz;
    OUT.lPosition.w = LightData[0].w;
    
    #ifndef OPT
        float lights = min(MAX_LIGHTS, fvars0.z);
    #elif defined(SPECULAR)
        float lights = min(MAX_LIGHTS, EyePosition.w);
    #else
        float lights = min(MAX_LIGHTS, LightData[0].w);
    #endif
    float lightsFrac = frac(lights);
    float lightsThreshold = (lights < 0.0 ? (-lightsFrac < lightsFrac ? 1.0 : 0.0) : 0) + (lights - lightsFrac);
    float lightUsed;
    
    #ifndef OPT
        OUT.lightDir.w = viewDir.x;
        OUT.lightDir.xyz = mul(tbn, LightData[0].xyz);
    #else
        lightUsed = 0 < lightsThreshold ? 1.0 : 0.0;
        OUT.lightDir.xyz = lightUsed * mul(tbn, LightData[lightOffset + 0].xyz - position.xyz);
        OUT.lightDir.w = viewDir.x;
    #endif
    
    lightUsed = 1 < lightsThreshold ? 1.0 : 0.0;
    OUT.light2.xyz = lightUsed * mul(tbn, LightData[lightOffset + 1].xyz - position.xyz);
    OUT.light2.w = viewDir.y;
    
    lightUsed = 2 < lightsThreshold ? 1.0 : 0.0;
    OUT.light3.xyz = lightUsed * mul(tbn, LightData[lightOffset + 2].xyz - position.xyz);
    OUT.light3.w = viewDir.z;
    
    #if MAX_LIGHTS > 3
        lightUsed = 3 < lightsThreshold ? 1.0 : 0.0;
        OUT.light4.xyz = lightUsed * mul(tbn, LightData[lightOffset + 3].xyz - position.xyz);
        OUT.light4.w = lightUsed * LightData[lightOffset + 3].w;
    #endif
    
    #if MAX_LIGHTS > 4
        lightUsed = 4 < lightsThreshold ? 1.0 : 0.0;
        OUT.light5.xyz = lightUsed * mul(tbn, LightData[lightOffset + 4].xyz - position.xyz);
        OUT.light5.w = lightUsed * LightData[lightOffset + 4].w;
        
        lightUsed = 5 < lightsThreshold ? 1.0 : 0.0;
        OUT.light6.xyz = lightUsed * mul(tbn, LightData[lightOffset + 5].xyz - position.xyz);
        OUT.light6.w = lightUsed * LightData[lightOffset + 5].w;
    #endif
    
    OUT.vertexColor = clamp(IN.vertexColor, 0.0f, 1.0f);

    float3 fogPos = OUT.sPosition.xyz;
    #ifdef REVERSED_DEPTH
        fogPos.z = OUT.sPosition.w - fogPos.z;
    #endif
    float fogStrength = 1 - saturate((FogParam.x - length(fogPos)) / FogParam.y);
    fogStrength = log2(fogStrength);
    OUT.fogColor.a = exp2(fogStrength * FogParam.z);
    OUT.fogColor.rgb = FogColor.rgb;

    // Through SHADOW_WP_STORE: at MAX_LIGHTS 6 this overwrites light4/5/6's .w, which the PS
    // ignores.
    float3 shadowWorldPos = GetShadowWorldPos(OUT.sPosition);
    SHADOW_WP_STORE(OUT, shadowWorldPos);

    return OUT;
};
#endif // Vertex shaders.

#if defined(PS) && (!defined(LIGHTS) || LIGHTS < 4)

struct PS_INPUT {
#ifndef NO_VERTEX_COLOR
    float3 vertexColor : COLOR0;
#endif
#ifndef NO_FOG
    float4 fogColor : COLOR1;
#endif
    float2 uv : TEXCOORD0;
    float4 lightDir : TEXCOORD1_centroid;
#if LIGHTS > 1 || NUM_PT_LIGHTS > 1
    float4 light2Dir : TEXCOORD2_centroid;
#endif
#if LIGHTS > 2 || NUM_PT_LIGHTS > 2
    float4 light3Dir : TEXCOORD3_centroid;
#endif
    float3 viewDir : TEXCOORD6_centroid;
    float3 lightDistSq : TEXCOORD5;
    float4 shadowWorldPos : TEXCOORD4;
#ifdef PROJ_SHADOW
    float4 shadowUVs : TEXCOORD7;
#endif
};

struct PS_OUTPUT {
    float4 color : COLOR0;
};

#if defined(DIFFUSE) || defined(ONLY_SPECULAR)
    sampler2D NormalMap : register(s0);
#else
    sampler2D BaseMap : register(s0);
    sampler2D NormalMap : register(s1);
#endif

#if !defined(DIFFUSE) && !defined(ONLY_SPECULAR)
    float4 AmbientColor : register(c1);
#endif

float4 PSLightColor[10] : register(c3);

#if (defined(SI) || defined(HAIR)) && !defined(ONLY_SPECULAR)
    #ifdef ONLY_LIGHT
        sampler2D GlowMap : register(s3);
    #else
        sampler2D GlowMap : register(s4);
    #endif
    float4 EmittanceColor : register(c2);
#endif

#ifdef PROJ_SHADOW
    #if defined(ONLY_SPECULAR)
        sampler2D ShadowMap : register(s4);
        sampler2D ShadowMaskMap : register(s5);
    #elif defined(ONLY_LIGHT)
        sampler2D ShadowMap : register(s5);
        sampler2D ShadowMaskMap : register(s6);
    #else
        sampler2D ShadowMap : register(s6);
        sampler2D ShadowMaskMap : register(s7);
    #endif
#endif

#ifndef OPT
    float4 Toggles : register(c27);
#endif


PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;
    
    #if !defined(DIFFUSE) && !defined(ONLY_SPECULAR)
        float4 baseColor = tex2D(BaseMap, IN.uv.xy);
    
        #if defined(ONLY_LIGHT)
            baseColor.rgb = 1;
        #endif
    #else
        float4 baseColor = 1;
    #endif
    
    #if !defined(OPT) && !defined(ONLY_SPECULAR)
        clip(AmbientColor.a >= 1 ? 0 : (baseColor.a - alphaTestRef));
    #endif
    
    float4 normal = tex2D(NormalMap, IN.uv.xy);
    normal.xyz = normalize(expand(normal.xyz));
    
    float roughness = getRoughness(normal.a);

    // Geometric specular AA -- see the comment on SpecularAA itself. Unconditional: this is a
    // quality fix for high-frequency normal maps (hair chief among them), not a debug toggle,
    // and ddx/ddy have to run here at top level regardless of anything below.
    roughness = SpecularAA(normal.xyz, roughness);

    //if (TESR_DebugVar.y > 0.0) {
    //    OUT.color.a = 1;
    //    if (TESR_DebugVar.y > 0.1)
    //        OUT.color.rgb = roughness.xxx;
    //    else
    //        OUT.color.rgb = normal.aaa;
    //    return OUT;
    //}
    
    #ifndef NO_VERTEX_COLOR
        #if defined(HAIR)
            float4 glow = tex2D(GlowMap, IN.uv.xy);
            baseColor.rgb = (2 * ((IN.vertexColor.g * (EmittanceColor.rgb - 0.5)) + 0.5)) * lerp(baseColor.rgb, glow.rgb, glow.a);
        #elif !defined(OPT)
            baseColor.rgb = useVertexColor <= 0 ? baseColor.rgb : (baseColor.rgb * IN.vertexColor.rgb);
        #else
            baseColor.rgb = baseColor.rgb * IN.vertexColor.rgb;
        #endif
    #endif
    
    // Vanilla shadows.
    float3 shadowMultiplier = 1.0;
    #if defined(STBB)
        shadowMultiplier = 0.85;
    #elif defined(PROJ_SHADOW)
        float3 shadow = tex2D(ShadowMap, IN.shadowUVs.xy).xyz;
        float shadowMask = tex2D(ShadowMaskMap, IN.shadowUVs.zw).x;
        shadowMultiplier = lerp(1, shadow, shadowMask);
    #endif
    
    // Applied to PSLightColor[0], the sun, only: ambient, emittance and point lights are
    // untouched. ddx/ddy must stay at top level, outside any dynamic branch.
    //
    // Computed once here and reused by the ambient block further down (that block's condition,
    // !DIFFUSE && !ONLY_SPECULAR, is a strict subset of this one, since POINT implies
    // ONLY_SPECULAR) -- two separate ddx/ddy evaluations of the identical
    // GetShadowGeometricNormal(IN.shadowWorldPos.xyz) call previously coexisted in the same
    // pixel shader whenever FORWARD_SHADOWS was compiled in, which is fragile enough on its own
    // to corrupt unrelated interpolator reads placed nearby.
    #if !defined(DIFFUSE) && !defined(POINT)
        float3 shadowGeometricNormal = GetShadowGeometricNormal(IN.shadowWorldPos.xyz);
        // Decline to shadow if a vanilla vertex shader ran: the interpolator is undefined.
        float sunShadow = 1.0f;
        #if FORWARD_SHADOWS
        sunShadow = SHADOW_VS_PRESENT(IN.shadowWorldPos.w)
                  ? GetSunShadow(IN.shadowWorldPos.xyz, shadowGeometricNormal)
                  : 1.0f;
        #endif
        shadowMultiplier *= sunShadow;
    #endif

    #if !defined(DIFFUSE) && !defined(POINT)
        float3 lighting = getSunLighting(IN.lightDir.xyz, PSLightColor[0].rgb * shadowMultiplier, IN.viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #else
        // Pointlights only. Attenuate from the object-space lightDistSq.x carried from the VS,
        // not length(IN.lightDir.xyz) -- that vector is tangent-space (TBN-transformed) and its
        // length is only correct if the TBN basis is orthonormal.
        float att0 = vanillaAttSq(IN.lightDistSq.x, IN.lightDir.w);
        float3 lighting = getPointLightLightingAtt(IN.lightDir.xyz, att0, PSLightColor[0].rgb * shadowMultiplier, IN.viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif
    
    // Self emmitance.
    #ifdef SI
        float3 glow = tex2D(GlowMap, IN.uv.xy).rgb;
        lighting += baseColor.rgb * glow.rgb * EmittanceColor.rgb;
    #endif
    
    #if !defined(DIFFUSE) && !defined(ONLY_SPECULAR)
        // Reuses shadowGeometricNormal computed above -- see the comment there. Always in scope
        // here: POINT implies ONLY_SPECULAR, so !ONLY_SPECULAR implies !POINT.
        lighting += getAmbientLighting(AmbientColor.rgb, baseColor.rgb, shadowGeometricNormal,
                                       SHADOW_VS_PRESENT(IN.shadowWorldPos.w) ? 1.0f : 0.0f);
    #endif

    // Other light sources. Same object-space attenuation fix as light0 above.
    #if LIGHTS > 1 || NUM_PT_LIGHTS > 1
        float att2 = vanillaAttSq(IN.lightDistSq.y, IN.light2Dir.w);
        lighting += getPointLightLightingAtt(IN.light2Dir.xyz, att2, PSLightColor[1].rgb, IN.viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif

    #if LIGHTS > 2 || NUM_PT_LIGHTS > 2
        float att3 = vanillaAttSq(IN.lightDistSq.z, IN.light3Dir.w);
        lighting += getPointLightLightingAtt(IN.light3Dir.xyz, att3, PSLightColor[2].rgb, IN.viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif
    
    float3 finalColor = lighting.rgb;
    
    // Fog.
    #ifndef NO_FOG
        #ifndef OPT
            finalColor.rgb = (useFog <= 0.0 ? finalColor.rgb : lerp(finalColor.rgb, IN.fogColor.rgb, IN.fogColor.a));
        #else
            finalColor.rgb = lerp(finalColor.rgb, IN.fogColor.rgb, IN.fogColor.a);
        #endif
    #endif
    

#if SHADOW_FORCE_MARKER
    finalColor.rgb = float3(1.0f, 0.0f, 1.0f);   // unconditional: proves this shader ran
#endif

    OUT.color.rgb = finalColor.rgb;
    
    #if defined(DIFFUSE)
        OUT.color.a = 1;
    #elif defined(ONLY_SPECULAR)
        #if !defined(DIFFUSE) && !defined(POINT)
            // Alpha here is a blend WEIGHT (this pass's own brightness, used to fade
            // its additive specular/sheen layer smoothly), not a darkness value --
            // unlike the colour output, it must not shrink with sun shadow, or the
            // whole layer fades toward invisible in shadow instead of just going
            // dark. That read as "alpha blending broken" under Forward Shadows
            // specifically, because sunShadow is the one new factor it added to
            // shadowMultiplier here (STBB/PROJ_SHADOW's own contribution predates
            // this and is left alone). Dividing it back out recovers the weight
            // this pass would have produced without Forward Shadows; harmless and
            // exact when Forward Shadows is compiled out, since sunShadow is then
            // fixed at 1.0.
            OUT.color.a = weight(finalColor.rgb) / max(sunShadow, 0.05f);
        #else
            OUT.color.a = weight(finalColor.rgb);
        #endif
    #elif defined(ONLY_LIGHT)
        OUT.color.a = baseColor.a;
    #else
        OUT.color.a = baseColor.a * AmbientColor.a;
    #endif

    return OUT;
}

#elif defined(PS) && LIGHTS >= 4

#if LIGHTS > 4
    #define MAX_LIGHTS 6
#elif LIGHTS > 3 && !defined(SPECULAR)
    #define MAX_LIGHTS 4
#else
    #define MAX_LIGHTS 3
#endif

// Camera-relative world position carrier. At MAX_LIGHTS 6 every TEXCOORD is taken, so it
// rides in light4/5/6's .w -- a light radius the PS never reads, since attenuation uses
// PSLightPosition[i].w. Below that, a free interpolator.
#if MAX_LIGHTS > 4
    // No fourth channel spare here, so the sentinel rides in lPosition.w. The vertex shader
    // normally puts LightData[0].w there and this pixel shader never reads it.
    #define SHADOW_WP_STORE(O, v) O.light4.w = (v).x; O.light5.w = (v).y; O.light6.w = (v).z; O.lPosition.w = SHADOW_VS_SENTINEL
    #define SHADOW_WP_LOAD(I)     float3((I).light4.w, (I).light5.w, (I).light6.w)
    #define SHADOW_WP_VALID(I)    SHADOW_VS_PRESENT((I).lPosition.w)
#else
    #define SHADOW_WP_DEDICATED
    #define SHADOW_WP_STORE(O, v) O.shadowWorldPos = float4((v), SHADOW_VS_SENTINEL)
    #define SHADOW_WP_LOAD(I)     (I).shadowWorldPos.xyz
    #define SHADOW_WP_VALID(I)    SHADOW_VS_PRESENT((I).shadowWorldPos.w)
#endif

struct PS_INPUT {
    float4 vertexColor : COLOR0;
    float4 fogColor : COLOR1;
    float4 sPosition : POSITION;
    float2 uv : TEXCOORD0;
    float4 lPosition : TEXCOORD1;
    float4 lightDir : TEXCOORD2_centroid;  // .w = .x of viewDir
    float4 light2 : TEXCOORD3_centroid; // .w = .y of viewDir
    float4 light3 : TEXCOORD4_centroid; // .w = .z of viewDir
#if MAX_LIGHTS > 3
    float4 light4 : TEXCOORD5_centroid;
#endif
#if MAX_LIGHTS > 4
    float4 light5 : TEXCOORD6_centroid;
    float4 light6 : TEXCOORD7_centroid;
#endif
#ifdef SHADOW_WP_DEDICATED
    #if MAX_LIGHTS > 3
        float4 shadowWorldPos : TEXCOORD6;
    #else
        float4 shadowWorldPos : TEXCOORD5;
    #endif
#endif
};

struct PS_OUTPUT {
    float4 color : COLOR0;
};

sampler2D BaseMap : register(s0);
sampler2D NormalMap : register(s1);

float4 AmbientColor : register(c1);

float4 PSLightColor[10] : register(c3);
float4 PSLightPosition[8] : register(c19);


#ifndef OPT
    float4 EmittanceColor : register(c2);

    float4 Toggles : register(c27);

    #define lightsUsed EmittanceColor.a
    #define lightOffset 0
    #define glossPow Toggles.z
#else
    #define lightsUsed PSLightColor[0].a
    #define lightOffset 1
    #define glossPow PSLightColor[1].w
#endif

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

    float4 baseColor = tex2D(BaseMap, IN.uv.xy);
    
    #ifndef OPT
        clip(AmbientColor.a >= 1 ? 0 : (baseColor.a - alphaTestRef));
    #endif
    
    #ifndef OPT
        baseColor.rgb = useVertexColor <= 0 ? baseColor.rgb : (baseColor.rgb * IN.vertexColor.rgb);
    #else
        baseColor.rgb = baseColor.rgb * IN.vertexColor.rgb;
    #endif
    
    float4 normal = tex2D(NormalMap, IN.uv.xy);
    normal.xyz = normalize(expand(normal.xyz));
    
    float roughness = getRoughness(normal.a);
    
    // Lighting.
    float3 viewDir = { IN.lightDir.w, IN.light2.w, IN.light3.w };
    
    float att;
    
    // Forward sun shadows -- see the LIGHTS < 4 variant. Only the OPT-off path has a sun
    // term; with OPT the first slot is a point light and must not be shadowed by the sun.
    #ifndef OPT
        float3 sunShadowWorldPos = SHADOW_WP_LOAD(IN);
        float3 sunShadowNormal = GetShadowGeometricNormal(sunShadowWorldPos);
        // Decline to shadow if a vanilla vertex shader ran: the interpolator is undefined.
        float sunShadow = 1.0f;
        #if FORWARD_SHADOWS
        sunShadow = SHADOW_WP_VALID(IN)
                  ? GetSunShadow(sunShadowWorldPos, sunShadowNormal)
                  : 1.0f;
        #endif
        float3 lighting = getSunLighting(IN.lightDir.xyz, PSLightColor[0].rgb * sunShadow, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #else
        att = vanillaAtt(PSLightPosition[0].xyz - IN.lPosition.xyz, PSLightPosition[0].w);
        float3 lighting = getPointLightLightingAtt(IN.lightDir.xyz, att, PSLightColor[0].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif
    
    att = vanillaAtt(PSLightPosition[lightOffset + 0].xyz - IN.lPosition.xyz, PSLightPosition[lightOffset + 0].w);
    lighting += (1 >= lightsUsed ? 0.0 : 1.0) * getPointLightLightingAtt(IN.light2.xyz, att, PSLightColor[1].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    
    att = vanillaAtt(PSLightPosition[lightOffset + 1].xyz - IN.lPosition.xyz, PSLightPosition[lightOffset + 1].w);
    lighting += (2 > lightsUsed ? 0.0 : 1.0) * getPointLightLightingAtt(IN.light3.xyz, att, PSLightColor[2].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    
    #if MAX_LIGHTS > 3
        att = vanillaAtt(PSLightPosition[lightOffset + 2].xyz - IN.lPosition.xyz, PSLightPosition[lightOffset + 2].w);
        lighting += (3 > lightsUsed ? 0.0 : 1.0) * getPointLightLightingAtt(IN.light4.xyz, att, PSLightColor[3].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif
    
    #if MAX_LIGHTS > 4
        att = vanillaAtt(PSLightPosition[3].xyz - IN.lPosition.xyz, PSLightPosition[3].w);
        lighting += (4 > lightsUsed ? 0.0 : 1.0) * getPointLightLightingAtt(IN.light5.xyz, att, PSLightColor[4].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    
        att = vanillaAtt(PSLightPosition[4].xyz - IN.lPosition.xyz, PSLightPosition[4].w);
        lighting += (5 > lightsUsed ? 0.0 : 1.0) * getPointLightLightingAtt(IN.light6.xyz, att, PSLightColor[5].rgb, viewDir.xyz, normal.xyz, baseColor.rgb, roughness);
    #endif
    
    // ddx/ddy must stay at pixel-shader top level.
    float3 ambNormal = GetShadowGeometricNormal(SHADOW_WP_LOAD(IN));
    lighting += getAmbientLighting(AmbientColor.rgb, baseColor.rgb, ambNormal,
                                   SHADOW_WP_VALID(IN) ? 1.0f : 0.0f);

    // TODO: Vanilla attenuates the full specular term by IN.lPosition.w for some reason. Is this a problem?
    float3 finalColor = lighting;
    
    #ifndef OPT
        finalColor.rgb = (useFog <= 0.0 ? finalColor.rgb : lerp(finalColor.rgb, IN.fogColor.rgb, IN.fogColor.a));
    #else
        finalColor.rgb = lerp(finalColor.rgb, IN.fogColor.rgb, IN.fogColor.a);
    #endif
    

#if SHADOW_FORCE_MARKER
    finalColor.rgb = float3(1.0f, 0.0f, 1.0f);   // unconditional: proves this shader ran
#endif

    OUT.color.rgb = finalColor.rgb;
    OUT.color.a = baseColor.a * AmbientColor.a;

    return OUT;
}

#endif // Pixel shaders.
