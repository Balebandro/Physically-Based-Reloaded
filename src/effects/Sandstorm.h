#pragma once

// Sandstorm, after Kappa's v5 weather update: while the weather is a sandstorm (any weather whose editor ID holds
// Keyword, "sandstorm" by default, in any case), the air fills with wind-driven dust. Billowing clouds of it are
// marched through near the camera and lit by the sun and sky, a dense haze swallows the distance and the sky, and
// thin streaks of sand blow past. It builds and settles with the weather's own transition.
class SandstormEffect : public EffectRecord
{
public:
	SandstormEffect() : EffectRecord("Sandstorm") {};

	struct SandstormSettingsStruct {
		char	Keyword[64];	// a weather whose editor ID holds this (any case) is a sandstorm
		float	Visibility;		// how far one sees through the full storm (game units)
		float	HeightFalloff;	// the dust thins with height above the camera over about this many units
		float	Billowing;		// how much the clouds of dust vary (0 an even haze)
		float	NoiseScale;		// size of the dust clouds (game units)
		float	WindSpeed;		// the dust's speed at the weather's full wind (units per second)
		float	MinWindSpeed;	// the dust's speed with no wind
		float	Streaks;		// the sand blown past the camera
		float	SandColor[3];	// the dust's colour (albedo)
		float	SunScattering;	// how much brighter the dust glows toward the sun
		float	Brightness;		// overall light on the dust
		float	FadeSpeed;		// how fast the storm builds and settles beyond the weather's own transition (per second)
		float	GrassWind;		// grass sways this many times harder at the storm's height, leaning downwind in gusts
		float	TreeWind;		// tree leaves likewise
		float	LightScattering;	// how strongly lamps, fires and other nearby lights glow through the dust (0 off)
		float	EmissiveThreshold;	// a pixel this many times brighter than lit dust counts as glowing in front (fire drawn without depth); 0 off
		float	EmissiveDistance;	// how much dust such a pixel is seen through (units)
		bool	ThroughBlended;	// glass and other see-through blended surfaces write no depth while the storm blows
		bool	Force;			// debugging: the full storm outdoors in any weather
	};
	SandstormSettingsStruct	Settings;

	struct SandstormStruct {
		D3DXVECTOR4	Data;		// x: intensity 0-1, y: density per unit, z: visibility, w: height falloff
		D3DXVECTOR4	Wind;		// x, y: wind direction, z: speed (units/s), w: time (s)
		D3DXVECTOR4	Shape;		// x: billowing, y: noise scale, z: streaks, w: sun scattering
		D3DXVECTOR4	Color;		// rgb: sand albedo, w: brightness
		D3DXVECTOR4	Cover;		// x: the ortho map (the top-down depth map) is there, to keep streaks out of the lee of walls and rocks
		D3DXVECTOR4	WindBoost;	// for the grass and leaf shaders: x grass, y trees, z time (s), w how hard the storm blows (0 off)
		D3DXVECTOR4	Lights;		// x: LightScattering
		D3DXVECTOR4	Emissive;	// x: EmissiveThreshold, y: EmissiveDistance
		D3DXVECTOR4	Water;		// x: 1 with the camera underwater, y: the water surface's height above the camera
	};
	SandstormStruct	Constants;

	float	Intensity = 0.0f;		// how much the storm blows now, eased
	float	Time = 0.0f;			// seconds, wrapped hourly
	void*	LastWeather = nullptr;	// the weathers last checked by name, and what they were
	void*	LastSecond = nullptr;
	bool	FirstIsStorm = false;
	bool	SecondIsStorm = false;
	void*	LoggedWeather = nullptr;	// the weathers last written to the log
	void*	LoggedSecond = nullptr;

	// While the storm blows (ThroughBlended), glass and other see-through blended surfaces leave the world's depth to what
	// lies behind them, so the dust is measured to that (RenderBlendedHook in Render.cpp).
	bool	HidesBlendedDepth() const { return Enabled && Settings.ThroughBlended && Intensity > 0.0f; }
	bool	Underwater = false;		// the camera is underwater (the storm only above the surface)
	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();
	bool	IsSandstorm(TESWeather* Weather);
};
