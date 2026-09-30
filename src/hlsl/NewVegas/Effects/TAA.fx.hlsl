// =================================================================================================
//  CREDIT: TAA for New Vegas Reloaded by Conor.
//  Upstream sources and references are credited below.
// =================================================================================================

// Temporal anti-aliasing: temporal accumulation with reprojection, over a sub-pixel-jittered world.
//
// Ported from Oblivion Reloaded E3 (arafuse/tes-reloaded, OblivionReloaded/Shaders/TAA/TAA.fx.hlsl),
// which builds on:
//   https://github.com/TheRealMJP/MSAAFilter (Catmull-Rom history filter, MIT licence)
//   https://www.elopezr.com/temporal-aa-and-the-quest-for-the-holy-trail/
// Variance clipping in YCoCg follows Salvi, "An Excursion in Temporal Supersampling" (GDC 2016),
// and the AABB clip follows Playdead's INSIDE TAA (Pedersen, GDC 2016).
//
// Each frame blends the current image with the previous TAA result, fetched from where this
// pixel's surface was on screen last frame. The world is rendered through a projection shifted by a
// different fraction of a pixel each frame (TAAEffect::BeginJitter), so successive frames sample
// each pixel at different points inside it, and averaging them recovers the partial coverage a
// single sample per pixel cannot see -- anti-aliasing, including on a still image. Motion adds more
// of the same, which is why edges that crawl as the camera moves settle too.
//
// The reprojection below deliberately ignores that jitter. It reconstructs with toWorld, which
// reads only the projection's _11/_22 scale and none of its _31/_32 offset, and last frame's camera
// is stored the same way. That is what motion vectors must do: the current sample is SUPPOSED to
// sit at this frame's sub-pixel offset inside the pixel -- that is the sample being accumulated --
// while the history lives on the steady pixel grid. Folding the jitter into the reprojection would
// give a still camera non-zero motion, and the image would drift and blur. (By the time TAA runs,
// NVR's matrices have been restored to the unjittered camera anyway.)
//
// What changed from the ORL original, and why:
//   - Reconstruction. ORL decodes its own depth format. This uses NVR's, and reprojects by
//     inverting the exact reconstruction NVR's shipping effects use (CameraPosition +
//     toWorld(uv) * readDepth(uv)), so a static camera maps every pixel onto itself.
//   - Last frame's camera goes in as a rotation, two projection scales and a position DELTA.
//     The view matrix's translation is deliberately not used: it is built from the game global
//     CameraLocation, while TESR_CameraPosition comes from the camera node's world translate,
//     and nothing here establishes that those agree. The delta is also computed on the CPU, so
//     no absolute world coordinate -- which can run to six figures in FNV worldspaces -- ever
//     reaches the shader to lose precision in a subtraction.
//   - The first-person weapon. It moves with the camera, so reprojecting it as world geometry
//     smears it every time the view turns -- the classic TAA complaint in first-person games.
//     Its pixels are identified with the same test CombineDepth uses (a non-zero viewmodel depth,
//     reversed depth so zero is cleared) and reprojected with zero motion.
//   - Neighbourhood clamp. ORL clamps to an RGB min/max box whose radius shrinks to 0.15 px near
//     the camera. This clips to a variance box in YCoCg, which rejects stale history more
//     precisely and shifts colour less, with integer loops -- ORL's float loop counters are the
//     construct that has crashed the D3DX compiler in this codebase before.
//   - History validity. ORL blends whatever the history buffer holds. On the first frame, after
//     a cell change or after the effect is re-enabled, that is garbage or a different place;
//     TESR_TAAData.z tells this shader to ignore it.

float4 TESR_ReciprocalResolution;      // x: 1 / width, y: 1 / height
float4 TESR_TAAData;                   // x: history weight, y: clip gamma, z: history valid (0/1), w: debug view (0 = off)
float4 TESR_TAAPrevProjection;         // x: last frame's projection _11, y: its _22
float4 TESR_TAACameraDelta;            // xyz: camera position this frame minus last frame's
float4x4 TESR_TAAPrevViewTransform;    // last frame's TESR_ViewTransform; only its rotation is read
float4 TESR_TAAWeapon;                 // x: history weight scale on first-person weapon pixels (WeaponTAA)

