#pragma once

// Heat haze: distant ground shimmering in the hot air above it. A screen distortion, strongest on far
// surfaces seen near the horizon, driven by how hot it is now -- the time of day (peaking in the early
// afternoon, off at night) and the weather (full when clear, less when cloudy, none in rain or snow or
// while the ground is still wet).
class HeatHazeEffect : public EffectRecord
{
public:
	HeatHazeEffect() : EffectRecord("HeatHaze") {};

	struct HeatHazeSettingsStruct {
		float	Strength;		// largest offset, in pixels at 1080p, at full heat
		float	StartDistance;	// no haze nearer than this
		float	FullDistance;	// full haze from here on
		float	HorizonBand;	// how far above and below the horizon (sine of the view angle) the haze reaches
		float	NoiseScale;		// ripple frequency
		float	Speed;			// how fast the ripples rise
		float	PeakHour;		// hottest hour of the day
		float	CloudyScale;	// heat in cloudy weather, as a fraction of a clear day's
	};
	HeatHazeSettingsStruct	Settings;

	struct HeatHazeStruct {
		D3DXVECTOR4	Data;		// x: offset at full haze (uv), y: start distance, z: full distance, w: horizon band
		D3DXVECTOR4	Noise;		// x: noise scale, y: speed, z: time (seconds), w: heat 0-1 (for debugging)
	};
	HeatHazeStruct	Constants;

	float	Heat = 0.0f;			// how hot it is now, 0-1, eased
	float	WeatherHeat = 1.0f;		// the weather's share, eased over weather changes

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();
};
