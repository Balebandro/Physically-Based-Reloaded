#include <algorithm>
#include <cmath>

#include "Sandstorm.h"

// The fog's brightness at which the dust shows exactly as set: a typical daytime fog, linear luma. Brighter fog
// (a bright day) does not brighten the dust past its colour; darker fog (dusk, night) darkens it.
static const float DayFogLuma = 0.3f;

// The streak noise repeats every this many cells along the wind (NoisePeriod in Sandstorm.fx.hlsl). The scroll is kept
// within one period, so it stays precise however long a storm runs, and wraps without a seam.
static const double NoisePeriod = 256.0;

// sRGB to linear: the same curve the shaders' linearize() applies to the game's colours.
static float ToLinear(float c) {
	c = std::clamp(c, 0.0f, 1.0f);
	return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

// Hash in 0-1 for a whole number, for the gusts.
static float Hash1(float n) {
	float p = n * 0.1031f;
	p -= floorf(p);
	p *= p + 33.33f;
	p *= p + p;
	return p - floorf(p);
}

// Smooth noise in 0-1 over one period of `period` whole units: a hashed value at each whole number, blended between
// them, and the last blends back into the first, so the noise repeats seamlessly.
static float Noise1(float x, float period) {
	float i = floorf(x);
	float f = x - i;
	float u = f * f * (3.0f - 2.0f * f);
	float i0 = i - period * floorf(i / period);
	float i1 = i0 + 1.0f;
	i1 -= period * floorf(i1 / period);
	return Hash1(i0) + (Hash1(i1) - Hash1(i0)) * u;
}

void SandstormEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SandstormData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_SandstormDust", &Constants.Dust);
	TheShaderManager->RegisterConstant("TESR_SandstormWind", &Constants.Wind);
	TheShaderManager->RegisterConstant("TESR_SandstormGrains", &Constants.Grains);
}

void SandstormEffect::UpdateSettings() {
	Settings.Density = max(0.0f, TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "Density"));
	Settings.HeightFalloff = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "HeightFalloff"), 1.0f, 100000.0f);
	Settings.DustColorR = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "DustColorR"), 0.0f, 1.0f);
	Settings.DustColorG = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "DustColorG"), 0.0f, 1.0f);
	Settings.DustColorB = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "DustColorB"), 0.0f, 1.0f);
	Settings.StreakStrength = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "StreakStrength"), 0.0f, 1.0f);
	Settings.StreakSpeed = max(0.0f, TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "StreakSpeed"));
	Settings.StreakScale = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "StreakScale"), 1.0f, 1000.0f);
	Settings.NearStreakDistance = max(1.0f, TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "NearStreakDistance"));
	Settings.SkyDarken = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "SkyDarken"), 0.0f, 1.0f);
	Settings.GustStrength = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "GustStrength"), 0.0f, 1.0f);
	Settings.WindThreshold = std::clamp(TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "WindThreshold"), 0.0f, 255.0f);
	Settings.FogDistanceThreshold = max(0.0f, TheSettingManager->GetSettingF("Shaders.Sandstorm.Main", "FogDistanceThreshold"));
	Settings.ForceStorm = TheSettingManager->GetSettingI("Shaders.Sandstorm.Main", "ForceStorm") != 0;
}

// A storm: windy, dusty weather that is neither rain nor snow. Dusty means the sky's fog far plane (Sky::fogFarPlane, the
// fog the game is drawing now, blended through the day and through weather changes; outdoors that is ShaderConst.fogData.y)
// is closer than FogDistanceThreshold. ForceStorm makes a storm whatever the weather.
bool SandstormEffect::IsStormNow() {
	if (Settings.ForceStorm) return true;
	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	if (!WorldSky) return false;
	// The weather choice Rain makes: the incoming one past the middle of a transition, the outgoing one before it.
	TESWeather* Weather = WorldSky->weatherPercent >= 0.5f ? WorldSky->firstWeather : WorldSky->secondWeather;
	if (!Weather) Weather = WorldSky->firstWeather;
	if (!Weather) return false;
	if (Weather->GetWeatherType() == TESWeather::WeatherType::kType_Rainy || Weather->GetWeatherType() == TESWeather::WeatherType::kType_Snow) return false;
	if ((float)Weather->GetWindSpeed() < Settings.WindThreshold) return false;
	return WorldSky->fogFarPlane < Settings.FogDistanceThreshold;
}

