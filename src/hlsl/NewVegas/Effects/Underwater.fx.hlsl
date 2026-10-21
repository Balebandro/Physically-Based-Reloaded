// Underwater fullscreen shader for Oblivion Reloaded
float4 TESR_ReciprocalResolution;
float4 TESR_SunDirection;
float4 TESR_GameTime;
float4 TESR_WaterCoefficients; // r g b scattering
float4 TESR_SunColor;
float4 TESR_FogColor;
// float4 TESR_FogData; // x: near fog distance, y:far fog distance, z: sun glare, w: fog power
float4 TESR_WaterFog; // x: near fog distance, y:far fog distance, z: sun glare, w: fog power
float4 TESR_WaterVolume; // x; causticsStrength, y:shore factor, z:turbidity, w: causticsStrengthS
float4 TESR_WaveParams;
float4 TESR_WaterSettings; // x: caustic strength, y:depthDarkness, w: refraction, z: caustic strength S ?
float4 TESR_WaterShallowColor; // Shallow color used by the game for water
float4 TESR_WaterDeepColor; // Deep color used by the game for water
float4 TESR_DebugVar;
float4 TESR_HorizonColor;
float4 TESR_SunAmount;
float4 TESR_SkyColor;
float4 TESR_SkyLowColor;

#include "Includes/Helpers.hlsl"

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SourceBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_WavesSampler : register(s3) < string ResourceName = "Water\water_NRM.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; ADDRESSW = WRAP; MAGFILTER = ANISOTROPIC; MINFILTER = ANISOTROPIC; MIPFILTER = ANISOTROPIC; } ;
sampler2D TESR_NormalsBuffer : register(s4) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D TESR_BlueNoiseSampler : register(s5) < string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D TESR_CausticsSampler : register(s6) < string ResourceName = "Water\caust_001.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = ANISOTROPIC; MINFILTER = ANISOTROPIC; MIPFILTER = ANISOTROPIC; };
sampler2D TESR_PointShadowBuffer : register(s7) = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = ANISOTROPIC; MINFILTER = ANISOTROPIC; MIPFILTER = ANISOTROPIC; };

static const float frame = TESR_GameTime.z * TESR_WaveParams.z * 1.5;
static const float4x4 ditherMat = {{0.0588, 0.5294, 0.1765, 0.6471},
	{0.7647, 0.2941, 0.8824, 0.4118},
	{0.2353, 0.7059, 0.1176, 0.5882},
{0.9412, 0.4706, 0.8235, 0.3259}};

static const float causticsStrength = TESR_WaterVolume.x;
static const float shoreFactor = TESR_WaterVolume.y;
static const float turbidity = TESR_WaterVolume.z;
static const float godraysStrength = TESR_WaterVolume.w;
static const float3 extCoeff = TESR_WaterCoefficients.xyz;// * turbidity;
static const float scattCoeff = TESR_WaterCoefficients.w;// * turbidity;
static const float waveWidth = TESR_WaveParams.y;
static const float depthDarkness = TESR_WaterSettings.y;
static const float3 up = float3(0, 0, 1);
static const float sunLuma = luma(pows(TESR_SunColor.rgb,2.2)); // linearise

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

#include "Includes/Depth.hlsl"
#include "Includes/Normals.hlsl"
#include "Includes/Blur.hlsl"
#include "Includes/Sky.hlsl"

float3 random(float2 seed)
{
	return tex2D(TESR_BlueNoiseSampler, (seed/256 + 0.5) / TESR_ReciprocalResolution.xy).xyz;
}
// DUST CALCULUS
float hash13(float3 p) {
	return frac(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453);
}

float3 hash33(float3 p) {
	return frac(sin(float3(
		dot(p, float3(127.1, 311.7, 74.7)),
		dot(p, float3(269.5, 183.3, 246.1)),
		dot(p, float3(113.5, 271.9, 124.6))
	)) * 43758.5453);
}

