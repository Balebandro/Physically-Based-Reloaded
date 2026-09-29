// =================================================================================================
//  CREDIT: Volumetric light shader by mcstfuerson. Used with permission.
//          Ported to New Vegas Reloaded by Conor.
//
//  Keep this credit intact in this file and in any copy, port or derivative of it.
// =================================================================================================

// Volumetric Light shafts for New Vegas Reloaded.
//
// Originally ported from arafuse/tes-reloaded's OblivionReloaded/Shaders/VolumetricLight/
// VolumetricLight.fx.hlsl, then rewritten against this fork's VSM/EVSM cascade shadow atlas
// (near/middle/far/lod, cross-faded) instead of the source's plain near/far depth-compare maps.
//
// This is now a from-scratch design for NVR rather than a port: two in-game tests (screenshots)
// showed the source shader's height-bounded "fog layer" ray march (march within a volume capped
// by a HEIGHT setting, animated flow-noise density, wind scroll) reads as a flat ground-hugging
// haze, not shafts -- a fully-lit ray inside that fog volume still glows even with zero occluder
// in view, so it looks like ambient fog rather than light breaking through gaps. In a second test,
// its unclamped accumulated light blew past 1.0 in a debris-dense area (lots of small sky gaps),
// which inverted CompositeLight's blend and erased the scene under a flat wash entirely.
//
// So: no fog volume, no height ceiling, no animated noise, no wind. The march is just camera to
// visible surface (or the falloff cutoff, whichever is nearer), testing the sun shadow atlas at each
// step. The only thing that ever brightens a pixel is GetSunShadowAmount() varying along the ray
// -- i.e. an actual occluder -- and the final output is saturated once, at the source, so it can
// never invert the composite blend. General atmospheric haze is VolumetricFog.fx.hlsl's job, not
// this one's.

// The bug that made this produce nothing for most of its development was a camera mismatch,
// not anything in the scattering or the shadow sampling. RenderManager::SetupSceneCamera builds
// the view matrices from *Pointers::Generic::CameraLocation but sets CameraPosition from
// WorldSceneGraph->camera->m_worldTransform.pos. The march took its direction from toWorld(),
// which is built on the first, and its origin from TESR_CameraPosition, which is the second, so
// every marched world position carried the offset between them -- enough to fall outside the
// 212-unit near cascade everywhere, so the shadow lookup returned lit almost always. See
// GetRayOrigin below. Anything here that looks like it is compensating for missing occlusion
// probably is, and should be re-derived rather than trusted.
//
// That offset is also nearly invisible to inspection: an offset position still yields a
// coherent frac() grid, a correct depth image, and correct cascade radii. It was found by
// dumping the lookup's inputs rather than reasoning about its output.

float4 TESR_ReciprocalResolution;
float4 TESR_SmoothedSunDir;
float4 TESR_SunColor;
float4 TESR_ShadowFade; // x: sunrise/sunset fade, y: shadow maps active

float4 TESR_FogData; // x: fog near, y: fog far, z: sun glare, w: fog power
float4 TESR_GameTime; // y: game hour -- read by Includes/FogDensity.hlsl
float4 TESR_SunAmount; // x: daylight ramp -- read by Includes/FogDensity.hlsl

// VolumetricFog's density constants, read through Includes/FogDensity.hlsl so these shafts scatter
// through the same air VolumetricFog paints. Published by VolumetricFogEffect::UpdateSettings,
// which runs for every effect whether or not it is enabled, so they stay live with the fog off.
float4 TESR_VolumetricFogDensity;      // x: BaseDensity, y: WeatherImpact, z: MorningFogDip, w: SunriseSunsetBoost
float4 TESR_VolumetricFogScatter;      // z: NoiseStrength
float4 TESR_VolumetricFogNight;        // x: DensityScale
float4 TESR_VolumetricFogNightScatter; // x: NoiseStrengthScale
float4 TESR_VolumetricLightData1; // xyz: scatter color tint, w: reference path length / march range
float4 TESR_VolumetricLightData2; // x: march range at night
float4 TESR_VolumetricLightData3; // x: strength, y: extinction, z: fog influence, w: anisotropy
float4 TESR_VolumetricLightData4; // x: scatter reference path, y: dither toggle, z: height falloff, w: dither offset this frame (0-1)
float4 TESR_VolumetricLightTemporal;        // x: history weight, y: history valid (0/1), z: clip gamma
float4 TESR_VolumetricLightPrevProjection;  // x: last frame's projection _11, y: its _22
float4 TESR_VolumetricLightCameraDelta;     // xyz: camera position this frame minus last frame's
float4x4 TESR_VolumetricLightPrevViewTransform; // last frame's TESR_ViewTransform; only its rotation is read

// Two techniques, not two passes of one technique: EffectRecord::Render() keeps a single
// RenderTarget/RenderedSurface pair for every pass of one Render() call, so a low-res march and
// a full-res composite can't share a technique. Technique 0 (March) renders into its own
// dedicated half-res TESR_VolumetricLightBuffer via RenderEffectToRT, same pattern as
// FlashlightBeamEffect's TESR_VolumetricBuffer. Technique 1 (Composite) runs later, at full
// resolution, through the normal RenderEffectsPreTonemapping chain.
sampler2D TESR_SourceBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
// POINT, not LINEAR. A depth buffer is not a colour buffer: interpolating between two texels
// either side of a silhouette yields a depth that belongs to neither surface. The march reads
// this at half-res UVs, so every sampled point sits between four full-res texels and every
// silhouette produces a band of rays terminating at an invented mid-air depth -- light with
// nothing to attach to. The composite's depth-aware upsample below wants true neighbour depths
// for the same reason.
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_ShadowAtlas : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
// Dedicated half-res march result. POINT, because Composite does the reconstruction itself:
// it takes the same four source texels bilinear would have used and weights them by depth
// similarity. Leaving this LINEAR would hand each of those four taps back a pre-blended mix of
// its neighbours, smuggling the cross-silhouette bleed back in underneath the depth weighting.
sampler2D TESR_VolumetricLightBuffer : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

// Blue noise for the march start offset, the same texture SunShadows and AmbientOcclusion use.
// WRAP so it tiles one texel per pixel across the half-res buffer.
sampler2D TESR_NoiseSampler : register(s4) < string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

