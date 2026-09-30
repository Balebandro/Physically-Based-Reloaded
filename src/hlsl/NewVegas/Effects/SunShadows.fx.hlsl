// Image space shadows shader for Oblivion Reloaded

float4x4 TESR_WorldViewProjectionTransform;
float4x4 TESR_ShadowCameraToLightTransformNear;
float4x4 TESR_ShadowCameraToLightTransformMiddle;
float4x4 TESR_ShadowCameraToLightTransformFar;
float4x4 TESR_ShadowCameraToLightTransformLod;
float4 TESR_ReciprocalResolution;
float4 TESR_SmoothedSunDir;
float4 TESR_ViewSpaceLightDir;
float4 TESR_ShadowData; // x: quality, y: darkness, z: texel size
float4 TESR_ShadowFormatData; // x: mode, y: format bits per pixels
float4 TESR_ShadowScreenSpaceData; // x: Enabled, y: blurRadius, z: renderDistance, w: intensity
float4 TESR_ShadowContactData; // x: strength, y: ray length, z: thickness, w: max distance
float4 TESR_SunAmbient;
float4 TESR_ShadowFade; // x: sunset attenuation, y: shadows maps active, z: point lights shadows active
// Injected as a D3DXMACRO by EffectRecord from [Shaders.ShadowsExteriors.Main] ForwardShadows,
// exactly as it is for the game shaders -- so the two halves cannot disagree.
// 1 = the object/terrain/parallax shaders evaluate the sun cascades themselves, so this
//     effect must not also apply them. 0 = stock deferred behaviour.
#ifndef FORWARD_SHADOWS
    #define FORWARD_SHADOWS 0
#endif
float4 TESR_ShadowBlur; // x: 1 / atlas resolution, y: whether the lod cascade was updated
float4 TESR_ShadowForwardData; // x: 1 when the forward path is SUPPRESSED
float4 TESR_ShadowNearCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowMiddleCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowFarCenter; // x,y,z: center (world space), w: radius
float4 TESR_ShadowLodCenter; // x,y,z: center (world space), w: radius

sampler2D TESR_DepthBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_ShadowAtlas : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_PointShadowBuffer : register(s3)  = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NoiseSampler : register(s4) < string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

#define SSS_STEPNUM 5
#define CONTACT_STEPNUM 12
#define CONTACT_GROWTH (1.0f / 600.0f)   // the ray doubles in length every 600 units of depth

static const float DARKNESS = 1-TESR_ShadowData.y;
static const float SSS_DIST = 2000;
static const float SSS_THICKNESS = 20;
static const float SSS_MAXDEPTH = TESR_ShadowScreenSpaceData.z * TESR_ShadowScreenSpaceData.x;

static const float Mode = TESR_ShadowFormatData.x;
static const float FormatBits = TESR_ShadowFormatData.y;

// Normal-offset bias in shadow map TEXELS, not world units -- a fixed world-space offset is
// several texels in the Near cascade and a fraction of one in the Lod cascade. See the note in
// Shaders/Includes/Shadow.hlsl. Keep these three in step with the SHADOW_NORMAL_BIAS_TEXELS /
// SHADOW_SLOPE_BIAS / SHADOW_FILTER_TAPS defaults there, or the two paths disagree.
static const float NormalBiasTexels = 2.5f;
static const float SlopeBias = 1.0f;
#define SHADOW_FILTER_TAPS 1
#define SHADOW_FILTER_SPREAD 1.0f