float dustSpeck(float3 p, float radius, float zScale) {
	float3 cell = floor(p);
	float3 f = frac(p) - 0.5;
	float3 rnd = hash33(cell) - 0.5;
	
	float3 d = f - rnd * float3(0.85, 0.85, 0.45);
	d.z *= zScale;
	
	float dist = length(d);
	return 1.0 - smoothstep(radius * 0.45, radius, dist);
}
// lerp between sky colors to recreate the sky for refractions as vanilla buffer is tinted
float3 getSkyColor(float3 eyeDirection, float3 sunColor) {
	float upAmount = saturate(pow(shade(eyeDirection, float3(0, 0, 1)), 0.5));
	
	float3 horizonColor = linearize(TESR_HorizonColor).rgb;
	float3 skyLowColor  = linearize(TESR_SkyLowColor).rgb;
	
	float3 skyColor = lerp(horizonColor, skyLowColor, upAmount);
	
	// Match the plane shader's stronger sun lobe more closely
	skyColor += sunColor * 5.0 * pows(shades(eyeDirection, -TESR_SunDirection.xyz), 20.0);
	
	return skyColor;
}

float4 getWaveTexture(float2 uv) {
    float2 texPos = uv;
	
	float waveWidth = TESR_WaveParams.y;
    float choppiness = TESR_WaveParams.x;
    float speed = TESR_GameTime.x * 0.002 * TESR_WaveParams.z;
    float smallScale = 0.5;
    float bigScale = 2;
    float4 waveTexture = expand(tex2D(TESR_WavesSampler, texPos * smallScale * waveWidth + normalize(float2(1, 4)) * speed));
    float4 waveTextureLarge = expand(tex2D(TESR_WavesSampler, texPos * bigScale * waveWidth + normalize(float2(-3, -2)) * speed));
	
    // combine waves
    waveTexture = float4(waveTextureLarge.xy + waveTexture.xy,  1, 1);
    waveTexture.xy *= choppiness;
	
    waveTexture = normalize(waveTexture);
    return waveTexture;
}
// --- CAUSTICS ------------------------------------------------

float getCaustics(float3 pos){
	float depth = TESR_WaterSettings.z - pos.z;
	pos += (depth/TESR_SunDirection.z) * TESR_SunDirection.xyz; // we go to the surface in the direction of the sun to sample
	
    float speed = TESR_GameTime.x * 0.01 * TESR_WaveParams.z;
	float scale = 0.002;
	
	float layer1 = tex2D(TESR_CausticsSampler, pos.xy * scale  + speed * normalize(float2(-1.2, - 2.5))).r;
	float layer2 = tex2D(TESR_CausticsSampler, pos.xy * scale * 1.2  + speed * normalize(float2(0.5, 2))).r;
	
	return pows(min(layer1, layer2), 1.3) * 6.0; //strengthen the definition and strength of the caustics
	// return pow(1 - shade(getWaveTexture(pos.xy * 0.0005).xyz, up), 10) * 100000 * causticsStrength;
}

// --- GOD RAYS ------------------------------------------------

float4 Godrays( VSOUT IN) : COLOR0 {
	// volumetric god rays rendered at quarter resolution
	float2 uv = IN.UVCoord * 2;
	clip( (uv <= 1) - 1);
	
    float3 eyeVector = toWorld(uv);
	float depth = length(readDepth(uv) * eyeVector);
	
	float godraysMaxDistance = 2000;
	float stepSize = godraysMaxDistance / 50;
	float3 step = eyeVector * stepSize;
	
	float4 color = float4(0, 0, 0, 1);
	
	float3 samplingUV = TESR_CameraPosition.xyz;
	[unroll]
	for (float i=1; i < 50; i++){
		samplingUV += step * lerp(0.5, 1, random(uv + TESR_ReciprocalResolution.xx * i));
		float distance = stepSize * i;
		float samplingDepthFade = smoothstep(800, 60, TESR_WaterSettings.x - samplingUV.z);
		float samplingDistanceFade = 1 - distance/godraysMaxDistance;
		float4 rayColor = lerp(float4(0, 0, 0, 1), float4(1, 1, 1, 1), samplingDistanceFade) * sunLuma * 0.05;
		color += getCaustics(samplingUV) * rayColor * samplingDepthFade * samplingDistanceFade * (distance < depth);
	}
	
	return float4(smoothstep(0.1, 0.4, color).rgb, 1); // clamp the values to increase the strength and improve blending
}


float aboveWater(float eyeHeight, float pointHeight, float waterHeight, float depth){
	if (eyeHeight < waterHeight - 4.0) return false;
	return eyeHeight > (waterHeight + 4.0) || pointHeight > (waterHeight - 0.6);
}


