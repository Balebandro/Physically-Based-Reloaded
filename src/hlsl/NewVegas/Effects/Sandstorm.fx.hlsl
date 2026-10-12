// Sandstorm, after Kappa's v5 weather update: wind-driven dust filling the air while the weather is a sandstorm
// (SandstormEffect::UpdateConstants, which also eases it in and out with the weather).
//
// Before tonemapping, in linear light, so the dust is lit on the same scale as the scene: the weather's own fog and
// ambient colours (a sandstorm weather's fog is already its dust) and the sun, scattered forward through the dust.
// Near the camera the view ray is marched through billowing clouds of dust that drift with the wind and thin with
// height; past that the storm is an even haze that swallows the distance and the sky. Thin streaks of sand blow past
// the camera on top.

float4 TESR_ReciprocalResolution;
float4 TESR_FogColor;
float4 TESR_SunColor;
float4 TESR_SunAmbient;
float4 TESR_SunPosition;
float4 TESR_SunAmount;      // x: daytime
float4 TESR_PBRData;        // z: direct light scale, w: ambient scale
float4 TESR_SandstormData;  // x: intensity, y: density per unit, z: visibility, w: height falloff
float4 TESR_SandstormWind;  // xy: wind direction, z: speed (units/s), w: time (s)
float4 TESR_SandstormShape; // x: billowing, y: noise scale, z: streaks, w: sun scattering
float4 TESR_SandstormColor; // rgb: sand albedo, w: brightness
float4 TESR_SandstormCover; // x: the ortho map is there
float4 TESR_SandstormLights;     // x: how strongly the nearby lights glow through the dust (0 off)
float4 TESR_SandstormEmissive;   // x: EmissiveThreshold (0 off), y: EmissiveDistance
float4 TESR_LightPosition[12];       // NVR's nearby lights (ShaderManager::GetNearbyLights): world position, w radius
float4 TESR_ShadowLightPosition[12]; // the shadow-casting ones
float4 TESR_LightColor[24];          // rgb, w dimmer: the shadow-casting lights first, then the others
float4 TESR_ShadowFade;            // y: the sun shadow maps are there
float4x4 TESR_ShadowCameraToLightTransformOrtho;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_OrthoMapBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_ShadowAtlas : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Shadows.hlsl"

static const int Steps = 12;

