// Lens Shader For TESReloaded
// Sun / light-driven dirt / window smudge overlay.
//
// EXTERIORS: the dirt is revealed by glare from the sun's REAL screen position:
//  - looking away from the sun            -> dirt hidden
//  - sun in frame / near frame edge       -> dirt appears around the sun, strongest looking straight at it
//  - sun hidden by clouds / geometry      -> dirt fades out
//  - night (no sun)                       -> dirt hidden
//
// INTERIORS (and night): the sun is ignored. Uses the ORIGINAL bloom-based method: the dirt shows wherever
// the bloom buffer is bright (lamps, candles, fires, windows), tinted by the colour of that light,
// with the strength/threshold/contrast coming from TESR_LensData. No visible light -> no dirt.
//--------------------------------------------------

float4 TESR_ReciprocalResolution;
float4 TESR_CinemaSettings; //x: dirtlens opacity, y:grainAmount, z:chromatic aberration strength 
float4 TESR_SunColor;
float4 TESR_SunAmbient;
float4 TESR_SunAmount;      // x: daylight amount (used to hide the effect at night)
float4 TESR_SunDirection;   // xyz: sun direction in world space (as used by the Godrays effect)
float4x4 TESR_ViewTransform;
float4x4 TESR_ProjectionTransform;
float4 TESR_LensData; // x: lens strength, y: falloff curve (higher = tighter around the sun), z: dirt contrast
float4 TESR_ShadowFormatData; // z: 1 = exterior, 0 = interior (only read when INTERIOR_MODE is 2)
float4 TESR_DebugVar;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_SourceBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_BloomBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_LensSampler : register(s3) < string ResourceName = "Effects\dirtlens.png"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

//--------------------------------------------------
// Tweakables
//--------------------------------------------------
#define DEBUG_VIEW         0      // 0 = off, 1 = show reveal mask, 2 = show computed sun position (red dot) + mask, 3 = show interior/exterior detection (green = exterior, red = interior)
#define MATRIX_TRANSPOSED  0      // set to 1 if the red dot in DEBUG_VIEW 2 moves the wrong way when you turn the camera
#define FLIP_SUN_Y         0      // set to 1 if the red dot moves up/down opposite to the real sun

// ---- Interiors: uses the ORIGINAL bloom-driven lens method (any bright light source, sun ignored) ----
// Strength / threshold / contrast come from TESR_LensData (x = strength, y = threshold curve, z = dirt contrast),
// so whatever you configured for interiors in the TESReloaded settings applies here.
#define INTERIOR_MODE      3      // 0 = always sun mode (exterior behaviour)
                                  // 1 = always interior/light mode (original bloom method)
                                  // 2 = auto via TESR_ShadowFormatData.z (1 = exterior, 0 = interior; may not exist in every build)
                                  // 3 = auto via screen brightness: bright daytime view = sun mode, dark scene with lights (interior or night) = light mode
#define AMBIENT_LOW        0.10   // mode 3: average bloom brightness under which the scene counts as fully "interior"
#define AMBIENT_HIGH       0.25   // mode 3: average bloom brightness above which the scene counts as fully "exterior"
#define INTERIOR_STRENGTH  1.0    // extra multiplier for the interior effect (1.0 = exactly like the original shader)

#define GLARE_NEAR         0.30   // tight glare radius around the sun (in screen heights)
#define GLARE_FAR          0.90   // wide glare falloff, lets dirt show across the frame when the sun is close to the edge
#define GLARE_NEAR_WEIGHT  0.65   // balance between the tight and wide glare (1 = tight only)
#define FACING_START       0.05   // sun direction z (view space) where the sun starts to count as "in front"
#define FACING_END         0.55   // ...and where it counts fully (looking straight at it = 1.0)

#define BRIGHT_LOW         0.35   // scene brightness below this reduces the dirt
#define BRIGHT_HIGH        0.90   // scene brightness above this = full dirt
#define BRIGHT_FLOOR       0.35   // minimum dirt strength in dark areas that are near the sun (silhouettes against the sun)
#define HALO_RADIUS        40.0   // px, sample radius used to measure local brightness

#define SUN_VIS_LOW        0.55   // luma at the sun position under which it is considered blocked
#define SUN_VIS_HIGH       0.95   // luma at the sun position at which it is considered fully visible
#define USE_SUN_AMOUNT     1      // 1 = hide at night using TESR_SunAmount.x (set 0 if everything disappears)

