// Image space shadows shader for Oblivion Reloaded

float4x4 TESR_WorldViewProjectionTransform;
float4 TESR_ReciprocalResolution;
float4 TESR_ViewSpaceLightDir;
float4 TESR_ShadowData; // x: quality, y: darkness, z: texel size
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
float4 TESR_ShadowForwardData; // x: 1 when the forward path is SUPPRESSED

sampler2D TESR_DepthBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_ShadowAtlas : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NormalsBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_PointShadowBuffer : register(s3)  = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_NoiseSampler : register(s4) < string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

#define CONTACT_STEPNUM 12
// Growth of the ray with depth, capped. Contact shadows are for detail the shadow maps are too
// coarse to catch, which only exists close up; a ray that kept growing with distance shadowed
// whole slopes and trees far off that the maps already cover, as a soft halo around their
// shadows.
#define CONTACT_GROWTH (1.0f / 2000.0f)
#define CONTACT_MAX_SCALE 3.0f

static const float DARKNESS = 1-TESR_ShadowData.y;
static const float SSS_MAXDEPTH = TESR_ShadowScreenSpaceData.z * TESR_ShadowScreenSpaceData.x;
// Where the denoising blur stops: no further than RenderDistance, and no further than contact
// shadows reach, since past that the buffer is uniformly lit and blurring it does nothing.
// 0 when contact shadows are off, which clips every pixel and skips both blur passes' work.
static const float CONTACT_BLUR_END = (TESR_ShadowContactData.x > 0.0f) ? min(SSS_MAXDEPTH, TESR_ShadowContactData.w) : 0.0f;


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
#include "Includes/SunCascades.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/BlurDepth.hlsl"