// Last frame's filtered march, for the Temporal pass. LINEAR, because the reprojected position
// almost never lands on a texel centre.
sampler2D TESR_VolumetricLightHistory : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Shadows.hlsl"
#include "Includes/FogDensity.hlsl"

// --- Cascade shadow lookup -----------------------------------------------------------------
// Mirrors SunShadows.fx.hlsl's GetLightAmount (same registered constants, same atlas), copied
// rather than shared: the two effects compile independently and SunShadows.fx.hlsl already
// documents this "mirrored, not shared" pattern for the game-shader/effect split. Keep the two
// in step if cascade selection, bias, or atlas layout ever change.
// No row_major here: unlike the game-shader path (Shaders/Includes/Shadow.hlsl), which binds
// matrices by raw register index and needs it explicit, D3DX Effects bind by name through
// Effect->SetMatrix() with their own default (non-row_major) packing -- SunShadows.fx.hlsl,
// the other Effect consuming these same matrices, declares them plain for exactly this reason.
// row_major here silently transposed every light-space transform, which is why no occluder was
// ever detected: a transposed transform sends samples outside the valid [0,1] shadow-map region
// for virtually every real point, and CLAMP addressing on TESR_ShadowAtlas turns "off the edge"
// into "reads as unoccluded" almost universally.
float4x4 TESR_ShadowCameraToLightTransformNear;
float4x4 TESR_ShadowCameraToLightTransformMiddle;
float4x4 TESR_ShadowCameraToLightTransformFar;
float4x4 TESR_ShadowCameraToLightTransformLod;
float4 TESR_ShadowNearCenter;
float4 TESR_ShadowMiddleCenter;
float4 TESR_ShadowFarCenter;
float4 TESR_ShadowLodCenter;
float4 TESR_ShadowFormatData; // x: mode, y: format bits

static const float ShadowMode = TESR_ShadowFormatData.x;
static const float ShadowFormatBits = TESR_ShadowFormatData.y;

float4 ScreenCoordToTexCoord(float4 coord) {
    coord.xyz /= coord.w;
    coord.x = coord.x * 0.5f + 0.5f;
    coord.y = coord.y * -0.5f + 0.5f;
    return coord;
}

float4 SampleShadowMoments(float2 uv) {
    return tex2Dlod(TESR_ShadowAtlas, float4(uv, 0.0f, 0.0f));
}

// A cascade's shadow map is an orthographic slab, 2*sphereRadius thick, oriented along the sun.
// Outside it there is no occlusion information at all, and the only correct answer is 'lit'.
//
// Without this test the out-of-range coordinate was handed to the comparison anyway, which does
// not fail gracefully: z > 1 (past the far plane) gives a huge warped depth, so pMax collapses to
// 0 and reads fully SHADOWED, while z < 0 (in front of the near plane) gives a tiny one and reads
// fully LIT. The switch between them is a hard plane in world space -- horizontal a few feet up
// with the sun overhead, tilted with a low sun -- matching no geometry whatever, because it is not
// occlusion. In-game that was the whole of the effect: shafts that cut off at a fixed height and
// corresponded to nothing in view.
//
// It also buried the real signal rather than merely adding to it. Every sample that left the slab
// returned a hard 0 or 1 regardless of what occluders lay along the ray, and with 64 samples those
// dominate the average, so the march reported how much of each ray fell outside the cascade instead
// of what crossed it. Near-field occlusion was being computed correctly and then swamped.
//
// SunShadows.fx.hlsl omits this check safely: its receivers are visible surfaces, and the cascade
// was fitted to the view frustum that contains them, so they are inside the slab by construction.
// A ray march walks thousands of units through open air and leaves it constantly. The Oblivion
// source this was ported from does carry the test (OutsideShadowMap, returning 1.0); it was lost in
// the rewrite onto the cascade atlas. Folded to one max-of-abs as it is there: |x| > 1 is exactly
// x < -1 || x > 1, and |2z - 1| > 1 is exactly z < 0 || z > 1.
bool OutsideShadowMap(float3 projected) {
    return max(max(abs(projected.x), abs(projected.y)), abs(projected.z * 2.0f - 1.0f)) > 1.0f;
}

// Light-bleed reduction, adjusted for the atlas format so the effect works on either.
//
// GetEVSMExponents clamps the EVSM positive exponent to 5.54 on a 16-bit atlas (Format = 0)
// against 40 on a 32-bit one. The narrower warp leaves the Chebyshev bound markedly looser, so
// pMax sits higher and occluded points read as partly lit. ReduceLightBleeding removes exactly
// that tail, which makes it the right place to compensate -- rather than requiring the wider
// format, which costs double atlas bandwidth across the whole shadow system.
//
// A ray march is far more exposed to this than surface shading. A shaded surface sits a few
// units behind its occluder, where the bound is still tight; march samples sit hundreds of
// units behind one, where it is weakest. So the shared defaults, tuned for surfaces, are too
// permissive here on 16-bit even though they are fine for the deferred path.
float BleedReduction(float amount) {
    return ShadowFormatBits == 0.0f ? lerp(amount, 0.9f, 0.45f) : amount;
}

// Samples one cascade, or returns -1 when the point does not fall inside that cascade's map.
// The caller uses that to pick a cascade, which is the whole reason this reports it rather
// than clamping: selecting on the projection itself needs no TESR_Shadow*Center constant.
float TryCascade(float4x4 lightTransform, float4 coord, float offsetX, float offsetY, float bias, float bleedReduction) {
    float4 projected = mul(coord, lightTransform);
    projected.xyz /= projected.w;
    if (OutsideShadowMap(projected.xyz)) return -1.0f;

    float4 lightSpaceCoord = float4(projected.x * 0.5f + 0.5f, projected.y * -0.5f + 0.5f, projected.z, 1.0f);
    lightSpaceCoord.xy *= 0.5f;
    lightSpaceCoord.x += offsetX;
    lightSpaceCoord.y += offsetY;

    float4 moments = SampleShadowMoments(lightSpaceCoord.xy);

    [branch]
    if (ShadowMode == 0.0f)
        return GetLightAmountValueVSM(moments.xy, lightSpaceCoord.z, bias, bleedReduction);
    else if (ShadowMode == 1.0f)
        return GetLightAmountValueEVSM2(moments.xy, lightSpaceCoord.z, bias, bleedReduction, ShadowFormatBits);
    else
        return GetLightAmountValueEVSM4(moments, lightSpaceCoord.z, bias, bleedReduction, ShadowFormatBits);
}