struct VSOUT
{
	float4 vertPos : POSITION;
	float4 normal : TEXCOORD1;
	float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Shadows.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/BlurDepth.hlsl"


VSOUT FrameVS(VSIN IN)
{
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

float4 ScreenCoordToTexCoord(float4 coord){
	// apply perspective (perspective division) and convert from -1/1 to range to 0/1 (shadowMap range);
	coord.xyz /= coord.w;
	coord.x = coord.x * 0.5f + 0.5f;
	coord.y = coord.y * -0.5f + 0.5f;

	return coord;
}

// Moments for one cascade, optionally averaged over several taps.
//
// Averaging the MOMENTS and evaluating Chebyshev once is the correct order -- moments are
// linearly filterable, which is the entire reason variance shadow maps exist. Averaging
// four separate Chebyshev results would be both wrong and slower.
// tex2Dlod, not tex2D: with forward compiled in, the deferred lookup sits inside a dynamic
// branch, and a gradient-taking sample there is illegal (X3528). The atlas has no mipmaps, so
// an explicit LOD 0 is exactly equivalent -- the forward path samples it the same way.
float4 SampleShadowMoments(float2 uv, float2 quadrantOffset) {
#if SHADOW_FILTER_TAPS <= 1
    return tex2Dlod(TESR_ShadowAtlas, float4(uv, 0.0f, 0.0f));
#else
	// Taps must stay inside their own quadrant: the atlas packs four unrelated cascades into
	// one texture, so a tap crossing a quadrant border reads another cascade's depths as if
	// they belonged to this one. ShadowMapBlur.pso clamps for the same reason.
    float texel = TESR_ShadowBlur.x;
    float2 lo = quadrantOffset + texel * 0.5f;
    float2 hi = quadrantOffset + 0.5f - texel * 0.5f;

    float2 d = texel * SHADOW_FILTER_SPREAD;
    float4 m;
    m  = tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + d * float2( 1.0f,  0.5f), lo, hi), 0.0f, 0.0f));
    m += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + d * float2(-0.5f,  1.0f), lo, hi), 0.0f, 0.0f));
    m += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + d * float2(-1.0f, -0.5f), lo, hi), 0.0f, 0.0f));
    m += tex2Dlod(TESR_ShadowAtlas, float4(clamp(uv + d * float2( 0.5f, -1.0f), lo, hi), 0.0f, 0.0f));
    return m * 0.25f;
#endif
}

float GetLightAmountValue(float4x4 lightTransform, float4 coord, float offsetX, float offsetY, float bias, float bleedReduction) {
    float4 LightSpaceCoord = ScreenCoordToTexCoord(mul(coord, lightTransform));

	// Offset to the correct position in the atlas.
    LightSpaceCoord.xy *= 0.5;
    LightSpaceCoord.x += offsetX;
    LightSpaceCoord.y += offsetY;

    float4 shadowBufferValue = SampleShadowMoments(LightSpaceCoord.xy, float2(offsetX, offsetY));

    float shadow;
	
	[branch]
    if (Mode == 0.0f)
        shadow = GetLightAmountValueVSM(shadowBufferValue.xy, LightSpaceCoord.z, bias, bleedReduction);
    else if (Mode == 1.0f)
        shadow = GetLightAmountValueEVSM2(shadowBufferValue.xy, LightSpaceCoord.z, bias, bleedReduction, FormatBits);
	else
        shadow = GetLightAmountValueEVSM4(shadowBufferValue, LightSpaceCoord.z, bias, bleedReduction, FormatBits);
	
    return shadow;
}

