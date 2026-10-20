#pragma once

// Wetness Effects, ported from Community Shaders (features/Wetness Effects, GPL-3.0): surfaces getting
// wet in the rain and drying after it -- darkening, a water film with its own highlight and reflection,
// puddles, raindrop ripples on the land, nothing wet under cover. The shading is in
// Shaders/Includes/Wetness.hlsl, used by the object and terrain templates (skin gets wet by its own
// RainWetness, effects/Skin.cpp). This collection holds the settings and works out from the
// weather how wet the world is, as CS's WetnessEffects::GetCommonBufferData does.
class WetnessEffectsShaders : public ShaderCollection
{
public:
	WetnessEffectsShaders() : ShaderCollection("WetnessEffects") {};

	struct WetnessSettingsStruct {
		float	MaxRainWetness;
		float	MaxPuddleWetness;
		float	PuddleRadius;
		float	PuddleMaxAngle;
		float	PuddleMinWetness;
		float	MinRainWetness;
		float	WeatherTransitionSpeed;
		float	HeightAwareness;	// how much the land's height maps shape the wetness (0 off)
		float	CreviceFill;		// the water line in the crevices at full wetness, as a height (0-1)
		float	NormalAwareness;	// how much the land's normal maps decide how wet a spot gets (0 off)

		bool	EnableRaindropFx;
		bool	EnableRipples;
		float	RaindropFxRange;
		float	RaindropGridSize;
		float	RaindropInterval;
		float	RaindropChance;
		float	RippleStrength;
		float	RippleRadius;
		float	RippleBreadth;
		float	RippleLifetime;

		// CS's debug overrides: -1 off, else the value used whatever the weather.
		float	WetnessOverride;
		float	PuddleOverride;
		float	RainOverride;
		bool	ShowCover;		// debug view of the cover test (Includes/Wetness.hlsl, WetnessCoverDebug)
	};
	WetnessSettingsStruct	Settings;

	struct WetnessStruct {
		D3DXVECTOR4		Data;		// x: wetness, y: puddle wetness, z: raining, w: time (s)
		D3DXVECTOR4		Params;		// x: MaxRainWetness, y: MaxPuddleWetness, z: MinRainWetness, w: PuddleRadius
		D3DXVECTOR4		Params2;	// x: PuddleMaxAngle, y: PuddleMinWetness, zw: unused
		D3DXVECTOR4		Drops;		// x: 1 / grid size, y: 1 / interval, z: drop chance, w: interval / ripple lifetime
		D3DXVECTOR4		Ripple;		// x: strength, y: radius, z: breadth, w: raindrop range
		D3DXVECTOR4		Camera;		// xyz: camera position, w: unused
		D3DXVECTOR4		Flags;		// x: on, z: ripples, w: ortho map texel size (0: none)
		D3DXVECTOR4		Sun;		// xyz: direction to the sun
		D3DXVECTOR4		Height;		// x: HeightAwareness, y: CreviceFill, z: NormalAwareness (the land only)
	};
	WetnessStruct	Constants;

	float	Wetness = 0.0f;			// eased, 0-1
	float	PuddleWetness = 0.0f;
	float	Raining = 0.0f;
	double	RainTime = 0.0;

	// How wet the weather has made things, 0-1, for the rest of NVR (PBR, skin, terrain and water
	// shaders, heat haze): the rain, or the wetness it left. Followed whether or not the effect is on.
	float	RainFactor() const { return max(Raining, Wetness); }

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
};