float4 Water( VSOUT IN ) : COLOR0 {
	float depth = readDepth(IN.UVCoord);
    float3 eyeVector = toWorld(IN.UVCoord);
	float3 eyeDirection = normalize(eyeVector);
    float3 worldPos = TESR_CameraPosition.xyz + eyeVector * depth;
	float3 eyePos = TESR_WaterSettings.x - TESR_CameraPosition.xyz;
	float fogDepth = length(eyeVector * depth); // a depth measure that's at the same distance from the camera at all angles
	float waterDepth = TESR_WaterSettings.x - worldPos.z; 
	float3 floorNormal = GetWorldNormal(IN.UVCoord);
	
	// float3 blurredColor = tex2D(TESR_RenderedBuffer, IN.UVCoord/2 + 1).rgb;
	float4 color = tex2D(TESR_SourceBuffer, IN.UVCoord);
 	if (aboveWater(TESR_CameraPosition.z, worldPos.z, TESR_WaterSettings.x, depth)) return color;
	
	color = linearize(color); //linearise
	
	
	// --- DEPTH DARKENESS ------------------------------------------------
	// depthDarkness (user setting) scales the overall strength.
	float falloff = 0.0015; // lowered from 0.004 — depth tint starts deeper
	// Darkening is driven purely by how deep the hit point is below the water surface.
	float pointDepth = max(0.2, TESR_WaterSettings.x - worldPos.z);
	float fogAmount = saturate(1.0 - exp(-pointDepth * falloff));
	
	float3 waterDeepColor = linearize(TESR_WaterDeepColor).rgb;
	float3 waterShallowColor = linearize(TESR_WaterShallowColor).rgb;
	float3 sunColor = linearize(TESR_SunColor).rgb;
	
	// --- UNDERWATER FOG ------------------------------------------------
	
	float camDepth = max(0.6, TESR_WaterSettings.x - TESR_CameraPosition.z);
	float shallowFactor = 1.0 - smoothstep(0.0, 18.0, camDepth);
	float3 skyColor = getSkyColor(eyeDirection, sunColor);
	
	float3 fogColor = skyColor * lerp(1.15, 0.75, 1.0 - shallowFactor);
	fogColor = lerp(fogColor, linearize(TESR_FogColor).rgb, 0.35);
	fogColor = saturate(fogColor);
	
	// --- CAUSTICS ------------------------------------------------
	
	// fading parameters for caustics and god rays
	float floorAngle = (smoothstep(0.5,1, dot(floorNormal, up)) + smoothstep(0.8,1, dot(floorNormal, TESR_SunDirection.xyz))) / 2;
	// depthFade: zero AT the surface, builds up as geometry gets deeper.
	// Previously was smoothstep(800,0,...) which was strongest AT the surface — wrong.
	// Now ramps from 0 (surface) to 1 at 200 units deep, so shallow wading doesn't overbrighten.
	float depthFade = smoothstep(0, 10, waterDepth);
	float distanceFade = smoothstep(8000, 3000, fogDepth); // smooth falloff, fully gone at 5000 units
	
	float2 shadows = tex2D(TESR_PointShadowBuffer, IN.UVCoord).rg;
	float caustics = getCaustics(worldPos) * shadows.r;
	
	float causticSurfaceFade = saturate(invlerp(0.0, 50.0, camDepth));
	float3 causticsContrib = color.rgb * pows(caustics, 2.0) * causticSurfaceFade * sunColor * depthFade * floorAngle * distanceFade * sunLuma * causticsStrength * 40;
	
	color.rgb += min(causticsContrib, color.rgb * 2.5);
	
	
	// --- WATER COLOR TINT ------------------------------------------------
	// Applied uniformly to everything including nearby geometry (player).
	// Driven by how deep the CAMERA is, not the fragment — so close objects
	// like the player get the same tint as the background.
	// Red is absorbed fastest, blue last — classic underwater look.
	
	float tintStrength = saturate(camDepth * 0.02) * pows(depthDarkness, 0.5);
	
	// Hybrid tint: keep plane/fog palette, but bring back actual water color for nearby actors
	float3 nearWaterTint = lerp(waterDeepColor, waterShallowColor, 0.75);
	float3 tintTarget = lerp(fogColor, nearWaterTint, 0.95);
	
	color.rgb *= lerp(float3(1,1,1), saturate(tintTarget), tintStrength);
	
	// --- CAMERA-BASED WATER COLUMN DARKENING -----------------------------
	float absorptionStrength = saturate(camDepth * 0.0010) * pows(depthDarkness, 0.3);
	
	// Darker tint the deeper the camera goes underwater
	float3 deepWaterTint = lerp(waterShallowColor, waterDeepColor, saturate(camDepth / 2200.0));
	float3 absorptionTarget = lerp(fogColor, deepWaterTint, 0.35);
	
	color.rgb *= lerp(float3(1,1,1), saturate(absorptionTarget), absorptionStrength);
	
	// --- UNDERWATER SUN CONTRAST RECOVERY -------------------------------
	float NdotL = saturate(dot(floorNormal, TESR_SunDirection.xyz));
	
	// Soft light mask, less faceted than a hard diffuse multiply
	float sunMask = smoothstep(0.35, 0.85, NdotL);
	sunMask *= shadows.r;
	sunMask *= depthFade;
	sunMask *= distanceFade;
	
	// Optional extra emphasis from caustics pattern without adding flat light
	float causticMask = saturate(pows(caustics, 1.2) * causticSurfaceFade * 0.35);
	
	// Final mask controlling where contrast recovery happens
	float contrastMask = saturate(sunMask * 0.85 + causticMask);
	
	// Mild brightness lift first, based on darker texels responding more
	float3 lightTerm = max(0.0, luma(exp(-color.rgb * 3.2))) * sunColor * contrastMask * sunLuma * 0.28;
	float3 litColor = color.rgb + color.rgb * lightTerm;
	
	// Apply light only where the underwater sunlight actually reaches
	color.rgb = lerp(color.rgb, litColor, contrastMask);
	
	// Flashlight-style contrast recovery, adapted for underwater
	const float UW_CONTRAST = 1.85;
	const float UW_PIVOT = 0.16;
	
	float factor = 1.0 + contrastMask * UW_CONTRAST;
	float3 contrasted = max(color.rgb, (color.rgb - UW_PIVOT) * factor + UW_PIVOT);
	
	// Blend the contrast recovery only inside lit areas
	color.rgb = lerp(color.rgb, contrasted, contrastMask * 0.85);
	
	
	// --- DISTANCE FOG ----------------------------------------------------
	// Driven by game ini values (TESR_WaterFog.x/y) so the ini stays in control.
	// Multipliers let you push the range farther than the game default.
	//float fogStart   = TESR_WaterFog.x * 80.0;
	//float fogEnd     = TESR_WaterFog.y * 80.0;
	//float fogStrength = 0.3;
	static const float fogStart = 0.0;
	static const float fogEnd = 16000.0;
	static const float fogStrength = 0.0;
	
	float distanceFog = saturate(invlerp(fogStart, fogEnd, fogDepth));
	
	// deep underwater adds a base fog amount everywhere
	float cameraFog = saturate(invlerp(250.0, 1400.0, camDepth));
	cameraFog = pow(cameraFog, 0.6);
	
	float totalFog = saturate(distanceFog * fogStrength + cameraFog * 0.35);
	
	color.rgb *= lerp(float3(1,1,1), saturate(lerp(fogColor, waterDeepColor, 0.35)), totalFog);
	
	
	
	
	// --- UNDERWATER DUST / GRAIN ----------------------------------------
	float time = TESR_GameTime.x;
	
	// Sample several positions ALONG the camera ray, not only at worldPos.
	// This makes the dust visible in open water and when looking toward the surface.
	float rayDepth1 = min(fogDepth, 140.0);
	float rayDepth2 = min(fogDepth, 320.0);
	float rayDepth3 = min(fogDepth, 700.0);
	
	float3 samplePos1 = TESR_CameraPosition.xyz + eyeDirection * rayDepth1;
	float3 samplePos2 = TESR_CameraPosition.xyz + eyeDirection * rayDepth2;
	float3 samplePos3 = TESR_CameraPosition.xyz + eyeDirection * rayDepth3;
	
	// World-anchored drifting dust field
	float3 dustP1 = samplePos1 / float3(18.0, 18.0, 28.0) + float3( time * 0.000035,  time * 0.000020, 0.0);
	float3 dustP2 = samplePos2 / float3(10.0, 10.0, 16.0) + float3(-time * 0.000020,  time * 0.000028, 0.0);
	float3 dustP3 = samplePos3 / float3( 6.0,  6.0, 10.0) + float3( time * 0.000012, -time * 0.000018, 0.0);
	
	float dust1 = dustSpeck(dustP1, 0.16, 1.8);
	float dust2 = dustSpeck(dustP2, 0.12, 1.6);
	float dust3 = dustSpeck(dustP3, 0.08, 1.4);
	
	// Stronger fade so the dust is subtler and less sparkly
	float depthFade1 = pows(saturate(invlerp(80.0, 260.0, rayDepth1)), 1.8);
	float depthFade2 = pows(saturate(invlerp(120.0, 600.0, rayDepth2)), 2.0);
	float depthFade3 = pows(saturate(invlerp(220.0, 900.0, rayDepth3)), 2.2);
	
	// Keep it below the water surface
	float surfaceFade1 = saturate((TESR_WaterSettings.x - samplePos1.z) / 10.0);
	float surfaceFade2 = saturate((TESR_WaterSettings.x - samplePos2.z) / 12.0);
	float surfaceFade3 = saturate((TESR_WaterSettings.x - samplePos3.z) / 14.0);
	
	float dustAmount =
	dust1 * 0.30 * depthFade1 * surfaceFade1 +
	dust2 * 0.22 * depthFade2 * surfaceFade2 +
	dust3 * 0.14 * depthFade3 * surfaceFade3;
	
	// Much less shiny: mostly fog-colored, only tiny sun lift
	float3 dustColor = lerp(fogColor, waterShallowColor, 0.25);
	dustColor = lerp(dustColor, sunColor, 0.04);
	
	// Very subtle final add
	color.rgb += dustAmount * dustColor * 0.18;
	
	
	
	// --- DISTANT SURFACE SKIRT -------------------------------------------
	// At far distances the water plane edge is visible as a hard cut against the
	// underwater fog. This gradient fades the water surface color downward over
	// 500 world units, softening that boundary.
	//
	// Conditions: fragment must be close to the surface (small waterDepth)
	//             AND far from the camera (fogDepth > skirtStart)
	//
	// skirtStart/End: distance ramp where skirt fades in
	// skirtHeight:    world units below surface over which skirt fades to transparent
	float skirtStart  = 1000.0;
	float skirtEnd    = 6000.0;
	float skirtHeight = 500.0;
	
	float skirtDistFade  = smoothstep(skirtStart, skirtEnd, fogDepth);
	float skirtDepthFade = saturate(1.0 - waterDepth / skirtHeight); // 1 at surface, 0 at skirtHeight below
	float skirtMask = skirtDistFade * skirtDepthFade;
	
	float3 skirtColor = waterDeepColor * sunLuma * 0.4	;
	color.rgb = lerp(color.rgb, skirtColor, skirtMask * 0.9);
	
	
	
	// blend in godrays
	float rays = tex2D(TESR_RenderedBuffer, IN.UVCoord / 2).r;
rays = pows(saturate(rays), 1.5);
color.rgb += rays * sunColor * godraysStrength * color.rgb;
//float3 underwaterRayColor = lerp(sunColor, lerp(waterShallowColor, waterDeepColor, saturate(camDepth / 1500.0)), 0.2);
//color.rgb += rays * underwaterRayColor * godraysStrength * color.rgb;
	
	// GLOBAL BRIGHTNESS
	float underwaterBrightness = 1.15;
color.rgb *= underwaterBrightness;


	// reduce banding
	int2 pix = int2(IN.UVCoord.xy / TESR_ReciprocalResolution.xy);
	color = delinearize(color);
	color.rgb += ditherMat[pix.x % 4][pix.y % 4] / 255.0;
	
	
	
    return float4(color.rgb, 1);
}

float4 WaterDistortion( VSOUT IN ) : COLOR0 {
	
	float depth = readDepth(IN.UVCoord);
    float3 eyeVector = toWorld(IN.UVCoord);
	float3 eyeDirection = normalize(eyeVector);
    float3 worldPos = TESR_CameraPosition.xyz + eyeVector * depth;
	float4 color = tex2D(TESR_SourceBuffer, IN.UVCoord);
	if (aboveWater(TESR_CameraPosition.z, worldPos.z, TESR_WaterSettings.x, depth)) return color;
	
	IN.UVCoord.x += sin(frame * 3 + IN.UVCoord.x * 60) * 0.001f;
	IN.UVCoord.y += cos(frame * 3 + IN.UVCoord.y * 60) * 0.001f;
	color = tex2D(TESR_RenderedBuffer, IN.UVCoord);
	color.a = 1;
	return color;
}

technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Godrays();
	}
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Blur(TESR_RenderedBuffer, OffsetMaskV, 2, 0.5);
	}
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Blur(TESR_RenderedBuffer, OffsetMaskH, 2, 0.5);
	}
	
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Water();
	}
	
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 WaterDistortion();
	}	
}		