float GetSunShadowAmount(float3 positionWS) {
    if (!TESR_ShadowFade.y) return 1.0f;

    const float bias = ShadowMode == 0.0f ? 0.00001f : 0.01f;
    float4 coord = float4(positionWS, 1.0f);

    // Cascade chosen by whether the point projects inside each map, nearest first -- not by
    // distance to TESR_Shadow*Center as the deferred path does.
    //
    // The distance form was silently selecting nothing. A diagnostic that ran those four sphere
    // tests directly, touching neither the atlas nor this function, came back solid black over an
    // entire exterior frame: not one cascade claimed a single pixel. Since this
    // function starts at shadow = 1.0 and only assigns inside one of those tests, it was
    // returning fully lit without ever sampling the shadow map, in every scene, which is why
    // no amount of work on the sampling itself changed anything.
    //
    // Selecting on the projection removes the dependency on those constants entirely: a point
    // is in a cascade exactly when it lands inside that cascade's map, which is the same test
    // already needed to reject out-of-range samples, and is how the Oblivion source this was
    // ported from cascades (GetLightAmount falling through to GetLightAmountFar). It is also
    // strictly more correct -- a bounding sphere overlaps the map it approximates rather than
    // matching it -- at the cost of the smooth cross-fade the radii allowed, which is worth
    // losing to get occlusion at all.
    float shadow = TryCascade(TESR_ShadowCameraToLightTransformNear,   coord, 0.0f, 0.0f, bias, BleedReduction(0.1f));
    if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformMiddle, coord, 0.5f, 0.0f, bias, BleedReduction(0.2f));
    if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformFar,    coord, 0.0f, 0.5f, bias, BleedReduction(0.6f));
    if (shadow < 0.0f) shadow = TryCascade(TESR_ShadowCameraToLightTransformLod,    coord, 0.5f, 0.5f, bias, BleedReduction(0.8f));

    // Outside every cascade there is no occlusion information, so lit is the only safe answer.
    if (shadow < 0.0f) return 1.0f;

    return saturate(shadow);
}

// --- Ray march setup -------------------------------------------------------------------------


// Sample count is the resolution at which the march can resolve a shadow volume, and it has to
// beat the occluders you want shafts from. At 14 samples over a 2000-unit range the step is 143
// units, while a tree trunk's shadow volume is 25-45 units across and a pole's is 15-30: the
// march simply steps over them, landing inside one maybe a fifth of the time, and a single
// darkened sample out of 14 is a 7% dip nobody can see. A building wall's shadow is 300+ units,
// wider than the step, which is why streets produced clear shafts while a forest produced none.
// Dithering the start offset helps beyond the raw count -- neighbouring pixels probe different
// points and the depth-aware upsample averages them -- but it cannot rescue a 5x shortfall.
// Compile-time constant, and an int -- deliberately, not a setting. Driving this from
// TESR_VolumetricLightData3.y made it a runtime bound with a float loop counter, and that
// crashed the D3DX9 HLSL compiler outright: the game died inside CompileEffect with no error
// logged, the log simply ending after this effect registered its texture. ps_3_0's native
// loop instruction counts with an integer register, so a float counter compared against a
// float bound cannot use it, and fxc falls back to a path that does not survive tex2Dlod and
// nested [branch] blocks in the body. Changing the count means editing this line and letting
// the effect recompile; if it needs to be a setting again, the D3DXMACRO route EffectRecord
// already uses for FORWARD_SHADOWS keeps it a compile-time constant, which this must stay.
static const int MARCH_NUM = 64;
static const float NOISE_GRANULARITY = 0.5 / 255.0;

static const float strength = TESR_VolumetricLightData3.x;
static const float anisotropy = TESR_VolumetricLightData3.w;
static const float fogInfluence = TESR_VolumetricLightData3.z;
static const float extinction = TESR_VolumetricLightData3.y;
static const float heightFalloff = TESR_VolumetricLightData4.z;
// Path length the scattering and extinction coefficients are expressed against. Floored in
// VolumetricLightEffect::UpdateSettings because this is a divisor.
static const float scatterReference = max(TESR_VolumetricLightData4.x, 1.0f);

// Geometric step growth: ds_i = ds_0 * r^i, so samples crowd near the camera and spread out with
// distance. A uniform march has to spend the same resolution on air 4000 units away, where one
// step covers a whole building, as on air 40 units away where it covers a fence post -- and the
// near air is both where the medium is densest and where a shadow volume subtends the most
// screen space. This is the same reasoning behind the exponential depth slices a froxel volume
// uses, applied to a per-pixel march.
//
// The steps have to sum to rayLength, so ds_0 = rayLength * (r - 1) / (r^N - 1). At r = 1.05 and
// N = 64, r^N = 22.7047, giving 0.0023037 -- a first step of 0.23% of the ray and a last step of
// 4.98%, against a uniform 1.56% throughout.
//
// r is set from what the march has to resolve, which MARCH_NUM above already documents: a tree
// trunk's shadow volume is 25-45 units across and a pole's is 15-30, while a building wall's is
// 300+. At AccumDistance 6000 that makes the first and last steps
//
//     r = 1.03   32.0 -> 205.8 units     first step steps over a pole, barely samples a trunk
//     r = 1.05   13.8 -> 298.9 units
//     r = 1.06    8.9 -> 348.0 units
//
// so 1.03 was spending its resolution in the wrong place: too coarse near the camera to catch the
// occluders that produce most of the visible shafts, while the far end was already finer than the
// building-scale shadows out there need. 1.05 is 2.3x finer near the camera for the same 64
// samples and the same range, paying for it where the occluders are large anyway. 1.06 goes
// further but the far steps start to outrun a building wall, and the dither jitters within each
// step, so the far field gets noisier as they grow.
//
// Written out rather than evaluated with pow() in a global initialiser: this file has already
// killed the D3DX9 compiler once over a change that looked just as harmless (see MARCH_NUM).
// If r changes, recompute BOTH -- they are not independent.
static const float STEP_GROWTH = 1.05f;
static const float STEP_FIRST_FRACTION = 0.0023037f;

