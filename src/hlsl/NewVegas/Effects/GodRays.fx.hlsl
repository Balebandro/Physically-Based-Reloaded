// GodRays full screen shader for Oblivion/Skyrim Reloaded

float4 TESR_ReciprocalResolution;
float4 TESR_GameTime;
float4 TESR_SunColor;
float4 TESR_GodRaysRay; // x: intensity, y:length, z: density, w: visibility
float4 TESR_GodRaysRayColor; // x:r, y:g, z:b, w:saturate
float4 TESR_GodRaysData; // x: passes amount, y: luminance, z:multiplier, w: time enabled
float4 TESR_ViewSpaceLightDir; // view space light vector
float4 TESR_SunDirection; // worldspace sun light vector
float4 TESR_SunPosition; // worldspace sundisk position
float4 TESR_ShadowFade; // attenuation factor of sunsets/sunrises and moon phases
float4 TESR_SunAmount;
float4 TESR_SunsetColor;
float4 TESR_DebugVar;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SourceBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_AvgLumaBuffer : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Sky.hlsl"

static const float raspect = 1.0f / TESR_ReciprocalResolution.z;
static const float samples = 10;
static const float stepLength = 1/samples;
static const float scale = 0.5;
static const float4x4 ditherMat = {{0.0588, 0.5294, 0.1765, 0.6471},
									{0.7647, 0.2941, 0.8824, 0.4118},
									{0.2353, 0.7059, 0.1176, 0.5882},
									{0.9412, 0.4706, 0.8235, 0.3259}};

static const float lumTreshold = TESR_GodRaysData.y;
static const float multiplier = TESR_GodRaysData.z;
static const float intensity = TESR_GodRaysRay.x;
static const float stepLengthMult = TESR_GodRaysRay.y;
static const float glareReduction = TESR_GodRaysRay.z;
static const float godrayCurve = TESR_GodRaysRay.w;
static const float sunHeight = 1 - shade(TESR_SunPosition.xyz, blue.xyz);

// How much air lies in front of a pixel, 0..1: the shafts are light scattered by the air between the eye and what it sees,
// so something a few units away (the first-person model, a wall at the face) gets almost none and is not lit over.
static const float nearAirDistance = 256.0f;
float AirInFront(float2 uv)
{
	return saturate(readDepthLod(uv) / nearAirDistance);
}

struct VSOUT {
	float4 vertPos : POSITION;
	float2 UVCoord : TEXCOORD0;
};
 
struct VSIN {
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};
 