void SandstormEffect::UpdateConstants() {
	// The storm, edge-detected the way RainEffect does rain: the Animator eases the strength up when one starts and
	// down when it ends. Its clock runs in game hours, so these durations are a few real seconds at the usual time scale.
	bool storm = IsStormNow();
	if (storm && !StormAnimator.switched) {
		StormAnimator.switched = true;
		StormAnimator.Start(0.05f, 1);
	}
	else if (!storm && StormAnimator.switched) {
		StormAnimator.switched = false;
		StormAnimator.Start(0.07f, 0);
	}
	Constants.Data.x = StormAnimator.GetValue();

	// Wind: the sky's wind direction (radians, in the world's XY plane) and its speed. The shader turns the direction
	// into the screen. ShaderConst.windSpeed is the sky's own wind speed, taken as normalised 0-1 (see TASK-NOTES).
	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	float windAngle = WorldSky ? WorldSky->windDirection : 0.0f;
	float windSpeed = std::clamp(TheShaderManager->ShaderConst.windSpeed, 0.0f, 1.0f);
	Constants.Wind.x = cosf(windAngle);
	Constants.Wind.y = sinf(windAngle);
	Constants.Wind.z = windSpeed;
	Constants.Wind.w = 0.0f;

	// The clocks, in double so they stay exact: the gusts', and how far the streaks have travelled with the wind
	// (screen heights per second, faster in a stronger wind).
	double elapsed = std::clamp((double)TheFrameRateManager->ElapsedTime, 0.0, 0.1);
	GustTime += elapsed;
	StreakTravel += elapsed * Settings.StreakSpeed * (0.5 + windSpeed);

	// Gusts: slow noise over time, about one gust every five seconds (0.2 per second of noise, one unit per lattice
	// cell), swinging the density and the streaks by +-GustStrength. Repeats every 720 noise units, an hour, without a jump.
	float gust = max(0.0f, 1.0f + Settings.GustStrength * (2.0f * Noise1((float)fmod(GustTime * 0.2, 720.0), 720.0f) - 1.0f));

	// Dust colour: the setting, linearised the way the shaders linearise the game's colours, scaled by the light. The light
	// is the luma of the sky's fog colour (the colour VolumetricFog takes as its HDR fog, linearised the same way) against a
	// typical daytime fog: full by day, so the dust shows as set, and lower at dusk and night when the game's fog goes dark.
	const D3DXVECTOR4& fog = TheShaderManager->ShaderConst.fogColor;
	float fogLuma = 0.2126f * ToLinear(fog.x) + 0.7152f * ToLinear(fog.y) + 0.0722f * ToLinear(fog.z);
	float light = std::clamp(fogLuma / DayFogLuma, 0.0f, 1.0f);
	Constants.Dust.x = ToLinear(Settings.DustColorR) * light;
	Constants.Dust.y = ToLinear(Settings.DustColorG) * light;
	Constants.Dust.z = ToLinear(Settings.DustColorB) * light;
	Constants.Dust.w = Settings.StreakStrength * gust;

	Constants.Data.y = Settings.Density * gust;
	Constants.Data.z = Settings.HeightFalloff;
	Constants.Data.w = Settings.SkyDarken;

	// Grains: the streaks' scale and the near distance, and how far each noise layer has scrolled along the wind, in its own
	// cells, within one period. The streak layer is stretched along the wind, about 17 times as long along as across
	// (streakCoord in the shader); the grain layer is 2.5 times finer across, about 4 times as long along as across, and
	// it moves 1.6 times as fast (grainCoord).
	Constants.Grains.x = Settings.StreakScale;
	Constants.Grains.y = Settings.NearStreakDistance;
	Constants.Grains.z = (float)fmod(StreakTravel * Settings.StreakScale * 0.06, NoisePeriod);
	Constants.Grains.w = (float)fmod(StreakTravel * 1.6 * Settings.StreakScale * 0.625, NoisePeriod);
}

bool SandstormEffect::ShouldRender() {
	return Constants.Data.x > 0.0f &&
		TheShaderManager->GameState.isExterior &&
		!TheShaderManager->GameState.isUnderwater;
}