#define DIRT_SOFTNESS      0.5    // 0 = sharp smudges, 1 = out of focus glass
#define DIRT_MIP           3.0
#define DIRT_COLOR_AMOUNT  1.0    // 0 = grayscale dirt, 1 = full colours of the png
#define DIRT_SATURATION    1.0    // >1 = more vivid colours, <1 = more muted
#define SUN_TINT           0.25   // how much the sun colour tints the dirt (lower = png colours stay truer)
#define GLOBAL_SUBTLETY    0.6    // overall intensity, lower = subtler

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

#include "Includes/Helpers.hlsl"

static const float3 lumaW = float3(0.2126, 0.7152, 0.0722);

static const float2 ringDirs[8] =
{
	float2( 1.0,  0.0), float2(-1.0,  0.0), float2( 0.0,  1.0), float2( 0.0, -1.0),
	float2( 0.7071,  0.7071), float2(-0.7071,  0.7071), float2( 0.7071, -0.7071), float2(-0.7071, -0.7071)
};

float SceneLuma(float2 uv)
{
	return dot(tex2D(TESR_SourceBuffer, uv).rgb, lumaW);
}

float4 Lens(VSOUT IN) : COLOR0 
{
	float2 uv = IN.UVCoord;
	float4 color = linearize(tex2D(TESR_SourceBuffer, uv));
	float aspect = TESR_ReciprocalResolution.y / TESR_ReciprocalResolution.x;

	// ---- 1. Where is the sun on screen? ---------------------------------------
	float3 sunW = normalize(TESR_SunDirection.xyz);
#if MATRIX_TRANSPOSED
	float3 sunV = mul(TESR_ViewTransform, float4(sunW, 0)).xyz;
	float4 sunClip = mul(TESR_ProjectionTransform, float4(sunV, 1));
#else
	float3 sunV = mul(float4(sunW, 0), TESR_ViewTransform).xyz;
	float4 sunClip = mul(float4(sunV, 1), TESR_ProjectionTransform);
#endif
	sunV = normalize(sunV);

	float2 sunNDC = sunClip.xy / (abs(sunClip.w) + 0.00001);
#if FLIP_SUN_Y
	sunNDC.y = -sunNDC.y;
#endif
	float2 sunUV = float2(0.5 + 0.5 * sunNDC.x, 0.5 - 0.5 * sunNDC.y);

	// Sun must be in front of the camera; 1.0 when looking straight at it
	float facing = smoothstep(FACING_START, FACING_END, sunV.z);

	// ---- 2. Glare around the sun ------------------------------------------------
	float2 d = (uv - sunUV) * float2(aspect, 1.0);
	float dist = length(d);
	float glareNear = exp(-(dist * dist) / (GLARE_NEAR * GLARE_NEAR));
	float glareFar = exp(-dist / GLARE_FAR);
	float glare = lerp(glareFar, glareNear, GLARE_NEAR_WEIGHT) * facing;

	// ---- 3. Is the sun actually visible (not behind clouds / geometry)? --------
	float2 sunSampleUV = saturate(sunUV);
	float sunLuma = SceneLuma(sunSampleUV);
	sunLuma += SceneLuma(sunSampleUV + float2( 0.01, 0.0));
	sunLuma += SceneLuma(sunSampleUV + float2(-0.01, 0.0));
	sunLuma += SceneLuma(sunSampleUV + float2(0.0,  0.01 * aspect));
	sunLuma += SceneLuma(sunSampleUV + float2(0.0, -0.01 * aspect));
	sunLuma *= 0.2;
	float sunVisOnScreen = smoothstep(SUN_VIS_LOW, SUN_VIS_HIGH, sunLuma);

	// Sun outside the frame can't be measured: assume visible, glare then falls off with distance
	float2 off = abs(sunUV - 0.5) * 2.0;
	float outside = smoothstep(0.9, 1.1, max(off.x, off.y));
	float sunVis = lerp(sunVisOnScreen, 1.0, outside);

#if USE_SUN_AMOUNT
	sunVis *= smoothstep(0.1, 0.6, TESR_SunAmount.x);
#endif

	// ---- 4. Local brightness: dirt shows more where light actually is ----------
	float local = SceneLuma(uv);
	float2 step = TESR_ReciprocalResolution.xy * HALO_RADIUS;
	float halo = 0;
	[unroll]
	for (int i = 0; i < 8; i++)
		halo += SceneLuma(uv + ringDirs[i] * step);
	halo /= 8.0;
	float bright = smoothstep(BRIGHT_LOW, BRIGHT_HIGH, max(local, halo));
	bright = lerp(BRIGHT_FLOOR, 1.0, bright);

	// ---- 5. Interior: original bloom-driven method --------------------------------
	// Dirt appears wherever the bloom buffer says there is light, coloured by that light.
	float4 bloomI = tex2D(TESR_BloomBuffer, uv);
	float bloomLumaI = luma(bloomI);
	float lightMask = pows(bloomLumaI, TESR_LensData.y);
	float3 lightTint = max(bloomI.rgb, 0) / max(bloomLumaI, 0.0001);

	// Interior / exterior weight
	float ambient = 0;
#if INTERIOR_MODE == 0
	float interior = 0;
#elif INTERIOR_MODE == 1
	float interior = 1;
#elif INTERIOR_MODE == 2
	float interior = 1.0 - saturate(TESR_ShadowFormatData.z);
#else
	// Mode 3: judge from the screen itself. A daytime exterior fills the view with bright sky/ground,
	// so the average bloom brightness is high. An interior (or a night scene) is mostly dark with a few lights.
	[unroll]
	for (int ax = 0; ax < 4; ax++)
	{
		[unroll]
		for (int ay = 0; ay < 3; ay++)
			ambient += luma(tex2D(TESR_BloomBuffer, float2((ax + 0.5) / 4.0, (ay + 0.5) / 3.0)));
	}
	ambient /= 12.0;
	float exterior = smoothstep(AMBIENT_LOW, AMBIENT_HIGH, ambient);
#if USE_SUN_AMOUNT
	exterior *= smoothstep(0.1, 0.6, TESR_SunAmount.x); // at night the sun is gone, so lights take over
#endif
	float interior = 1.0 - exterior;
#endif

	// ---- 6. Final reveal mask ---------------------------------------------------
	float sunReveal = pows(saturate(glare * sunVis * bright), max(TESR_LensData.y, 0.01));
	float reveal = lerp(sunReveal, saturate(lightMask), interior);

#if DEBUG_VIEW == 1
	return float4(reveal, reveal, reveal, 1);
#endif
#if DEBUG_VIEW == 2
	float marker = 1.0 - smoothstep(0.008, 0.012, dist);
	return float4(saturate(reveal + marker), reveal, reveal * (1 - marker), 1) * (sunV.z > 0 ? 1 : 0.2);
#endif
#if DEBUG_VIEW == 3
	// red = interior weight, green = exterior weight, blue = measured average bloom brightness (mode 3)
	return float4(interior, 1.0 - interior, saturate(ambient), 1);
#endif

	// ---- 6. The dirt itself -----------------------------------------------------
	float3 dirtSharp = tex2D(TESR_LensSampler, uv).rgb;
	float3 dirtSoft = tex2Dlod(TESR_LensSampler, float4(uv, 0, DIRT_MIP)).rgb;
	float3 dirt = lerp(dirtSharp, dirtSoft, DIRT_SOFTNESS);

	// Contrast curve applied per channel so the colours of the png are preserved
	dirt = pow(max(dirt, 0.0001), max(0, 3 - TESR_LensData.z));

	// Blend between grayscale (0) and the full colour of the png (1), plus optional saturation boost
	float dirtLuma = dot(dirt, lumaW);
	dirt = lerp(dirtLuma.xxx, dirt, DIRT_COLOR_AMOUNT);
	dirt = max(lerp(dirtLuma.xxx, dirt, DIRT_SATURATION), 0);

	float3 sunTint = lerp(float3(1, 1, 1), normalize(max(TESR_SunColor.rgb, 0.0001)) * 1.73, SUN_TINT);

	// Exterior: sun glare mask (tinted by the sun, scaled by GLOBAL_SUBTLETY)
	// Interior: original bloom mask (tinted by the light itself)
	float3 exteriorMask = sunReveal * sunTint * GLOBAL_SUBTLETY;
	float3 interiorMask = lightMask * lightTint * INTERIOR_STRENGTH;
	float3 scatter = dirt * lerp(exteriorMask, interiorMask, interior) * TESR_LensData.x;

	// Screen blend: adds glow without harsh clipping
	color.rgb = 1.0 - (1.0 - saturate(color.rgb)) * (1.0 - saturate(scatter));

	return delinearize(float4(color.rgb, 1));
}

technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 Lens();
	}
}