float GetLightAmount(float4 positionWS, float3 normal)
{
	// Normal offset.
    float NdotL = dot(normal, TESR_SmoothedSunDir.xyz);
    float offsetScale = saturate(1 - NdotL);

	// World size of one shadow map texel, per cascade. GetCascadeViewProj builds each cascade
	// as [-radius, +radius], so a texel is 2*radius/cascadeResolution; the atlas is two
	// cascades wide, so cascadeResolution = 0.5 / TESR_ShadowBlur.x and the texel works out
	// to 4 * radius * TESR_ShadowBlur.x.
    float4 radii = {
        TESR_ShadowNearCenter.w,
        TESR_ShadowMiddleCenter.w,
        TESR_ShadowFarCenter.w,
        TESR_ShadowLodCenter.w,
    };
    float4 texelWorld = 4.0f * radii * max(TESR_ShadowBlur.x, 1.0f / 16384.0f);
    float4 offsetDistance = offsetScale * NormalBiasTexels * texelWorld;

	// Slope-scaled variance floor: a grazing texel spans a long run of receiver depth and
	// needs more slack before Chebyshev calls it occluded.
    float bias = (Mode == 0.0f ? 0.00001f : 0.01f) * (1.0f + SlopeBias * offsetScale);

    const float blend = 0.9f;

	// Each cascade is offset in its OWN texel scale -- one shared samplePos cannot suit all
	// four when their texels differ by more than an order of magnitude.
	float4 shadows = {
        GetLightAmountValue(TESR_ShadowCameraToLightTransformNear,   float4(positionWS.xyz + offsetDistance.x * normal, 1.0f), 0.0, 0.0, bias, 0.1f),
		GetLightAmountValue(TESR_ShadowCameraToLightTransformMiddle, float4(positionWS.xyz + offsetDistance.y * normal, 1.0f), 0.5, 0.0, bias, 0.2f),
		GetLightAmountValue(TESR_ShadowCameraToLightTransformFar,    float4(positionWS.xyz + offsetDistance.z * normal, 1.0f), 0.0, 0.5, bias, 0.6f),
		GetLightAmountValue(TESR_ShadowCameraToLightTransformLod,    float4(positionWS.xyz + offsetDistance.w * normal, 1.0f), 0.5, 0.5, bias, 0.8f),
    };

    float4 distances = {
        length(positionWS.xyz - TESR_ShadowNearCenter.xyz),
		length(positionWS.xyz - TESR_ShadowMiddleCenter.xyz),
		length(positionWS.xyz - TESR_ShadowFarCenter.xyz),
		length(positionWS.xyz - TESR_ShadowLodCenter.xyz),
    };
	
    if (distances.x < TESR_ShadowNearCenter.w) {
        if (distances.x < TESR_ShadowNearCenter.w * blend)
            return shadows.x;
		
        return lerp(shadows.x, shadows.y, smoothstep(TESR_ShadowNearCenter.w * blend, TESR_ShadowNearCenter.w, distances.x));
    }
    else if (distances.y < TESR_ShadowMiddleCenter.w) {
        if (distances.y < TESR_ShadowMiddleCenter.w * blend)
            return shadows.y;
		
        return lerp(shadows.y, shadows.z, smoothstep(TESR_ShadowMiddleCenter.w * blend, TESR_ShadowMiddleCenter.w, distances.y));
    }
    else if (distances.z < TESR_ShadowFarCenter.w) {
        if (distances.z < TESR_ShadowFarCenter.w * blend)
            return shadows.z;
		
        return lerp(shadows.z, shadows.w, smoothstep(TESR_ShadowFarCenter.w * blend, TESR_ShadowFarCenter.w, distances.z));
    }
    else if (distances.w < TESR_ShadowLodCenter.w) {
        if (distances.w < TESR_ShadowLodCenter.w * blend)
            return shadows.w;
		
        return lerp(shadows.w, 1.0f, smoothstep(TESR_ShadowLodCenter.w * blend, TESR_ShadowLodCenter.w, distances.w));
    }
    else {
        return 1.0f;
    }
}

// returns a semi random float3 between 0 and 1 based on the given seed. (blue noise)
// tailored to return a different value for each uv coord of the screen.
float3 random(float2 seed)
{
	return tex2D(TESR_NoiseSampler, (seed/256 + 0.5) / TESR_ReciprocalResolution.xy).xyz;
}