VSOUT FrameVS(VSIN IN) {
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

float4 SkyMask(VSOUT IN) : COLOR0 {
	
	float2 uv = IN.UVCoord / scale;
	clip((uv <= 1) - 1);

	float sunset = pows(sunHeight, 8);
    float3 sunColor = linearize(TESR_SunColor).rgb + lerp(linearize(TESR_SunsetColor.rgb), 0, sunset); // linearise

	float glarePower = lerp(0.1, 8.0, sunset); // increase flare boost during sunrise/sunset

	//only pixels belonging to the sky will register; as a share of the four full-res pixels here, so a dithered alpha
	//(foliage) counts as partly open instead of a hard checker the radial blur streaks into speckled rays
	float2 px = TESR_ReciprocalResolution.xy * 0.5f;
	float depth = 0.25f * ((readDepth(uv + float2(-px.x, -px.y)) / farZ > 0.9) + (readDepth(uv + float2(px.x, -px.y)) / farZ > 0.9) +
	                       (readDepth(uv + float2(-px.x, px.y)) / farZ > 0.9) + (readDepth(uv + float2(px.x, px.y)) / farZ > 0.9));
	float3 sunGlare = pows(dot(TESR_ViewSpaceLightDir.xyz, normalize(reconstructPosition(uv))), 180) * glarePower; // fake sunglare computed from light direction
	float3 color = linearize(tex2D(TESR_SourceBuffer, uv)).rgb;
	color = (color + sunGlare * sunColor) * depth * smoothstep(0, 0.01, sunHeight);

	return float4(color, 1.0f);
}


float4 LightMask(VSOUT IN) : COLOR0 {
	// isolates the brightest parts of the sky to only use those for radial blur
	
	float2 uv = IN.UVCoord;
	clip((uv <= scale) - 1);

	// quick average lum with 4 samples at corner pixels
	float3 color = tex2D(TESR_RenderedBuffer, uv).rgb;
	color += tex2D(TESR_RenderedBuffer, uv + float2(-1, -1) * TESR_ReciprocalResolution.xy).rgb;
	color += tex2D(TESR_RenderedBuffer, uv + float2(-1, 1) * TESR_ReciprocalResolution.xy).rgb;
	color += tex2D(TESR_RenderedBuffer, uv + float2(1, -1) * TESR_ReciprocalResolution.xy).rgb;
	color += tex2D(TESR_RenderedBuffer, uv + float2(1, 1) * TESR_ReciprocalResolution.xy).rgb;
	color /= 5;

	// extract bright pixels
	float treshold = lerp(2.0, 0.0, pow(abs(sunHeight), 8)); // scale the bloom power with sunsets/sunrises
	float bloom = smoothstep(treshold, treshold + lumTreshold * 15, luma(color));

	color = saturate(bloom * color * 100 * intensity);

	return float4(color.rgb, 1.0f);
}


float RayAttenuation(float2 uv) {
	float3 eyeDir = normalize(reconstructPosition(uv));
	float heightAttenuation = TESR_GodRaysData.w ? lerp(0.2, 4.0, pows(sunHeight, 4)) : 1.0;
	return pow(compress(shade(TESR_ViewSpaceLightDir.xyz, eyeDir)), 2.5) *
		heightAttenuation * (sunHeight < 1);
}

float4 RadialBlur(VSOUT IN, uniform float step, uniform float storeAttenuation) : COLOR0 {
	float2 uv = IN.UVCoord;
	clip((uv <= scale) - 1);
	uv /= scale; // restore uv scale to do calculations in [0, 1] space
	uv -= 0.5 * TESR_ReciprocalResolution.xy;

	// calculate vector from pixel to sun along which we'll sample
	float2 sunPos = projectPosition(TESR_ViewSpaceLightDir.xyz * farZ).xy;

	// vector from the given pixel to the sun position
	float2 blurDirection = (sunPos.xy - uv) * float2(1.0f, raspect); // apply aspect ratio correction
	float distance = length(blurDirection); // distance from pixel to radial blur center

	float2 dir = blurDirection / max(distance, 0.000001f);

	float stepSize = step * stepLengthMult;

	// sample the light clamped image from the pixel to the sun for the given amount of samples
	float2 samplePos = uv;
	float4 color = float4(0, 0, 0, 1);
	float total = 1;
	for (float i=0; i < samples; i++){
		float sampleDistance = stepSize * i;
		samplePos = uv + (dir * sampleDistance / float2(1, raspect));

		[branch] if (sampleDistance <= distance && samplePos.x > 0 && samplePos.y > 0 && samplePos.x < 1 && samplePos.y < 1) {
			color += tex2Dlod(TESR_RenderedBuffer, float4(samplePos * scale, 0, 0));
			total += 1;
		}
	}
	color /= total;

	return float4(color.rgb, lerp(1.0, RayAttenuation(uv), storeAttenuation));
}


float4 Combine(VSOUT IN) : COLOR0
{
	float scale = 0.5; // godrays were rendered at smaller res
	float4 color = linearize(tex2D(TESR_SourceBuffer, IN.UVCoord));
	float2 uv = IN.UVCoord;

	uv *= scale;
	float4 rays = tex2D(TESR_RenderedBuffer, uv);

	// calculate sun color
    float3 sunColor = GetSunColor(shade(TESR_SunDirection.xyz, blue.xyz), 1, TESR_SunAmount.x, TESR_SunColor.rgb, TESR_SunsetColor.rgb);
    float3 godRayColor = linearize(TESR_GodRaysRayColor).rgb;

	//rays = pows(rays, godrayCurve); // increase response curve to extract more definition from godray pass
	rays.rgb *= multiplier * lerp(sunColor, godRayColor, TESR_GodRaysRayColor.w);
	rays.rgb *= rays.a * AirInFront(IN.UVCoord);

	// reduce banding by dithering areas impacted by the rays
	//float maxDitherLuma = 0.05; // 0.2 ^ 2.2, rounded down
	//bool useDither = (rays.r + rays.g + rays.b > 0) && (pows(tex2D(TESR_AvgLumaBuffer, float2(0.5, 0.5)),2.2).x < maxDitherLuma); // only dither when there is some ray & when average luma is low
	//uv /= TESR_ReciprocalResolution.xy;
	//rays.rgb += (ditherMat[(uv.x)%4 ][ (uv.y)%4 ] / 255) * useDither;

	color += max(rays, 0) * 5 * color + max(rays, 0) * 0.2;
	color = delinearize(color);
	return float4(color.rgb, 1);
}
 
technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 SkyMask(); 
	}

	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 LightMask(); 
	}

	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 RadialBlur(stepLength, 0); 
	}

	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 RadialBlur(stepLength * stepLength, 0); 
	}

	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 RadialBlur(stepLength * stepLength * stepLength, 1); 
	}

	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		Pixelshader = compile ps_3_0 Combine();
	}
}

