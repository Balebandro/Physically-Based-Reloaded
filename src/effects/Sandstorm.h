#pragma once

// Sandstorm: a dust storm's haze and the wind-blown grains in it, drawn over the scene in HDR before tonemapping
// (Sandstorm.fx.hlsl). A storm is windy, dusty weather that is neither rain nor snow (see IsStormNow). It fades in
// and out over a few seconds as one starts and ends, the way rain does.
class SandstormEffect : public EffectRecord
{
public:
	SandstormEffect() : EffectRecord("Sandstorm") {
		Constants.Data = D3DXVECTOR4(0, 0, 0, 0);	// no storm until UpdateConstants says so
		Constants.Dust = D3DXVECTOR4(0, 0, 0, 0);
		Constants.Wind = D3DXVECTOR4(0, 0, 0, 0);
		Constants.Grains = D3DXVECTOR4(0, 0, 0, 0);
		StormAnimator.Initialize(0);
	};

	struct SandstormSettingsStruct {
		float	Density;				// dust thickness: haze optical depth per game unit of distance, at full storm
		float	HeightFalloff;			// altitude (game units) over which the dust thins by a factor of e; thickest near the ground
		float	DustColorR;				// dust colour, sRGB, as it looks in full daylight
		float	DustColorG;
		float	DustColorB;
		float	StreakStrength;			// how bright the wind-blown grains and streaks are against the haze
		float	StreakSpeed;			// how fast they sweep across the screen, in screen heights per second, at medium wind (half that in none, one and a half times it in full wind)
		float	StreakScale;			// how fine the streaks are: streaks per screen height across the wind
		float	NearStreakDistance;		// grains fade out nearer than this (game units), so the weapon and hands are never streaked
		float	SkyDarken;				// sky brightness at full storm, as a share of its clear-weather brightness
		float	GustStrength;			// how far the gusts swing the density and the streaks, either way
		float	WindThreshold;			// the weather's wind speed (0-255) a storm needs
		float	FogDistanceThreshold;	// the sky's fog far plane (game units) a storm needs: closer than this is dusty air
		bool	ForceStorm;				// debug: a storm whatever the weather
	};
	SandstormSettingsStruct	Settings;

	struct SandstormStruct {
		D3DXVECTOR4	Data;		// x: storm strength 0-1 (animated), y: density (gust-scaled), z: height falloff (game units), w: sky darkening at full storm
		D3DXVECTOR4	Dust;		// xyz: dust colour, linear, scaled by the light; w: streak strength (gust-scaled)
		D3DXVECTOR4	Wind;		// x, y: wind direction in the world (unit length, XY); z: wind speed 0-1; w: unused
		D3DXVECTOR4	Grains;		// x: streak scale (per screen height); y: near grain distance (game units); z: streak scroll (noise cells, within one noise period); w: grain scroll (noise cells, within one noise period)
	};
	SandstormStruct	Constants;

	Animator	StormAnimator;	// the storm's strength, eased in and out (Constants.Data.x)

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();

private:
	bool	IsStormNow();
	double	GustTime = 0.0;		// seconds, unwrapped: the gusts' clock (double, so it stays exact)
	double	StreakTravel = 0.0;	// screen heights the streaks have travelled with the wind, unwrapped (double, for the same reason)
};