float4 ScreenSpaceShadow(VSOUT IN) : COLOR0
{	
	// calculates wether a point is in shadow based on screen depth
	float2 uv = IN.UVCoord;
	// clip((uv < 0.5) - 1);
	// uv *= 2;

    float4 color = tex2D(TESR_PointShadowBuffer, IN.UVCoord);
	if (!TESR_ShadowScreenSpaceData.x) return float4(1.0, color.g, 0, 1); // skip is screenspace shadows are disabled

	const float3 origin = reconstructPosition(uv);   // the long march below walks pos along the ray
	float3 pos = origin;

	float bias = 0.01;
	if (pos.z > SSS_MAXDEPTH) return float4(1.0, color.g, 0, 1); // early out for pixels further away than the max render distance
	
    float3 random3 = random(uv);
    float rand = lerp(min(0.8f, pos.z / SSS_MAXDEPTH), 1.0f, random3.r); // some noise to vary the ray length

	// scale the step with distance, and randomize length
	float depth = getHomogenousDepth(uv) / farZ;
	float3 step = pows(depth, 0.6) * (SSS_DIST / SSS_STEPNUM) * TESR_ViewSpaceLightDir.xyz * rand;
	float thickness = pows(depth, 0.6) * SSS_THICKNESS;

	float occlusion = 0.0;
	float total = 0;

	// Doing two steps at once to optimize the depth march
	[unroll]
	for (float i = 1; i < SSS_STEPNUM; i+=2){
		float step1 = i;
		float step2 = i + 1;

		float3 pos1 = pos + step1 * step; // we move to the light with bigger steps each time
		float3 pos2 = pos1 + step2 * step; // we move to the light with bigger steps each time
		
		// if (screen_pos.x > 0 && screen_pos.x < 1.0 && screen_pos.y > 0 && screen_pos.y <1){
		float2 depth = {pos1.z, pos2.z};
		float2 depthCompare = {
			readDepth(projectPosition(pos1).xy),
			readDepth(projectPosition(pos2).xy),
		};

		float2 depthDelta = depth - depthCompare;

		occlusion += (depthDelta.x > bias && depthDelta.x < SSS_THICKNESS)/step1; // in Shadow
		occlusion += (depthDelta.y > bias && depthDelta.y < SSS_THICKNESS)/step2; // in Shadow
		pos = pos2; 
		total += 1/step1 + 1/step2; // weight samples inversely with distance
	}

    occlusion = pows(occlusion / total, 0.3); // get an average shading based on total weights

	// Contact shadows. The march above takes four samples over a ray hundreds of units long,
	// which finds large occluders and steps straight over small ones. This one is the
	// opposite: many samples over a short ray, for the shadow a prop leaves where it meets the
	// ground. tex2Dlod because the loop sits inside a dynamic branch.
	[branch] if (TESR_ShadowContactData.x > 0.0f && origin.z < TESR_ShadowContactData.w) {
		float scale = 1.0f + origin.z * CONTACT_GROWTH;
		float3 contactStep = TESR_ViewSpaceLightDir.xyz * (TESR_ShadowContactData.y * scale / CONTACT_STEPNUM);
		float contactThickness = TESR_ShadowContactData.z * scale;
		float contactBias = contactThickness * 0.05f;

		float3 contactPos = origin + contactStep * random3.g;   // jittered start hides the step pattern
		float contact = 0.0f;
		[unroll]
		for (int j = 0; j < CONTACT_STEPNUM; j++) {
			contactPos += contactStep;
			float sceneDepth = tex2Dlod(TESR_DepthBuffer, float4(projectPosition(contactPos).xy, 0.0f, 0.0f)).x * farZ;
			float delta = contactPos.z - sceneDepth;
			if (delta > contactBias && delta < contactThickness) contact = 1.0f;
		}

		contact *= TESR_ShadowContactData.x * (1.0f - smoothstep(TESR_ShadowContactData.w * 0.8f, TESR_ShadowContactData.w, origin.z));
		occlusion = max(occlusion, saturate(contact));
	}
	

    // save result of SSS in red channel, and fade contribution with distance
    color.r = lerp(1.0f - occlusion, 1.0, smoothstep(SSS_MAXDEPTH * 0.8, SSS_MAXDEPTH, pos.z));
    return color;
}

// returns a shadow value from darkness setting value (full shadow) to 1 (full light)
float4 Shadow(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;

    float viewDepth;
    float4 worldPos = reconstructWorldPosition(uv, viewDepth);

	// Sample Screen Space shadows
	float4 Shadow = tex2D(TESR_PointShadowBuffer, IN.UVCoord);
    Shadow = pow(Shadow, TESR_ShadowScreenSpaceData.w);
	if (!TESR_ShadowFade.y) return Shadow; // disable shadow maps if ShadowFade.y == 0 (setting for shadow map disabled)

	// Sample shadows from shadowmaps.
	//
	// Skipped when the forward path is doing the cascade lookup: ObjectTemplate.hlsl and
	// friends then apply the result to the sun term alone, which this screen-space composite
	// cannot do -- it can only scale the finished pixel, dimming ambient, emittance and
	// specular along with the sun.
	//
	// Screen-space contact shadows (already in Shadow.r) and point lights (Shadow.g) stay
	// deferred either way; the forward path only takes over the cascade lookup.
	//
	// FORWARD_SHADOWS decides whether the forward code was COMPILED INTO the game shaders;
	// TESR_ShadowForwardData.x decides whether it is RUNNING. When forward is compiled in we
	// must branch at runtime rather than compile this out, so that turning the setting off
	// mid-session hands the cascades back here in the same frame -- game shaders cannot be
	// recompiled at runtime, so a macro alone would leave neither path drawing shadows.
#if FORWARD_SHADOWS
	// GetWorldNormal samples the normals buffer, so it has to stay outside the branch.
	float3 normal = GetWorldNormal(uv);
	[branch] if (TESR_ShadowForwardData.x) {
		Shadow.r = min(Shadow.r, GetLightAmount(worldPos, normal));
	}
#else
	// Forward was compiled out entirely, so the cascades are always ours.
	float3 normal = GetWorldNormal(uv);
	Shadow.r = min(Shadow.r, GetLightAmount(worldPos, normal)); // darkest of screenspace & sun
#endif

	return Shadow;
}


technique {

	pass {
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 ScreenSpaceShadow();
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskH, TESR_ShadowScreenSpaceData.y, 3500, SSS_MAXDEPTH);
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskV, TESR_ShadowScreenSpaceData.y, 3500, SSS_MAXDEPTH);
	}

    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Shadow();
    }

}