float4 NVR_GodRaysLayout;
sampler2D NVR_GodRaysBuffer : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };

float4 NVR_GodRaysSkip;
float4 NVR_GodRaysReduce;
sampler2D NVR_GodRaysMax : register(s6) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

bool GodRaysEmpty() {
	return NVR_GodRaysSkip.x > 0.5f && tex2Dlod(NVR_GodRaysMax, float4(0.5f, 0.5f, 0.0f, 0.0f)).r <= 0.0f;
}

float4 MaxReduce(VSOUT IN, float2 vpos : VPOS) : COLOR0 {
	const float2 origin = floor(vpos) * 8.0f + 0.5f;
	float m = 0.0f;
	[unroll] for (int y = 0; y < 8; y++) {
		[unroll] for (int x = 0; x < 8; x++) {
			const float3 c = tex2Dlod(NVR_GodRaysBuffer, float4((origin + float2(x, y)) * NVR_GodRaysReduce.xy, 0.0f, 0.0f)).rgb;
			m = max(m, max(c.r, max(c.g, c.b)));
		}
	}
	return float4(m, m, m, 1.0f);
}

VSOUT HalfVS(VSIN IN) {
	VSOUT OUT = FrameVS(IN);
	OUT.UVCoord += 0.5 * (NVR_GodRaysLayout.zw - TESR_ReciprocalResolution.xy);
	return OUT;
}

float3 reconstructPositionFromDepth(float2 uv, float linearDepth01)
{
	float4 viewSpace = mul(float4(uv.x * 2 - 1, (1 - uv.y) * 2 - 1, projectedDepthFromLinear(linearDepth01), 1.0f), TESR_InvProjectionTransform);
	viewSpace /= viewSpace.w;
	return viewSpace.xyz;
}

float4 DedicatedSkyMask(VSOUT IN) : COLOR0 {
	float2 uv = IN.UVCoord;

	float rawDepth = tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).x;
	// How much of this half-res texel is sky: its four full-res pixels, so a dithered alpha (foliage) counts as partly open
	// instead of a hard sky / not-sky checker the radial blur streaks into speckled rays.
	float2 px = TESR_ReciprocalResolution.xy * 0.5f;
	float depth = 0.25f * ((tex2Dlod(TESR_DepthBuffer, float4(uv + float2(-px.x, -px.y), 0.0f, 0.0f)).x > 0.9) +
	                       (tex2Dlod(TESR_DepthBuffer, float4(uv + float2( px.x, -px.y), 0.0f, 0.0f)).x > 0.9) +
	                       (tex2Dlod(TESR_DepthBuffer, float4(uv + float2(-px.x,  px.y), 0.0f, 0.0f)).x > 0.9) +
	                       (tex2Dlod(TESR_DepthBuffer, float4(uv + float2( px.x,  px.y), 0.0f, 0.0f)).x > 0.9));
	float horizon = smoothstep(0, 0.01, sunHeight);
	[branch] if (depth * horizon == 0.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

	float sunset = pows(sunHeight, 8);
	float3 sunColor = linearize(TESR_SunColor).rgb + lerp(linearize(TESR_SunsetColor.rgb), 0, sunset);
	float glarePower = lerp(0.1, 8.0, sunset);

	float3 sunGlare = pows(dot(TESR_ViewSpaceLightDir.xyz, normalize(reconstructPositionFromDepth(uv, rawDepth))), 180) * glarePower;
	float3 color = linearize(tex2Dlod(TESR_RenderedBuffer, float4(uv, 0.0f, 0.0f))).rgb;
	color = (color + sunGlare * sunColor) * depth * horizon;

	return float4(color, 1.0f);
}

