#pragma once

class VolumetricFogEffect : public EffectRecord
{
public:
	VolumetricFogEffect() : EffectRecord("VolumetricFog") {
		Constants.WeatherFilterAnimator.Initialize(1);
		weatherFilterWasActive = true;
		rainyDisablesSkyFilter = true;
		cloudyDisablesSkyFilter = true;
		nightMinDarkness = 1.0f - 0.35f; // matches ShadowsExteriors.Main's own NightMinDarkness default (0.35), until the first exterior settings pass sets it for real
	};

	struct VolumetricFogStruct {
		D3DXVECTOR4		Density;         // x: BaseDensity, y: WeatherImpact, z: MorningFogDip, w: SunriseSunsetBoost
		D3DXVECTOR4		Shape;           // x: HeightFalloff, y: MaxHeight, z: Extinction, w: Inscattering
		D3DXVECTOR4		Wind;            // x: WindDirX, y: WindDirY, z: WindSpeed, w: NoiseScale
		D3DXVECTOR4		Scatter;         // x: PhaseAsymmetry, y: ShadowStrength, z: NoiseStrength, w: HeightInfluence
		D3DXVECTOR4		Weather;         // x: WeatherFilterBlend (animated 0-1, 1=sky mask active), y: isExterior, z: SkyAmbientAvailable, w: FogSaturation
		D3DXVECTOR4		Aerial;          // x: AerialStrength, y: AerialRangeStart, z: AerialTintBlend, w: AerialDayFadeStart
		D3DXVECTOR4		AerialTintColor; // xyz: manual aerial tint override, w: SunScatteringStrength
		D3DXVECTOR4		Distant;         // x: DistantFogRange, y: DistantFogBlend, z: DistantFogHeight, w: EdgeAA
		D3DXVECTOR4		Global;          // x: Amount, y: NightDisableSkyMask (Night-scoped, packed here for the spare slot), z: MoonVisibility, w: MinDensityFloor
		// Its own section/settings-UI tab (Shaders.VolumetricFog.Night), separate from Main, so
		// night-specific controls don't crowd the exterior tab as more of them get added.
		D3DXVECTOR4		Night;           // x: DensityScale, y: AmountScale, z: HeightFalloffScale, w: MaxHeightOffset
		D3DXVECTOR4		NightScatter;    // x: NoiseStrengthScale, y: WindSpeedScale, z: ExtinctionScale, w: InscatteringScale
		D3DXVECTOR4		NightTint;       // xyz: multiplicative night fog color tint, w: NightAmbientStrength
		Animator		WeatherFilterAnimator;
	};
	VolumetricFogStruct	Constants;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();

	// cached from UpdateSettings, consumed by UpdateConstants to drive WeatherFilterAnimator
	bool	rainyDisablesSkyFilter;
	bool	cloudyDisablesSkyFilter;
	bool	weatherFilterWasActive; // edge-detect for the animator, mirrors RainAnimator.switched

	// cached from UpdateSettings (Shaders.ShadowsExteriors.Main/NightMinDarkness), consumed by
	// UpdateConstants to drive the moon-phase night-ambient ceiling
	float	nightMinDarkness;
};