// POINT: the neighbourhood below reads exact texels.
sampler2D TESR_SourceBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
// LINEAR: the Catmull-Rom filter gets its middle taps from bilinear fetches.
sampler2D TESR_TAAHistoryBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D TESR_DepthBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_DepthBufferViewModel : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

#include "Includes/Depth.hlsl"

static const float historyWeight = TESR_TAAData.x;
static const float clipGamma = TESR_TAAData.y;
static const float historyValid = TESR_TAAData.z;
static const float debugView = TESR_TAAData.w;
static const float weaponHistoryScale = TESR_TAAWeapon.x;

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

float3 RGBToYCoCg(float3 c)
{
	return float3(0.25f * c.r + 0.5f * c.g + 0.25f * c.b,
	              0.5f * c.r - 0.5f * c.b,
	             -0.25f * c.r + 0.5f * c.g - 0.25f * c.b);
}

float3 YCoCgToRGB(float3 c)
{
	return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Where this pixel's surface was on screen last frame.
//
// This inverts NVR's reconstruction. toWorld(uv) returns F + a*R + b*U, with R, U, F the camera's
// right, up and forward axes, a = (2u - 1) / P._11 and b = -(2v - 1) / P._22, so the surface sits
// at depth * toWorld(uv) from the camera. Expressing that point against last frame's axes and
// running the same relations backwards gives last frame's uv. When nothing moved, that is uv.
float2 Reproject(float2 uv, out float inFront)
{
	float3 cameraVector = toWorld(uv) * readDepth(uv);
	float3 fromPrevCamera = cameraVector + TESR_TAACameraDelta.xyz;

	// Same axis layout toWorld reads out of TESR_ViewTransform.
	float3 prevRight   = float3(TESR_TAAPrevViewTransform[0][0], TESR_TAAPrevViewTransform[1][0], TESR_TAAPrevViewTransform[2][0]);
	float3 prevUp      = float3(TESR_TAAPrevViewTransform[0][1], TESR_TAAPrevViewTransform[1][1], TESR_TAAPrevViewTransform[2][1]);
	float3 prevForward = float3(TESR_TAAPrevViewTransform[0][2], TESR_TAAPrevViewTransform[1][2], TESR_TAAPrevViewTransform[2][2]);

	float viewZ = dot(fromPrevCamera, prevForward);
	inFront = viewZ > 0.0f ? 1.0f : 0.0f;

	float2 ndc = float2(dot(fromPrevCamera, prevRight) * TESR_TAAPrevProjection.x,
	                    dot(fromPrevCamera, prevUp) * TESR_TAAPrevProjection.y) / max(viewZ, 1e-4f);
	return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
}

// Catmull-Rom filtered history fetch in 5 taps instead of 16. After MJP (MIT licence):
// https://gist.github.com/TheRealMJP/bc503b0b87b643d3505d41eab8b332ae (the link ORL credits)
//
// MJP's version is 9 bilinear taps; the four corner ones are dropped here and the rest renormalised,
// as Jimenez's Filmic SMAA does. A corner's weight is the product of two outer lobes, at most about
// half a percent of the total, and exactly zero when the history is read at a texel centre -- a still
// camera -- so that case is unchanged and moving ones differ far less than the clip moves them.
//
// Reprojected uvs almost never land on texel centres, and plain bilinear resampling blurs the
// history a little every frame -- compounded over the ~10 frames a 0.9 weight averages, that is
// visible softening in motion. Catmull-Rom keeps it sharp. It can overshoot at hard edges, which
// the clip in ResolvePS absorbs.
float3 SampleHistory(float2 uv)
{
	float2 texelSize = TESR_ReciprocalResolution.xy;
	float2 samplePos = uv / texelSize;
	float2 texPos1 = floor(samplePos - 0.5f) + 0.5f;
	float2 f = samplePos - texPos1;

	float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
	float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
	float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
	float2 w3 = f * f * (-0.5f + 0.5f * f);

	float2 w12 = w1 + w2;
	float2 offset12 = w2 / w12;

	float2 texPos0 = (texPos1 - 1.0f) * texelSize;
	float2 texPos3 = (texPos1 + 2.0f) * texelSize;
	float2 texPos12 = (texPos1 + offset12) * texelSize;

	float wTop    = w12.x * w0.y;
	float wLeft   = w0.x  * w12.y;
	float wCenter = w12.x * w12.y;
	float wRight  = w3.x  * w12.y;
	float wBottom = w12.x * w3.y;

	float3 result = 0.0f;
	result += tex2D(TESR_TAAHistoryBuffer, float2(texPos12.x, texPos0.y)).rgb  * wTop;
	result += tex2D(TESR_TAAHistoryBuffer, float2(texPos0.x,  texPos12.y)).rgb * wLeft;
	result += tex2D(TESR_TAAHistoryBuffer, float2(texPos12.x, texPos12.y)).rgb * wCenter;
	result += tex2D(TESR_TAAHistoryBuffer, float2(texPos3.x,  texPos12.y)).rgb * wRight;
	result += tex2D(TESR_TAAHistoryBuffer, float2(texPos12.x, texPos3.y)).rgb  * wBottom;

	return max(result / (wTop + wLeft + wCenter + wRight + wBottom), 0.0f);
}

// Pull the history toward the box centre until it lies inside the box. Clipping along the line
// to the centre, rather than clamping each channel on its own, keeps the history's hue instead of
// snapping it toward a box corner.
float3 ClipToBox(float3 history, float3 boxMin, float3 boxMax)
{
	float3 center = 0.5f * (boxMax + boxMin);
	float3 extents = 0.5f * (boxMax - boxMin) + 1e-4f;
	float3 offset = history - center;
	float3 units = abs(offset / extents);
	float maxUnit = max(units.x, max(units.y, units.z));
	return maxUnit > 1.0f ? center + offset / maxUnit : history;
}

// Everything the resolve computes, kept together so the debug views read the same values the real
// resolve used rather than a second copy of the maths that could drift from it.
struct TAAResult
{
	float3 color;         // final colour, RGB
	float3 current;       // this frame's colour at the pixel, RGB
	float3 historyRaw;    // reprojected history before clipping, RGB
	float2 motionPixels;  // where the pixel was last frame minus where it is now, in pixels
	float weight;         // history weight actually applied: 0 = rejected, up to HistoryWeight
	float clipAmount;     // how far clipping moved the history, in YCoCg
	float isViewModel;    // 1 on first-person weapon pixels
	float depth;          // linear view-space depth, game units
};

TAAResult ResolveCore(float2 uv)
{
	TAAResult result;
	float2 texelSize = TESR_ReciprocalResolution.xy;

	// Current-frame 3x3 neighbourhood in YCoCg: its range, and its mean and spread.
	float3 current = 0.0f;
	float3 moment1 = 0.0f;
	float3 moment2 = 0.0f;
	float3 neighbourMin = 1e5f;
	float3 neighbourMax = -1e5f;
	[unroll]
	for (int y = -1; y <= 1; y++) {
		[unroll]
		for (int x = -1; x <= 1; x++) {
			float3 c = RGBToYCoCg(tex2D(TESR_SourceBuffer, uv + float2(x, y) * texelSize).rgb);
			if (x == 0 && y == 0) current = c;
			moment1 += c;
			moment2 += c * c;
			neighbourMin = min(neighbourMin, c);
			neighbourMax = max(neighbourMax, c);
		}
	}
	moment1 /= 9.0f;
	moment2 /= 9.0f;
	float3 sigma = sqrt(max(moment2 - moment1 * moment1, 0.0f));

	// Variance box, never wider than the range actually present. The mean always sits inside
	// both, so the intersection cannot come out inverted.
	float3 boxMin = max(neighbourMin, moment1 - clipGamma * sigma);
	float3 boxMax = min(neighbourMax, moment1 + clipGamma * sigma);

	float inFront;
	float2 prevUV = Reproject(uv, inFront);

	// The weapon is fixed to the camera, so it was at this same pixel last frame.
	float isViewModel = tex2D(TESR_DepthBufferViewModel, uv).x > 0.0f ? 1.0f : 0.0f;
	prevUV = lerp(prevUV, uv, isViewModel);
	inFront = max(inFront, isViewModel);

	float2 inside = step(0.0f, prevUV) * step(prevUV, 1.0f);
	float onScreen = inside.x * inside.y;

	float3 historyRaw = SampleHistory(prevUV);
	float3 historyRawYCoCg = RGBToYCoCg(historyRaw);
	float3 history = ClipToBox(historyRawYCoCg, boxMin, boxMax);

	// A surface that was off screen or behind the camera last frame has no history to use, and
	// neither does anything on the first frame after a reset.
	float weight = historyWeight * historyValid * onScreen * inFront;

	// The weapon is not jittered, so history buys it no anti-aliasing -- only stability while it sways,
	// at the cost of some softening, because its own animation is motion zero-motion reprojection
	// cannot follow. WeaponTAA trades one against the other: 1 treats it like the world, 0 leaves it
	// exactly as rendered.
	weight *= lerp(1.0f, weaponHistoryScale, isViewModel);

	result.color = YCoCgToRGB(lerp(current, history, weight));
	result.current = YCoCgToRGB(current);
	result.historyRaw = historyRaw;
	result.motionPixels = (prevUV - uv) / texelSize;
	result.weight = weight;
	result.clipAmount = length(history - historyRawYCoCg);
	result.isViewModel = isViewModel;
	result.depth = readDepth(uv);
	return result;
}

float4 ResolvePS(VSOUT IN) : COLOR0
{
	return float4(ResolveCore(IN.UVCoord).color, 1.0f);
}

// Debug views, selected by DebugView in [_Shaders.TAA.Main]. Drawn to the screen in place of Output,
// BEFORE this frame's resolve is copied into the history -- so these see the same previous frame
// the real resolve saw, and the debug picture never becomes next frame's history.
//
//   1  Motion. Black = the pixel did not move. Red = horizontal motion, green = vertical, full
//      brightness at 16 pixels per frame. Standing still the whole frame must be black; turning
//      should give a smooth, even wash across the world while the weapon stays black. Blotches,
//      bands, or a weapon that lights up mean the reprojection is wrong.
//   2  Reprojection error. |reprojected history - current frame|, x4, before any clipping. THE
//      check for "does the image trail when I turn": while turning past static scenery this must
//      stay mostly dark, lit only along edges and where something newly came into view. A frame
//      that lights up everywhere -- a doubled image -- means last frame is being fetched from the
//      wrong place.
//   3  History use. Grey level = how much history was blended in (white = the full HistoryWeight,
//      black = rejected: off screen, behind the camera, or just after a reset). Red = how hard
//      clipping pulled the history in to stop a ghost -- expect it on moving NPCs and edges.
//   4  Weapon mask. The frame, darkened, with pixels treated as the first-person weapon in magenta.
//      Must cover the weapon and hands exactly, and nothing else.
//   5  Depth, as TAA reads it: log scale, black near, white at the far plane.
float4 DebugPS(VSOUT IN) : COLOR0
{
	TAAResult r = ResolveCore(IN.UVCoord);

	float3 motion = float3(saturate(abs(r.motionPixels) / 16.0f), 0.0f);
	float3 error = saturate(abs(r.historyRaw - r.current) * 4.0f);
	float3 historyUse = float3(saturate(r.weight + r.clipAmount * 8.0f), r.weight, r.weight);
	float3 weaponMask = lerp(r.current * 0.35f, float3(1.0f, 0.0f, 1.0f), r.isViewModel * 0.75f);
	float3 depth = saturate(log2(1.0f + r.depth) / log2(1.0f + farZ)).xxx;

	float3 view = r.color;
	view = debugView > 0.5f && debugView < 1.5f ? motion : view;
	view = debugView > 1.5f && debugView < 2.5f ? error : view;
	view = debugView > 2.5f && debugView < 3.5f ? historyUse : view;
	view = debugView > 3.5f && debugView < 4.5f ? weaponMask : view;
	view = debugView > 4.5f ? depth : view;
	return float4(view, 1.0f);
}

// Pixel shaders carry a PS suffix so no function shares a name with a technique -- every other
// effect in this codebase keeps the two distinct, and the Resolve and Output technique names are
// what TAAEffect looks up.
//
// Copies the resolved frame, which lives in the FP16 history buffer, back to the screen.
float4 OutputPS(VSOUT IN) : COLOR0
{
	return float4(tex2D(TESR_TAAHistoryBuffer, IN.UVCoord).rgb, 1.0f);
}

technique Resolve
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 ResolvePS();
	}
}

technique Output
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 OutputPS();
	}
}

technique Debug
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 DebugPS();
	}
}