float4 DedicatedLightMask(VSOUT IN) : COLOR0 {
	float2 uv = IN.UVCoord;
	float2 texel = NVR_GodRaysLayout.zw;
	float3 color = tex2D(NVR_GodRaysBuffer, uv).rgb;
	color += tex2D(NVR_GodRaysBuffer, uv + float2(-1, -1) * texel).rgb;
	color += tex2D(NVR_GodRaysBuffer, uv + float2(-1, 1) * texel).rgb;
	color += tex2D(NVR_GodRaysBuffer, uv + float2(1, -1) * texel).rgb;
	color += tex2D(NVR_GodRaysBuffer, uv + float2(1, 1) * texel).rgb;
	color /= 5;

	float treshold = lerp(2.0, 0.0, pow(abs(sunHeight), 8));
	float bloom = smoothstep(treshold, treshold + lumTreshold * 15, luma(color));
	color = saturate(bloom * color * 100 * intensity);

	return float4(color.rgb, 1.0f);
}

float4 DedicatedRadialBlur(VSOUT IN, uniform float step, uniform float storeAttenuation) : COLOR0 {
	[branch] if (GodRaysEmpty()) return float4(0.0f, 0.0f, 0.0f, 1.0f);
	float2 uv = IN.UVCoord - 0.5 * TESR_ReciprocalResolution.xy;

	float2 sunPos = projectPosition(TESR_ViewSpaceLightDir.xyz * farZ).xy;
	float2 blurDirection = (sunPos.xy - uv) * float2(1.0f, raspect);
	float distance = length(blurDirection);
	float2 dir = blurDirection / max(distance, 0.000001f);
	float stepSize = step * stepLengthMult;

	float2 samplePos = uv;
	float4 color = float4(0, 0, 0, 1);
	float total = 1;
	for (float i=0; i < samples; i++){
		float sampleDistance = stepSize * i;
		samplePos = uv + (dir * sampleDistance / float2(1, raspect));
		[branch] if (sampleDistance <= distance && samplePos.x > 0 && samplePos.y > 0 && samplePos.x < 1 && samplePos.y < 1) {
			color += tex2Dlod(NVR_GodRaysBuffer, float4(samplePos, 0, 0));
			total += 1;
		}
	}
	color /= total;

	return float4(color.rgb, lerp(1.0, RayAttenuation(uv), storeAttenuation));
}

float4 DedicatedCombine(VSOUT IN) : COLOR0
{
	float4 source = tex2D(TESR_RenderedBuffer, IN.UVCoord);
	float4 rays = tex2D(NVR_GodRaysBuffer, IN.UVCoord);
	[branch] if (NVR_GodRaysSkip.y > 0.5f && !any(rays.rgb)) return float4(source.rgb, 1.0f);
	float4 color = linearize(source);

	float3 sunColor = GetSunColor(shade(TESR_SunDirection.xyz, blue.xyz), 1, TESR_SunAmount.x, TESR_SunColor.rgb, TESR_SunsetColor.rgb);
	float3 godRayColor = linearize(TESR_GodRaysRayColor).rgb;

	rays.rgb *= multiplier * lerp(sunColor, godRayColor, TESR_GodRaysRayColor.w);
	rays.rgb *= rays.a * AirInFront(IN.UVCoord);

	color += max(rays, 0) * 5 * color + max(rays, 0) * 0.2;
	color = delinearize(color);
	return float4(color.rgb, 1);
}

technique DedicatedGodRays
{
	pass SkyMask { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 DedicatedSkyMask(); }
	pass LightMask { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 DedicatedLightMask(); }
	pass Blur1 { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 DedicatedRadialBlur(stepLength, 0); }
	pass Blur2 { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 DedicatedRadialBlur(stepLength * stepLength, 0); }
	pass Blur3 { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 DedicatedRadialBlur(stepLength * stepLength * stepLength, 1); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 DedicatedCombine(); }
}

technique GodRaysMaxReduce
{
	pass Reduce { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 MaxReduce(); }
}

float4 IdleTest(VSOUT IN) : COLOR0 {
	clip(tex2Dlod(NVR_GodRaysMax, float4(0.5f, 0.5f, 0.0f, 0.0f)).r - NVR_GodRaysSkip.z);
	return float4(1.0f, 1.0f, 1.0f, 1.0f);
}

technique GodRaysIdleTest
{
	pass Test { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 IdleTest(); }
}
