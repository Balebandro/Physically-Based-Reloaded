// VolumetricFog's density model, shared so that every effect reading "how thick is the air" gets
// the same answer. VolumetricFog.fx.hlsl paints the visible haze with it; VolumetricLight.fx.hlsl
// scales its scattering medium by it, so the shafts thicken and thin with the fog the player can
// see rather than with a second estimate that disagrees with it.
//
// Everything here is uniform across the frame, so the effect compiler folds it into a per-frame
// preshader rather than evaluating it per pixel. The one per-pixel term, VolumetricFog's animated
// fbm3 noise, is passed in by the caller as noiseModulation: VolumetricFog passes its real per-pixel
// value, and anything that cannot afford three noise octaves per sample (VolumetricLight's march)
// passes GetFogMeanNoiseModulation() instead and follows the fog's mean density.
//
// Settings and constants live in VolumetricFog.cpp. All of them are published from
// VolumetricFogEffect::UpdateSettings, which ShaderManager runs for every effect whether or not it
// is enabled, so they stay current for other effects while the fog itself is switched off.
//
// Requires, declared by the including file (declaring them here would clash with the includer's
// own declarations of the same globals):
//   float4 TESR_FogData;                    // x: fog near, y: fog far, w: fog power
//   float4 TESR_GameTime;                   // y: game hour
//   float4 TESR_SunAmount;                  // x: daylight ramp
//   float4 TESR_VolumetricFogDensity;       // x: BaseDensity, y: WeatherImpact, z: MorningFogDip, w: SunriseSunsetBoost
//   float4 TESR_VolumetricFogScatter;       // z: NoiseStrength
//   float4 TESR_VolumetricFogNight;         // x: DensityScale
//   float4 TESR_VolumetricFogNightScatter;  // x: NoiseStrengthScale
// and Includes/Helpers.hlsl (pows, PI) and Includes/Depth.hlsl (farZ) included before this file.

// 0 for interiors (no consistent day/night concept) or full daylight; ramps toward 1 through dusk
// for exteriors. Shared by every Night* setting so they all fade in together, in step.
float GetFogNightFactor(float isExterior) {
	float isDayTime = smoothstep(0.4, 0.8, TESR_SunAmount.x);
	return isExterior * (1 - isDayTime);
}

// How strongly the fbm3 noise modulates density, NoiseStrength with its night scale applied.
float GetFogNoiseStrength(float nightFactor) {
	return saturate(TESR_VolumetricFogScatter.z) * lerp(1.0, max(0, TESR_VolumetricFogNightScatter.x), nightFactor);
}

// The noise modulation VolumetricFog applies on average, for callers that follow the mean density.
// fbm3 is saturate(n * 1.4 - 0.2) over a weighted sum of value noise that averages 0.5, which maps
// to 0.5 -- so on average the noise thins density by half its strength rather than leaving it be.
static const float FOG_NOISE_MEAN = 0.5;

float GetFogMeanNoiseModulation(float nightFactor) {
	return lerp(1.0, FOG_NOISE_MEAN, GetFogNoiseStrength(nightFactor));
}

// VolumetricFog's `strength`: NVR-authored density plus the vanilla weather's, before extinction,
// inscattering or any height shaping is applied.
float GetFogStrength(float noiseModulation, float isExterior, float nightFactor) {
	float baseDensity = max(0, TESR_VolumetricFogDensity.x);
	float weatherImpact = max(0, TESR_VolumetricFogDensity.y);
	float morningFogDip = saturate(TESR_VolumetricFogDensity.z);
	float sunriseSunsetBoost = max(0, TESR_VolumetricFogDensity.w);

	// ---- vanilla-anchored density, derived from the active weather's own authored fog shape ----
	float vanillaStrength = pows((saturate(1 - TESR_FogData.y / farZ) + saturate(1 - TESR_FogData.x / farZ)) / 2, 2) / (TESR_FogData.w + 1);

	// ---- NVR-driven density: time-of-day curve, sunrise/sunset boost, night scale, noise ----
	float sunsetBump = sin(saturate(TESR_SunAmount.x) * PI) * isExterior;
	float noonTrough = 1 - saturate(abs(TESR_GameTime.y - 12) / 6); // 0 at 6am/6pm, 1 at solar noon
	float timeOfDayScale = lerp(1.0, lerp(1.0, 1.0 - morningFogDip, noonTrough), isExterior);
	float nightDensityScale = lerp(1.0, max(0, TESR_VolumetricFogNight.x), nightFactor);

	float nvrDensity = baseDensity * timeOfDayScale * nightDensityScale * noiseModulation;
	nvrDensity += sunriseSunsetBoost * sunsetBump;

	return max(0, nvrDensity + weatherImpact * vanillaStrength);
}
