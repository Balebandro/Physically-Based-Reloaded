#pragma once

// Wetness Effects, ported from Community Shaders (features/Wetness Effects, GPL-3.0): surfaces getting
// wet in the rain and drying after it -- darkening, a water film with its own highlight and reflection,
// puddles, shore wetness, raindrop splashes and ripples, nothing wet under cover. The shading is in
// Shaders/Includes/Wetness.hlsl, used by the object and terrain templates; skin and hair take
// SkinWetness through the skin shaders. This collection holds the settings and works out from the
// weather how wet the world is, as CS's WetnessEffects::GetCommonBufferData does.
class WetnessEffectsShaders : public ShaderCollection
{
public:
	WetnessEffectsShaders() : ShaderCollection("WetnessEffects") {};

	struct WetnessSettingsStruct {
		float	MaxRainWetness;
		float	MaxPuddleWetness;
		float	MaxShoreWetness;
		float	ShoreRange;
		float	PuddleRadius;
		float	PuddleMaxAngle;
		float	PuddleMinWetness;
		float	MinRainWetness;
		float	SkinWetness;
		float	WeatherTransitionSpeed;

		bool	EnableRaindropFx;
		bool	EnableSplashes;
		bool	EnableRipples;
		float	RaindropFxRange;
		float	RaindropGridSize;
		float	RaindropInterval;
		float	RaindropChance;
		float	SplashesLifetime;
		float	SplashesStrength;
		float	SplashesMinRadius;
		float	SplashesMaxRadius;
		float	SplashSize;			// scales both splash radii
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
		D3DXVECTOR4		Params2;	// x: PuddleMaxAngle, y: PuddleMinWetness, z: MaxShoreWetness, w: ShoreRange
		D3DXVECTOR4		Drops;		// x: 1 / grid size, y: 1 / interval, z: drop chance, w: interval / ripple lifetime
		D3DXVECTOR4		Splash;		// x: strength, y: lifetime, z: min radius, w: max radius
		D3DXVECTOR4		Ripple;		// x: strength, y: radius, z: breadth, w: raindrop range
		D3DXVECTOR4		Camera;		// xyz: camera position, w: water height (-1e9: none)
		D3DXVECTOR4		Flags;		// x: on, y: splashes, z: ripples, w: ortho map texel size (0: none)
		D3DXVECTOR4		Sun;		// xyz: direction to the sun
	};
	WetnessStruct	Constants;

	float	Wetness = 0.0f;			// eased, 0-1
	float	PuddleWetness = 0.0f;
	float	Raining = 0.0f;
	float	SkinWetnessValue = 0.0f;	// for the skin shaders: Wetness x SkinWetness, exteriors only
	double	RainTime = 0.0;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
};