// Scattering medium density, taken from VolumetricFog's density model.
//
// Scattered light is proportional to how much medium the ray crosses, so a constant density
// gives identical shafts in clear desert air and in thick fog, which is wrong in both
// directions: too strong when there is nothing to scatter off, too weak when the air is full
// of it. Density has to come from somewhere real, and the right source is the fog the player
// can see.
//
// It used to come from TESR_FogData alone, reading the span between the weather's near and far
// fog distances as an inverse density. VolumetricFog builds its density from those same vanilla
// numbers PLUS a time-of-day curve (MorningFogDip), a sunrise/sunset boost, a night density scale
// and animated noise, so the old heuristic contradicted the visible haze -- strongest shafts at
// noon, exactly when MorningFogDip has just thinned the air they scatter through.
//
// GetFogStrength (Includes/FogDensity.hlsl) is the same function VolumetricFog calls, so the two
// cannot drift apart. The fbm3 noise is replaced by its mean (GetFogMeanNoiseModulation): three
// octaves at every one of MARCH_NUM samples is far outside the ps_3_0 budget, and it varies per
// sample so it cannot be hoisted. The shafts follow the fog's mean density, not its per-point
// pockets. isExterior is 1 because this effect only renders in exteriors (see ShouldRender).
//
// FOG_REFERENCE_STRENGTH is the strength treated as a fully dense medium. At 1.0 the default
// exterior fog settings put clear weather around 0.1-0.2, close to where the old span heuristic
// sat for clear weather, so FogInfluence's tuning roughly carries over; heavy weather fog pushes
// it higher.
static const float FOG_REFERENCE_STRENGTH = 1.0f;

float GetFogDensity() {
    float nightFactor = GetFogNightFactor(1.0f);
    float strength = GetFogStrength(GetFogMeanNoiseModulation(nightFactor), 1.0f, nightFactor);
    return saturate(strength / FOG_REFERENCE_STRENGTH);
}

// Medium density falls off exponentially with altitude, measured from the ray origin.
//
// A uniform medium scatters the same amount at any height, so a shaft is as bright 300 feet up
// as it is at ground level and the frame reads as an even glow. Real haze is stratified -- dense
// low, thin above -- and that gradient is what makes a shaft read as a beam punching through a
// layer rather than as light smeared over the whole view.
//
// This is NOT the height-bounded fog volume the header describes removing. That one added light
// of its own: a fully lit ray inside the volume glowed with no occluder anywhere in view, which
// is why it read as ambient haze. Density here only scales a term already multiplied by
// GetSunShadowAmount, so no occluder still means no light, and the effect stays what it is.
//
// Referenced to the ray origin rather than to an absolute world Z. Absolute height is the
// physically right datum, but FNV has no single ground level -- every worldspace and DLC sits at
// its own Z -- so a fixed reference would need retuning per cell and be wrong everywhere it had
// not been. The camera is self-calibrating: stand on the ground and the air around you is at full
// density, thinning above.
//
// max(dz, 0) rather than dz, so looking down from a clifftop does not amplify the density below
// the camera without bound. Below the reference the medium simply stays at full density.
float GetHeightDensity(float positionZ, float originZ) {
    if (heightFalloff <= 0.0f) return 1.0f;
    return exp(-max(positionZ - originZ, 0.0f) / heightFalloff);
}

static const bool ditherEnabled = TESR_VolumetricLightData4.y > 0.5f;

// Calibration constant. Left at 0.04, with Strength carrying the rest, so the usable setting is
// around 55 rather than around 1.
//
// This is not the number the maths wants. TESR_SunColor does not carry the large linear HDR
// magnitude a comment elsewhere in this file claims -- working back from a tuned frame it sits
// near 0.5 -- so everything downstream is scaled down with it, and 2.2 here is what would put the
// slider back near 1.0. That change was made and then reversed: it silently rescales Strength by
// 55x, so every config tuned against this constant reads 55x too bright until it is edited by
// hand, and that cost more than the tidier slider range was worth.
//
// If it is ever revisited, the two have to move together: multiply here, divide in every
// [Shaders.VolumetricLight.Main] Strength, including any the user has saved.
//
// It is not a ceiling either way. Two things that used to cap it are gone:
//
//   - CompositeLight ran the march output through linearize() as though it were an sRGB-encoded
//     colour. It is not -- it is linear light -- so the shaft was gamma-decoded a second time.
//     That decode was removed and then asked for back, because the contrast it gives is wanted;
//     it is now an explicit pow() at SHAFT_RESPONSE_POWER instead of a colour-space call that
//     happened to have the right shape. Strength therefore responds on that power curve, not
//     linearly, but it does so by the same factor at every brightness -- which the sRGB decode
//     did not, its effective exponent drifting with the shaft's own magnitude.
//
//   - The old value was cut from the source shader's 3.0 to stop a fully lit ray clipping past
//     1.0, because above 1.0 the old composite blend inverted. The composite tracks transmittance
//     separately now, so in-scattered light is additive and a value above 1.0 is just a bright
//     shaft. The buffers are FP16 all the way to the tonemapper, so it survives to be rolled off
//     rather than clipped.
static const float accumLightStrength = 0.04f;

// Response curve applied to the shaft in the composite. Strength feeds the march linearly, so
// the overall response is Strength^2.1. See the long note at the composite for what the curve
// buys and why it is an explicit power rather than the sRGB decode it used to be.
static const float SHAFT_RESPONSE_POWER = 2.1f;

struct VSOUT {
    float4 vertPos : POSITION;
    float2 UVCoord : TEXCOORD0;
};