struct VSOUT
{
	float4 vertPos : POSITION;
	float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN)
{
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

// Hash and value noise without sin, so they stay precise far from the world's origin.
float hash13(float3 p)
{
	p = frac(p * 0.1031f);
	p += dot(p, p.zyx + 31.32f);
	return frac((p.x + p.y) * p.z);
}

float valueNoise(float3 x)
{
	float3 i = floor(x);
	float3 f = frac(x);
	f = f * f * (3.0f - 2.0f * f);
	return lerp(lerp(lerp(hash13(i), hash13(i + float3(1, 0, 0)), f.x),
	                 lerp(hash13(i + float3(0, 1, 0)), hash13(i + float3(1, 1, 0)), f.x), f.y),
	            lerp(lerp(hash13(i + float3(0, 0, 1)), hash13(i + float3(1, 0, 1)), f.x),
	                 lerp(hash13(i + float3(0, 1, 1)), hash13(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(float3 p)
{
	return valueNoise(p) * 0.55f + valueNoise(p * 2.03f + 17.1f) * 0.3f + valueNoise(p * 4.01f + 41.7f) * 0.15f;
}

// Henyey-Greenstein: how much light the dust scatters toward the eye, g > 0 forward.
float phase(float cosTheta, float g)
{
	float g2 = g * g;
	return (1.0f - g2) / (4.0f * 3.14159265f * pow(max(1.0f + g2 - 2.0f * g * cosTheta, 1e-4f), 1.5f));
}

// --- The sun's visibility through the dust: NVR's sun shadow cascades, as VolumetricLight.fx.hlsl reads them (copied:
// effects compile on their own). Dust in the shadow of a wall, a rock or a building scatters no sunlight.
float4x4 TESR_ShadowCameraToLightTransformNear;
float4x4 TESR_ShadowCameraToLightTransformMiddle;
float4x4 TESR_ShadowCameraToLightTransformFar;
float4x4 TESR_ShadowCameraToLightTransformLod;
float4 TESR_ShadowFormatData; // x: mode, y: format bits

// A cascade's map is a slab along the sun; outside it there is nothing to go on.
bool OutsideShadowMap(float3 projected)
{
	return max(max(abs(projected.x), abs(projected.y)), abs(projected.z * 2.0f - 1.0f)) > 1.0f;
}

float BleedReduction(float amount)
{
	return TESR_ShadowFormatData.y == 0.0f ? lerp(amount, 0.9f, 0.45f) : amount;
}

// One cascade's verdict, or -1 when the point is not in its map.
float TryCascade(float4x4 lightTransform, float4 coord, float offsetX, float offsetY, float bias, float bleedReduction)
{
	float4 projected = mul(coord, lightTransform);
	projected.xyz /= projected.w;
	if (OutsideShadowMap(projected.xyz)) return -1.0f;
	float4 lightSpace = float4(projected.x * 0.5f + 0.5f, projected.y * -0.5f + 0.5f, projected.z, 1.0f);
	lightSpace.xy = lightSpace.xy * 0.5f + float2(offsetX, offsetY);
	float4 moments = tex2Dlod(TESR_ShadowAtlas, float4(lightSpace.xy, 0.0f, 0.0f));
	[branch] if (TESR_ShadowFormatData.x == 0.0f)
		return GetLightAmountValueVSM(moments.xy, lightSpace.z, bias, bleedReduction);
	else if (TESR_ShadowFormatData.x == 1.0f)
		return GetLightAmountValueEVSM2(moments.xy, lightSpace.z, bias, bleedReduction, TESR_ShadowFormatData.y);
	else
		return GetLightAmountValueEVSM4(moments, lightSpace.z, bias, bleedReduction, TESR_ShadowFormatData.y);
}

// How much a point near the camera (camera-relative) sees the sun: 1 lit, 0 in shadow, 1 out of the shadow maps' reach.
float SunVisibility(float3 relative)
{
	if (!TESR_ShadowFade.y) return 1.0f;
	float bias = TESR_ShadowFormatData.x == 0.0f ? 0.00001f : 0.01f;
	float4 coord = float4(relative, 1.0f);
	float shadow = TryCascade(TESR_ShadowCameraToLightTransformNear, coord, 0.0f, 0.0f, bias, BleedReduction(0.1f));
	if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformMiddle, coord, 0.5f, 0.0f, bias, BleedReduction(0.2f));
	if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformFar, coord, 0.0f, 0.5f, bias, BleedReduction(0.6f));
	if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformLod, coord, 0.5f, 0.5f, bias, BleedReduction(0.8f));
	return shadow < 0.0f ? 1.0f : saturate(shadow);
}


// Whether anything stands above a point near the camera (camera-relative), by NVR's top-down depth map: 0 if
// something does, 1 in the open. InTheWind asks it upwind of the point. Out of the map's reach, or without it, counts as open.
float OpenAbove(float3 relative)
{
	[branch] if (TESR_SandstormCover.x < 0.5f) return 1.0f;
	float4 ortho = mul(float4(relative, 1.0f), TESR_ShadowCameraToLightTransformOrtho);
	ortho.xyz /= ortho.w;
	if (abs(ortho.x) > 1.0f || abs(ortho.y) > 1.0f || ortho.z < 0.0f || ortho.z > 1.0f) return 1.0f;
	float top = tex2Dlod(TESR_OrthoMapBuffer, float4(ortho.x * 0.5f + 0.5f, ortho.y * -0.5f + 0.5f, 0.0f, 0.0f)).r;
	return top > ortho.z - 0.0001f;
}

// Whether the wind reaches a point near the camera, or something upwind (a wall, a rock, a building) puts it in the
// lee. A wind shadow runs about five times as far as the obstacle is tall, so looking k units upwind, only something
// standing more than k / 5 above the point shelters it: a low rock a short way, a cliff a long way. What is overhead
// does not matter (sand blows in under roofs).
static const float LeeReach[8] = { 50.0f, 110.0f, 190.0f, 290.0f, 410.0f, 550.0f, 710.0f, 900.0f };

float InTheWind(float3 relative, float2 wind)
{
	float reached = 1.0f;
	[unroll] for (int k = 0; k < 8; k++)
		reached *= OpenAbove(relative + float3(-wind * LeeReach[k], LeeReach[k] * 0.2f));
	return reached;
}

// The same, coarser (every other reach), for the dust near the camera where it is asked many times per pixel.
float InTheWindCoarse(float3 relative, float2 wind)
{
	float reached = 1.0f;
	[unroll] for (int k = 1; k < 8; k += 2)
		reached *= OpenAbove(relative + float3(-wind * LeeReach[k], LeeReach[k] * 0.2f));
	return reached;
}


// How far along the view ray a pixel's surface is; the sky lies well beyond what the storm lets through.
float ViewDistance(float2 coord, float visibility)
{
	float depth = readDepth(coord);
	if (depth / farZ >= 0.9961f) return visibility * 6.0f;
	return length(toWorld(coord) * depth);
}

// The glow of a point light through the dust: the light it scatters toward the eye along the whole view ray up to the
// surface, in closed form (the single-scattering integral of an inverse-square light along a line, Sun et al. 2005's
// airlight). Behind a wall it stops at the wall; it dims by the dust between the eye and the light. The core is softened
// over a tenth of the light's radius so it never blows out.
// light: xyz world position, w radius; color: rgb, w dimmer (as the game gives them).
float3 PointGlow(float4 light, float4 color, float3 camera, float3 dir, float distance, float density) {
    [branch] if (light.w <= 0.0f || color.w <= 0.0f) return 0.0f;
    float3 toLight = light.xyz - camera;
    float along = dot(toLight, dir);
    float across = sqrt(max(dot(toLight, toLight) - along * along, 0.0f) + light.w * light.w * 0.01f);
    float swept = (atan((distance - along) / across) + atan(along / across)) / across;
    float through = exp(-density * clamp(along, 0.0f, distance));
    return linearize(color.rgb) * color.w * light.w * light.w * swept * through;
}


float4 SandstormPS(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;
	float4 color = linearize(tex2D(TESR_RenderedBuffer, uv));

	float intensity = TESR_SandstormData.x;
	float density = TESR_SandstormData.y * intensity;
	float visibility = TESR_SandstormData.z;
	float heightFalloff = TESR_SandstormData.w;
	float time = TESR_SandstormWind.w;
	float2 wind = TESR_SandstormWind.xy;
	float speed = TESR_SandstormWind.z;
	float billowing = TESR_SandstormShape.x;
	float noiseScale = TESR_SandstormShape.y;

	float3 dir = normalize(toWorld(uv));

	// How far the dust runs before the pixel's surface, from a 3x3 tent of taps around it (5 pixels across) averaged as how much
	// of the scene shows through. A half-transparent edge (hair, foliage, a fringe drawn with blending) holds the
	// colour of what is behind it, undusted, but only the near surface's depth: on its own depth it got no dust and
	// showed as a dark rim. Averaged, it gets about as much as the mix of the two it shows. Even surfaces are unchanged.
	float fullDensity = max(TESR_SandstormData.y, 1e-6f);
	float2 texel = TESR_ReciprocalResolution.xy * 2.0f;   // taps two pixels apart: hair fringes run a few pixels wide
	float shown = 0.0f;
	[unroll] for (int y = -1; y <= 1; y++)
		[unroll] for (int x = -1; x <= 1; x++)
			shown += (2 - abs(x)) * (2 - abs(y)) * exp(-ViewDistance(uv + float2(x, y) * texel, visibility) * fullDensity);
	float distance = min(-log(max(shown / 16.0f, 1e-9f)) / fullDensity, visibility * 6.0f);
	float3 camera = TESR_CameraPosition.xyz;

	// The light on the dust: the weather's fog colour and ambient all round, the sun scattered forward.
	float daytime = smoothstep(0.1f, 0.6f, TESR_SunAmount.x);
	float3 ambient = (linearize(TESR_FogColor.rgb) * 0.6f + linearize(TESR_SunAmbient.rgb) * 0.4f) * TESR_PBRData.w;
	float3 sunLight = linearize(TESR_SunColor.rgb) * TESR_PBRData.z * daytime;
	float sunPhase = phase(dot(dir, normalize(TESR_SunPosition.xyz)), 0.55f) * 4.0f * 3.14159265f;
	// Ambient and sun kept apart: the sun's share is shadowed wherever the dust is (SunVisibility).
	float3 dustAmbient = TESR_SandstormColor.rgb * ambient * TESR_SandstormColor.w;
	float3 dustSun = TESR_SandstormColor.rgb * sunLight * lerp(0.35f, sunPhase, saturate(TESR_SandstormShape.w * 0.5f)) * max(TESR_SandstormShape.w, 0.25f)
		* TESR_SandstormColor.w;
	float3 dustLight = dustAmbient + dustSun;   // out in the open

	// The wind carries the dust; it also rolls slowly upward.
	float3 drift = float3(wind * speed * time, -speed * 0.05f * time);
	float jitter = frac(52.9829189f * frac(dot(uv / TESR_ReciprocalResolution.xy, float2(0.06711056f, 0.00583715f))) + time * 7.123f);

	// Billowing dust, marched through the first stretch of the ray (steps closer together near the camera).
	float marchEnd = min(distance, visibility * 1.5f);
	float transmittance = 1.0f;
	float3 scattered = 0.0f;
	// The same, only as far as EmissiveDistance: what an emissive effect drawn without depth (fire, sparks) is seen through.
	float nearCut = TESR_SandstormEmissive.y;
	float nearTransmittance = 1.0f;
	float3 nearScattered = 0.0f;
	[loop] for (int i = 0; i < Steps; i++) {
		float t0 = marchEnd * pow((i + jitter) / Steps, 2.0f);
		float t1 = marchEnd * pow(min(i + 1 + jitter, Steps) / Steps, 2.0f);
		float3 p = camera + dir * (0.5f * (t0 + t1));
		float height = exp(-max(p.z - camera.z + 200.0f, 0.0f) / heightFalloff);
		float clouds = fbm((p - drift) / noiseScale);
		float local = density * height * lerp(1.0f, saturate(clouds * 2.2f - 0.35f) * 1.8f, billowing) * (t1 - t0);
		// In the lee of a wall or a rock the air near the camera is calmer: some dust hangs in it, less blows through.
		float middle = 0.5f * (t0 + t1);
		[branch] if (middle < 500.0f) local *= lerp(lerp(0.35f, 1.0f, InTheWindCoarse(dir * middle, wind)), 1.0f, smoothstep(350.0f, 500.0f, middle));
		float absorbed = 1.0f - exp(-local);
		float3 light = dustAmbient + dustSun * SunVisibility(dir * middle);
		scattered += transmittance * absorbed * light * (0.8f + 0.4f * clouds);
		transmittance *= 1.0f - absorbed;
		float nearShare = saturate((nearCut - t0) / max(t1 - t0, 1e-3f));
		float nearAbsorbed = 1.0f - exp(-local * nearShare);
		nearScattered += nearTransmittance * nearAbsorbed * light * (0.8f + 0.4f * clouds);
		nearTransmittance *= 1.0f - nearAbsorbed;
	}

	// Beyond the march: an even haze to the scene, or the sky, behind it.
	float endHeight = exp(-max(dir.z * marchEnd + 200.0f, 0.0f) / heightFalloff);
	float haze = 1.0f - exp(-max(distance - marchEnd, 0.0f) * density * lerp(endHeight, 1.0f, 0.5f));
	scattered += transmittance * haze * dustLight;
	transmittance *= 1.0f - haze;
	float3 dustScattered = scattered;   // the dust alone; what follows (streaks, light glow) is in front of anything

	// Streaks: thin sand blown past the camera, stretched along the wind. Only where nothing nearer is in the way, fading
	// out before the surface behind, and where the wind reaches (InTheWind): none in the lee of a wall or a rock.
	float3 streaks = 0.0f;
	float2 across = float2(-wind.y, wind.x);
	[unroll] for (int s = 0; s < 3; s++) {
		float t = 50.0f + 120.0f * s + 30.0f * jitter;
		if (t < distance) {
			float3 p = camera + dir * t - float3(wind * speed * time * (2.5f + s), 0.0f);
			float3 q = float3(dot(p.xy, wind) / 240.0f, dot(p.xy, across) / 8.0f, p.z / 6.0f);
			float visible = saturate((distance - t) / 60.0f) * InTheWind(dir * t, wind);
			float grain = smoothstep(0.74f, 0.96f, valueNoise(q + s * 31.7f)) * (1.0f - s * 0.25f) * visible;
			[branch] if (grain > 0.0f) streaks += grain * (dustAmbient + dustSun * SunVisibility(dir * t));
		}
	}
	scattered += streaks * TESR_SandstormShape.z * intensity * 0.25f;

	// The nearby lights glowing through the dust, as the sun does (lamps, fires, signs).
	[branch] if (TESR_SandstormLights.x > 0.0f) {
		float3 glow = 0.0f;
		[loop] for (int l = 0; l < 12; l++) {
			glow += PointGlow(TESR_ShadowLightPosition[l], TESR_LightColor[l], camera, dir, distance, density);
			glow += PointGlow(TESR_LightPosition[l], TESR_LightColor[12 + l], camera, dir, distance, density);
		}
		scattered += glow * density * TESR_SandstormColor.rgb * TESR_SandstormLights.x * 0.01f;
	}

	float3 result = color.rgb * transmittance + scattered;

	// Fire, sparks and the like are drawn without depth, so the depth here is what lies behind them and they would sink
	// into the dust of that distance. A pixel far brighter than lit dust can be is taken as something glowing in front:
	// it gets only the dust within EmissiveDistance. The sky needs twice the margin, so a bright sky stays buried.
	float rawDepth = readDepth(uv);
	bool skyBehind = rawDepth / farZ >= 0.9961f;
	float emissive = 0.0f;
	[branch] if (TESR_SandstormEmissive.x > 0.0f) {
		float dustLuma = max(dot(dustLight, float3(0.2126f, 0.7152f, 0.0722f)), 1e-4f) * TESR_SandstormEmissive.x * (skyBehind ? 2.0f : 1.0f);
		emissive = saturate((dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f)) - dustLuma) / dustLuma);
		float3 nearResult = color.rgb * nearTransmittance + nearScattered + (scattered - dustScattered);
		result = lerp(result, nearResult, emissive);
	}
	return delinearize(float4(result, color.a));
}

technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 SandstormPS();
	}
}