VSOUT FrameVS(VSIN IN)
{
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

// returns a semi random float3 between 0 and 1 based on the given seed. (blue noise)
// tailored to return a different value for each uv coord of the screen.
float3 random(float2 seed)
{
	return tex2D(TESR_NoiseSampler, (seed/256 + 0.5) / TESR_ReciprocalResolution.xy).xyz;
}

float4 ScreenSpaceShadow(VSOUT IN) : COLOR0
{
	// Contact shadows: many samples along a short ray toward the sun, for the shadow a prop
	// leaves where it meets the ground, in a crease or at a character's feet. The shadow maps
	// are too coarse for those; anything larger is theirs. Result in the red channel, point
	// light attenuation passes through in green.
	float2 uv = IN.UVCoord;
	float4 color = tex2D(TESR_PointShadowBuffer, uv);
	// tex2Dlod, not random(): the compiler sinks this sample to where it is used, past the dynamic
	// returns below, and warns (X4121) about a gradient sample in flow control. The noise has no
	// use for mips anyway.
	float3 random3 = tex2Dlod(TESR_NoiseSampler, float4((uv / 256 + 0.5) / TESR_ReciprocalResolution.xy, 0.0f, 0.0f)).xyz;

	if (!TESR_ShadowScreenSpaceData.x || TESR_ShadowContactData.x <= 0.0f) return float4(1.0, color.g, 0, 1);

	// reconstructPosition, sampled with tex2Dlod: it follows a dynamic return.
	float4 originClip = float4(uv.x * 2.0f - 1.0f, (1.0f - uv.y) * 2.0f - 1.0f, tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).y, 1.0f);
	float4 originView = mul(originClip, TESR_InvProjectionTransform);
	const float3 origin = originView.xyz / originView.w;
	if (origin.z > TESR_ShadowContactData.w) return float4(1.0, color.g, 0, 1);

	// A surface facing away from the sun has no sunlight for a contact shadow to take away, and
	// the composite would scale whatever this found by a sun share of zero. Skipping it spares
	// the whole march on roughly every surface in the sun's shade. The buffer holds view-space
	// normals, the space TESR_ViewSpaceLightDir is in.
	float3 viewNormal = tex2Dlod(TESR_NormalsBuffer, float4(uv, 0.0f, 0.0f)).xyz * 2.0f - 1.0f;
	float NdotL = dot(viewNormal, TESR_ViewSpaceLightDir.xyz);
	if (NdotL <= 0.0f) return float4(1.0, color.g, 0, 1);
	// Near the terminator the march runs almost along the receiving surface, and bilinear depth
	// reads there are slightly off its true plane, an error that cycles with the sub-pixel sample
	// phase: a small fixed bias flips the test on and off in bands across the ray (horizontal black
	// lines on sun-lit surfaces under a high sun). Fade the term in as the surface turns toward the
	// sun (ported from NVR UNOFFICIAL Optimized, P8-P26).
	float facing = saturate(NdotL * 8.0f);

	// The ray grows a little with distance so it keeps a usable size on screen, up to a cap.
	float scale = min(1.0f + origin.z * CONTACT_GROWTH, CONTACT_MAX_SCALE);
	float3 contactStep = TESR_ViewSpaceLightDir.xyz * (TESR_ShadowContactData.y * scale / CONTACT_STEPNUM);
	float contactThickness = TESR_ShadowContactData.z * scale;
	// The self-intersection bias also grows with distance (same port), so grazing lit faces far off do not band.
	float contactBias = max(contactThickness * 0.05f, origin.z * 0.002f);

	// Marched in clip space. Projection is linear in homogeneous coordinates, so a view-space
	// ray maps to a straight line there: project the start and one step once, then each sample
	// costs an add and a divide instead of a full matrix multiply. View depth is linear along
	// the ray too, so it steps the same way.
	//
	// tex2Dlod: the early outs above are dynamic flow, and a gradient sample after them is illegal.
	float3 startPos = origin + contactStep * random3.g;   // jittered start hides the step pattern
	float4 clipPos = mul(float4(startPos, 1.0f), TESR_ProjectionTransform);
	float4 clipStep = mul(float4(contactStep, 0.0f), TESR_ProjectionTransform);
	float rayDepth = startPos.z;

	// The nearer the occluder along the ray, the darker the shadow, fading to nothing at the
	// ray's end. A shadow is darkest where an object meets the surface and fades away from it;
	// a flat-dark mask instead ended in a hard rim around everything that also cast a
	// shadow-map shadow, which read as a second, softer shadow behind the real one.
	//
	// Every hit counts, grass blades included: grass is not in the shadow maps, so this is the
	// only shadow it casts.
	float contact = 0.0f;
	[unroll]
	for (int j = 0; j < CONTACT_STEPNUM; j++) {
		clipPos += clipStep;
		rayDepth += contactStep.z;
		float2 sampleUV = clipPos.xy / clipPos.w * float2(0.5f, -0.5f) + 0.5f;
		float delta = rayDepth - tex2Dlod(TESR_DepthBuffer, float4(sampleUV, 0.0f, 0.0f)).x * farZ;
		contact = (delta > contactBias && delta < contactThickness) ? max(contact, 1.0f - (float)j / CONTACT_STEPNUM) : contact;
	}

	float fade = 1.0f - smoothstep(TESR_ShadowContactData.w * 0.8f, TESR_ShadowContactData.w, origin.z);
	color.r = 1.0f - saturate(contact * TESR_ShadowContactData.x * fade * facing);
	return color;
}

// returns a shadow value from darkness setting value (full shadow) to 1 (full light)
float4 Shadow(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;

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
	if (!TESR_ShadowForwardData.x) return Shadow;
#endif

	// Only reached when the cascades are ours, so the position and normal are only paid for
	// then. tex2Dlod for the normal: it is sampled after the dynamic returns above.
    float viewDepth;
    float4 worldPos = reconstructWorldPosition(uv, viewDepth);
	float3 normal = mul(TESR_ViewTransform, float4(tex2Dlod(TESR_NormalsBuffer, float4(uv, 0.0f, 0.0f)).xyz * 2.0f - 1.0f, 1.0f)).xyz;   // GetWorldNormal
	Shadow.r = min(Shadow.r, GetLightAmount(worldPos, normal)); // darkest of screenspace & sun

	return Shadow;
}


technique {

	pass {
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 ScreenSpaceShadow();
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskH, TESR_ShadowScreenSpaceData.y, 3500, CONTACT_BLUR_END);
	}

	pass {
		VertexShader = compile vs_3_0 FrameVS();
	 	PixelShader = compile ps_3_0 DepthBlur(TESR_PointShadowBuffer, OffsetMaskV, TESR_ShadowScreenSpaceData.y, 3500, CONTACT_BLUR_END);
	}

    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 Shadow();
    }

}