struct VSIN {
    float4 vertPos : POSITION0;
    float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN) {
    VSOUT OUT = (VSOUT) 0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

// pow(g, 1.5); fxc does not fold this on its own.
float Pow1_5(float g) {
    return g * sqrt(g);
}

// Henyey-Greenstein phase function, anisotropy clamped to ceiling (wider, flatter lobe for sky
// rays than ground rays -- see the two call sites' scatterCeiling).
//
// Normalised to peak at exactly 1.0 looking straight into the sun, so Anisotropy sets the SHAPE
// of the lobe and nothing else. Raw HG has its magnitude tied to g: the peak is
// (1-g^2)/(4*PI*(1-g)^3), which climbs from 0.108 at g=0.1 to 0.796 at g=0.6 -- so tightening
// the lobe also made the whole effect 7.4x brighter, far past where the composite blend
// saturates, and the frame washed out to a flat sheet that destroyed the very structure the
// tighter lobe was meant to reveal. Dividing through by that peak decouples the two knobs:
// Anisotropy controls how sharply light gathers toward the sun, Strength controls how much
// there is. The peak term is a closed form -- at lightDotView == 1 the denominator is
// (1 + g^2 - 2g)^1.5 = ((1-g)^2)^1.5 = (1-g)^3 -- so this costs no extra evaluation.
float ComputeScattering(float lightDotView, float ceiling) {
    float g = min(anisotropy, ceiling);
    float forward = 1.0f - g;
    float denom = 1.0f + g * g - (2.0f * g) * lightDotView;
    return (forward * forward * forward) / Pow1_5(max(denom, 0.0001f));
}

// Low-resolution ray march: walks the view ray from the camera to the visible surface, or to
// the distance-falloff cutoff, whichever is nearer -- sampling the sun shadow atlas at each step. The Henyey-
// Greenstein term itself only depends on view/sun angle, so it's constant along the ray and
// computed once outside the loop; the ONLY thing that varies per step, and the only thing that
// ever brightens a pixel, is the shadow value -- so a fully-lit, unoccluded view (no occluder in
// the ray's path) contributes almost nothing, and contrast only appears where the ray actually
// crosses a shadow boundary.
// Ray origin, taken from TESR_InvViewTransform rather than TESR_CameraPosition.
//
// RenderManager::SetupSceneCamera builds the view and inverse-view matrices from
// *Pointers::Generic::CameraLocation, but sets CameraPosition from
// WorldSceneGraph->camera->m_worldTransform.pos. Those are two different sources for the same
// thing. The march took its direction from toWorld(), which is built on TESR_ViewTransform and
// so on the first of them, while taking its origin from the second -- so any disagreement
// between them offsets every world position the march produces, and with it every cascade test
// and every shadow sample, while still looking perfectly coherent in a frac() grid.
//
// SunShadows.fx.hlsl cannot hit this: reconstructWorldPosition derives position entirely from
// TESR_InvViewTransform, so its origin and direction always agree. Matching that here removes
// the mismatch rather than assuming the two sources are equal.
float3 GetRayOrigin() {
    return float3(TESR_InvViewTransform[3][0], TESR_InvViewTransform[3][1], TESR_InvViewTransform[3][2]);
}

float4 VolumetricLight(VSOUT IN) : COLOR0 {
    float2 uv = IN.UVCoord.xy;
    float3 rayOrigin = GetRayOrigin();

    float depth = readDepth(uv);
    bool isSky = depth > (farZ * 0.99f);

    float3 cameraVector = toWorld(uv) * depth;
    float3 rayDirection = normalize(cameraVector);

    // March only as far as the distance falloff below actually weights: every sample past
    // accumDistance is multiplied by zero, so spending steps out there buys nothing and costs
    // the resolution of the part that does count. Marching to the visible surface (or 20000
    // units into open sky) instead put a sky ray's step length at 20000/14 = ~1430 units, so
    // only its first two or three samples landed inside the falloff window at all -- the whole
    // open-sky result was reconstructed from three samples 1430 units apart, while a ray that
    // hit a wall 700 units out got all 14 at 50-unit spacing. That quality cliff between
    // "ray hit something near" and "ray reached sky" is what read as soft blobs of light
    // hanging in mid-air, untethered from any geometry.
    float accumDistance = max(TESR_VolumetricLightData1.w, 1.0f);

    // Shorter reach at night. After dark the light is the moon, and marched the full range, every
    // ray that runs a long way through open air -- the sky, the far terrain -- adds up thousands of
    // units of moonlit medium with no occluder in it, and the forward-scattering lobe turns that into
    // a smooth glow over the distance in the moon's direction. That is the part that looks wrong.
    // Night shafts come from occluders near the camera, where rays stop at geometry well inside this
    // range anyway, so cutting the range removes the far glow and leaves them alone. The distant glow
    // scales with the range, so NightDistance / AccumDistance is roughly how much of it remains.
    // Fades in through dusk on the same curve as VolumetricFog's night settings.
    float marchRange = lerp(accumDistance, max(TESR_VolumetricLightData2.x, 1.0f), GetFogNightFactor(1.0f));
    float rayLength = isSky ? marchRange : min(length(cameraVector), marchRange);

    // Blue noise, not the 4x4 ordered pattern this used to use.
    //
    // An ordered pattern repeats every 4 pixels by construction, so the step boundaries it is
    // meant to hide line up into a regular structure instead of scattering. Upsampled from half
    // resolution that became clear diagonal banding with a crosshatch texture across every shaft
    // -- structured, not random, and therefore not something a denoiser can remove: blurring
    // bands only produces softer bands.
    //
    // Blue noise has no such periodicity, so the same step boundaries scatter into fine grain
    // that a blur genuinely does clear. Sampled one texel per pixel, unfiltered, which is how a
    // blue noise mask has to be read to keep its spectral properties.
    float2 noiseUV = uv * (0.5f / TESR_ReciprocalResolution.xy) / 256.0f;
    float ditherOffset = ditherEnabled ? tex2D(TESR_NoiseSampler, noiseUV).r : 0.5f;

    // Advance the mask every frame so the sample pattern is not frozen in place: shifted by the
    // golden-ratio sequence, which VolumetricLightEffect::UpdateConstants steps once per frame and
    // passes in already wrapped to [0, 1). 0, and so no motion, unless TAA is on or DitherMotion
    // forces it -- with nothing averaging the frames back together, a moving dither is only shimmer.
    // With TAA it pays off: a fixed pattern is exactly what temporal accumulation cannot remove,
    // because every frame reproduces it.
    ditherOffset = frac(ditherOffset + TESR_VolumetricLightData4.w);

    float lightDotView = dot(rayDirection, TESR_SmoothedSunDir.xyz);
    float3 lightColor = TESR_VolumetricLightData1.xyz * TESR_SunColor.rgb;
    float scatterCeiling = isSky ? 1.0f : 0.5f;
    // VolumetricFog's density scales the medium. FogInfluence at 0 keeps a constant medium and the
    // previous behaviour exactly; at 1 the shafts track the fog the player can actually see.
    float3 scatterTerm = ComputeScattering(lightDotView, scatterCeiling).xxx * lightColor;
    // VolumetricFog's density sets the baseline density of the medium; GetHeightDensity varies it per sample.
    float baseDensity = lerp(1.0f, GetFogDensity(), saturate(fogInfluence));

    // Both coefficients are per world unit, expressed against ScatterReference as the reference
    // path. A full-length ray through undiminished medium accumulates unit scattering, and
    // Extinction reads as "optical depth over that same reference path" -- 1.0 meaning the scene
    // behind it is attenuated to 1/e. Without this normalisation the coefficients would be
    // raw per-unit numbers in the 1e-4 range and every setting would need retuning by three
    // orders of magnitude.
    //
    // This divides by ScatterReference and NOT by accumDistance, which it used to, and the
    // difference is the whole reason ScatterReference exists. Dividing by the march range makes
    // one setting do two unrelated jobs, and they fight:
    //
    //   accumLight ~ scatterTerm * density * (Shadow_avg * rayLength) / reference
    //
    // rayLength is min(distance to the surface, accumDistance). A sky ray has rayLength ==
    // accumDistance, so the ratio is 1 and raising the range costs it nothing. Every ray that
    // hits something has rayLength pinned by the depth buffer, so raising the range divided its
    // brightness outright -- at 12000 instead of 6000 a ray stopping at a wall 800 units away
    // came out half as bright. Near the camera every ray terminates early, so raising the march
    // range faded the shafts out exactly where the player is standing while the distance and the
    // sky held station.
    //
    // Split in two, each setting does one job: ScatterReference sets how dense the air is,
    // accumDistance sets how far to look. Leaving them equal reproduces the old behaviour, which
    // is why the default is 6000 for both.
    float invReference = 1.0f / scatterReference;

    float3 accumLight = 0.0f.xxx;
    // Transmittance of the medium between the camera and the current sample. Tracked separately
    // from the in-scattered light, which is the whole point of the rewrite -- see CompositeLight.
    float transmittance = 1.0f;

    float t = 0.0f;
    float ds = rayLength * STEP_FIRST_FRACTION;

    [loop]
    for (int i = 0; i < MARCH_NUM; i++) {
        // Jittered within its own step, not just at the ray start. With uniform steps a single
        // start offset was enough, because every step was the same length and the jitter carried
        // down the ray. Steps now grow, so an offset applied once decays to nothing in relative
        // terms by the far end and the step boundaries out there band again.
        float3 currentPosition = rayOrigin + rayDirection * (t + ds * ditherOffset);

        // 1.0 where this step sees the sun, towards 0 behind an occluder.
        float Shadow = GetSunShadowAmount(currentPosition);

        // Beer-Lambert, integrated analytically over the step rather than sampled at a point.
        //
        // What stood here was a Riemann sum with a linear 1 - dist/accumDistance ramp standing in
        // for extinction. Two problems. The ramp reaches a hard zero at accumDistance, so light
        // stopped at a plane in open air instead of fading, which caps how far a shaft can reach no
        // matter how the range is set. And a plain sum is only as accurate as its step count,
        // which is why this needed 64 samples.
        //
        // The closed form below is exact for constant in-scattering across the step, so it holds
        // its accuracy as the steps grow long at the far end of the march -- which the geometric
        // growth above relies on. It is the standard form: over a step of length ds, the light
        // reaching the camera from that step is S * (1 - exp(-sigmaT*ds)) / sigmaT, attenuated by
        // the transmittance accumulated so far.
        float density = baseDensity * GetHeightDensity(currentPosition.z, rayOrigin.z);
        float sigmaS = density * invReference;
        float sigmaT = max(density * extinction * invReference, 1e-8f);

        float opticalDepth = sigmaT * ds;
        float stepTransmittance = exp(-opticalDepth);

        // (1 - exp(-x)) / sigmaT is the integral, but it cancels catastrophically for small x:
        // in a thin medium x can be 1e-6, and float32 computing 1.0 - 0.999999 keeps barely one
        // significant digit, so the segment length comes back quantised and the march picks up
        // noise that has nothing to do with the scene. Below the crossover the second-order
        // series ds * (1 - x/2) is both exact to the precision available and cheaper than the
        // divide. Extinction near zero is a setting anyone might reasonably pick -- it means
        // "shafts that light the air without veiling what is behind them" -- so this path is
        // normal operation, not a degenerate guard.
        float segment = opticalDepth > 1e-3f
            ? (1.0f - stepTransmittance) / sigmaT
            : ds * (1.0f - 0.5f * opticalDepth);

        accumLight += transmittance * scatterTerm * Shadow * sigmaS * segment;
        transmittance *= stepTransmittance;

        t += ds;
        ds *= STEP_GROWTH;
    }

    // No path-length normalisation here any more. The loop's segment term carries real world
    // units, so how far the ray travelled is already in the result -- which is what the old
    // "mean sample value" form had to be corrected back to by hand.
    accumLight *= accumLightStrength * strength;
    accumLight += lerp(-NOISE_GRANULARITY, NOISE_GRANULARITY, rand(uv));

    // Clamped, but not to 1.0. The old saturate() was there because CompositeLight's blend
    // inverted above 1.0 and swamped the scene -- the "everything erased to a flat wash" failure
    // in debris-dense areas. The composite no longer has that failure mode, and this effect runs
    // in the pre-tonemapping chain, where a value above 1.0 is a legitimate HDR highlight that
    // the tonemapper is there to roll off. Clamping to 1.0 instead of letting it through is what
    // makes a shaft look like paint rather than like light. The ceiling that remains is only to
    // keep a pathological value out of the FP16 buffer.
    //
    // Alpha carries the medium's OPACITY, 1 - transmittance, back in the half-res buffer.
    //
    // This costs a blocky fringe at silhouettes and that is a known, accepted trade. A ray that
    // stops on a near object accumulates almost no extinction while a sky ray runs the full
    // AccumDistance, so the value either side of an edge differs enormously -- at Extinction 1.0,
    // keeping 99% of the pixel against keeping 45%. Reconstructing that through the 4-tap upsample
    // is what fringes, and where all four taps are rejected the fallback is a POINT sample of a
    // half-res texture, i.e. 2x2 blocks. Alpha-tested hair is worst, writing no depth, so its edge
    // pixels read the background's depth and pull in sky transmittance.
    //
    // Computing it at full resolution in the composite removes that entirely and costs very
    // little -- see git history for the closed form, which matched the march's stepped integral
    // to five decimal places. Go back to it if the fringe matters more than whatever this is
    // being traded for.
    //
    // Opacity rather than transmittance so an all-zero buffer reads as "no medium" and passes the
    // frame through, instead of reading as "absorbs everything" and blacking the screen on the
    // first frame after a device reset recreates it.
    return float4(min(accumLight, 16.0f), 1.0f - transmittance);
}

// One tap of the depth-aware upsample. exp2 falls off fast enough that a tap on the far side
// of a silhouette contributes essentially nothing, while the depth difference across a
// continuous surface (even a steeply raked one) stays well inside the kernel. Relative to
// centerDepth, not absolute: the same slope spans a far larger absolute depth range at 4000
// units than at 40, and an absolute tolerance would either bleed up close or over-reject far off.
// Weights all four channels together: opacity rides in alpha and has to be reconstructed against
// the same depth test as the colour, or a silhouette pixel takes its in-scattered light from one
// side of the edge and its attenuation from the other.
void AccumulateTap(float2 tapUV, float centerDepth, inout float4 sum, inout float weightSum) {
    float tapDepth = readDepth(tapUV);
    float weight = exp2(-32.0f * abs(tapDepth - centerDepth) / max(centerDepth, 1.0f));
    sum += tex2D(TESR_VolumetricLightBuffer, tapUV) * weight;
    weightSum += weight;
}

// Full resolution: upsamples the low-res march and blends it onto the scene. No separate
// sky-ambient term: this stays a pure shadow-occlusion shaft effect, not a general atmospheric
// glow -- the march itself already scales every contribution by GetSunShadowAmount, so a pixel
// only lights up here where an occluder actually created contrast against the sun.
//
// The upsample is depth-aware rather than a plain bilinear tex2D. A half-res texel straddling a
// silhouette mixes a short ray (near surface, little accumulated light) with a long one (open sky
// behind it, much more), and bilinear then smears that mixture several full-res pixels to either
// side of the edge -- a halo of light detached from the object that should bound it. Scaling the
// march by path length widens precisely that near/far gap, so this matters more now, not less.
float4 CompositeLight(VSOUT IN) : COLOR0 {
    float2 uv = IN.UVCoord.xy;

    // TESR_ReciprocalResolution is the full-res texel; the half-res texel is twice that, so this
    // offset is exactly half a half-res texel -- the four source texels bilinear would have used.
    float2 offset = TESR_ReciprocalResolution.xy;
    float centerDepth = readDepth(uv);

    float4 sum = float4(0.0f, 0.0f, 0.0f, 0.0f);
    float weightSum = 0.0f;
    AccumulateTap(uv + float2(-offset.x, -offset.y), centerDepth, sum, weightSum);
    AccumulateTap(uv + float2( offset.x, -offset.y), centerDepth, sum, weightSum);
    AccumulateTap(uv + float2(-offset.x,  offset.y), centerDepth, sum, weightSum);
    AccumulateTap(uv + float2( offset.x,  offset.y), centerDepth, sum, weightSum);

    // When every tap is rejected -- a thin feature, or a strong depth discontinuity where all
    // four neighbours sit on the far side of an edge -- dividing by the epsilon floor returns
    // black, not a neutral result. That painted single-pixel black speckle along every
    // silhouette in the frame, and because it rides on top of whatever the march produced it
    // corrupted the diagnostics too: a view that output one flat colour with no uv term at all
    // still came back speckled, which is how it was found. Earlier readings of those
    // specks as genuine occlusion were wrong; they were this.
    //
    // Falling back to the nearest single tap keeps the pixel's own value instead of inventing
    // a black one. It is the right answer as well as a safe one: if no neighbour shares this
    // pixel's depth, the unfiltered sample is exactly what should be used.
    float4 volumeLight = weightSum < 0.0001f
        ? tex2D(TESR_VolumetricLightBuffer, uv)
        : sum / weightSum;

    // The volumetric rendering equation: what reaches the eye is the scene behind the medium,
    // attenuated by the medium's transmittance, plus the light the medium scattered into the ray.
    //
    //     result = color * T + L
    //
    // What stood here was color * (1 - L) + L, a premultiplied "over" blend that makes
    // transmittance a function of shaft BRIGHTNESS. Those are independent quantities: a sunbeam
    // scatters a great deal of light toward you while absorbing almost none of what is behind it,
    // because the air it runs through is thin. Tying them together meant a bright shaft had to
    // veil the scene behind it in exact proportion to how bright it was, so the effect could
    // never be light added to the frame -- only paint laid over it. Every clamp and ceiling that
    // used to sit upstream of here existed to stop that veiling becoming total.
    //
    // T comes from the march's own extinction integral, so a thin medium passes the scene through
    // essentially untouched however bright the shaft gets, and a genuinely thick one (heavy fog
    // weather, high Extinction) attenuates it whether or not the sun is behind an occluder.
    //
    // The in-scattered term is raised to SHAFT_RESPONSE_POWER, which is DELIBERATE and is not a
    // colour-space conversion. The march output is built from TESR_SunColor, already linear HDR
    // in this engine, so there is nothing here to decode. It is a response curve, and what it
    // does to the picture is wanted:
    //
    //   - Strength stops being linear. Doubling it gives 2^2.1 = 4.3x, so the slider has a soft
    //     bottom end and ramps hard.
    //   - Dim scattering is crushed harder than bright scattering, which pulls the general haze
    //     down relative to the bright shaft cores. That is the contrast the curve is wanted for.
    //   - It also SATURATES the shaft, which is the part that is easy to miss. The curve is
    //     per-channel, so the ScatterR/G/B tint spreads: 1.0 / 0.9 / 0.78 comes out nearer
    //     1.0 / 0.80 / 0.59. Warm tints get warmer. Retune the tint, not this, if that goes too far.
    //
    // This was linearize() -- the real sRGB EOTF -- and is now an explicit power, because sRGB is
    // not a fixed power curve. Its local exponent is 2.4 * c / (c + 0.055), which runs from about
    // 1.88 at c = 0.2 to 2.34 at c = 2.0, so the slider's feel changed with how bright the shaft
    // already was. A constant 2.1 sits inside that range and behaves the same everywhere; at the
    // values this runs at the two differ by under about 10% in magnitude, so this is a change of
    // slope, not of exposure, and Strength does not need recalibrating for it.
    //
    // The one real difference is at the very bottom. sRGB has a linear segment below 0.04045
    // (c / 12.92) that this does not, so the faintest haze is crushed harder than before -- which
    // is the direction the curve is wanted in anyway.
    float3 color = linearize(tex2D(TESR_SourceBuffer, uv)).rgb;
    float3 shaft = pow(max(volumeLight.rgb, 0.0f), SHAFT_RESPONSE_POWER);
    float3 result = color * (1.0f - volumeLight.a) + shaft;
    return delinearize(float4(result, 1.0f));
}

// --- Temporal filter (half res) -------------------------------------------------------------
// Blends each frame's march with the filtered result of the frames before it, reprojected for camera
// motion. The march's blue-noise dither moves every frame while this runs (see UpdateConstants), so
// the history averages many different sample placements into one smooth shaft -- the step-boundary
// grain a single frame cannot avoid. Same method as TAA.fx.hlsl, at the march's resolution and
// before the upsample, so it works with TAA off and costs a quarter as much.
//
// Rejection is a clamp of the history to the current frame's 3x3 neighbourhood, shrunk to the mean
// plus or minus ClipGamma standard deviations (Salvi's variance clipping). The dither's grain sits
// inside that range and is averaged away; a shaft that genuinely moved or a disocclusion falls
// outside it and is pulled back to the current frame.
static const float temporalWeight = TESR_VolumetricLightTemporal.x;
static const float temporalValid = TESR_VolumetricLightTemporal.y;
static const float temporalGamma = TESR_VolumetricLightTemporal.z;

// Where the surface under uv was on screen last frame. Inverts toWorld with last frame's camera: the
// same maths as TAA's Reproject, on this effect's own copy of the previous camera. The view matrix
// holds only rotation here -- position arrives as a CPU-side delta, so no large world coordinates
// reach the GPU.
float2 ReprojectToPrevious(float2 uv, out float inFront) {
    float3 cameraVector = toWorld(uv) * readDepth(uv);
    float3 fromPrevCamera = cameraVector + TESR_VolumetricLightCameraDelta.xyz;

    float3 prevRight   = float3(TESR_VolumetricLightPrevViewTransform[0][0], TESR_VolumetricLightPrevViewTransform[1][0], TESR_VolumetricLightPrevViewTransform[2][0]);
    float3 prevUp      = float3(TESR_VolumetricLightPrevViewTransform[0][1], TESR_VolumetricLightPrevViewTransform[1][1], TESR_VolumetricLightPrevViewTransform[2][1]);
    float3 prevForward = float3(TESR_VolumetricLightPrevViewTransform[0][2], TESR_VolumetricLightPrevViewTransform[1][2], TESR_VolumetricLightPrevViewTransform[2][2]);

    float viewZ = dot(fromPrevCamera, prevForward);
    inFront = viewZ > 0.0f ? 1.0f : 0.0f;

    float2 ndc = float2(dot(fromPrevCamera, prevRight) * TESR_VolumetricLightPrevProjection.x,
                        dot(fromPrevCamera, prevUp) * TESR_VolumetricLightPrevProjection.y) / max(viewZ, 1e-4f);
    return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
}

float4 TemporalFilter(VSOUT IN) : COLOR0 {
    // Same convention as the march: the quad's half-full-res-texel UV offset puts uv on the first
    // full-res texel of this half-res pixel's 2x2 block, which is also the depth the march used.
    float2 uv = IN.UVCoord.xy;
    float2 halfResTexel = TESR_ReciprocalResolution.xy * 2.0f;
    float4 current = tex2D(TESR_VolumetricLightBuffer, uv);

    // Mean, variance and range of the 3x3 neighbourhood, all four channels: opacity rides in alpha
    // and has to be filtered against the same history as the light, or the two drift apart.
    float4 m1 = 0.0f;
    float4 m2 = 0.0f;
    float4 nMin = current;
    float4 nMax = current;
    [unroll]
    for (int y = -1; y <= 1; y++) {
        [unroll]
        for (int x = -1; x <= 1; x++) {
            float4 s = tex2D(TESR_VolumetricLightBuffer, uv + float2(x, y) * halfResTexel);
            m1 += s;
            m2 += s * s;
            nMin = min(nMin, s);
            nMax = max(nMax, s);
        }
    }
    m1 /= 9.0f;
    m2 /= 9.0f;
    float4 sigma = sqrt(max(m2 - m1 * m1, 0.0f));
    float4 boxMin = max(nMin, m1 - temporalGamma * sigma);
    float4 boxMax = min(nMax, m1 + temporalGamma * sigma);

    float inFront;
    float2 prevUV = ReprojectToPrevious(uv, inFront);
    float onScreen = step(0.0f, prevUV.x) * step(prevUV.x, 1.0f) * step(0.0f, prevUV.y) * step(prevUV.y, 1.0f);

    // prevUV follows the same first-texel convention; half a full-res texel on is this half-res
    // texel's centre, so a still camera reads the history texel back exactly, with no blur.
    float4 history = tex2D(TESR_VolumetricLightHistory, prevUV + 0.5f * TESR_ReciprocalResolution.xy);
    history = clamp(history, boxMin, boxMax);

    float weight = temporalWeight * temporalValid * onScreen * inFront;
    return lerp(current, history, weight);
}

technique March {
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 VolumetricLight();
    }
}

technique Composite {
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 CompositeLight();
    }
}

// Technique 2, run by VolumetricLightEffect::RenderTemporal between the march and the composite.
technique Temporal {
    pass {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 TemporalFilter();
    }
}
