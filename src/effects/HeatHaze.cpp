#include <algorithm>

#include "HeatHaze.h"

void HeatHazeEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_HeatHazeData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_HeatHazeNoise", &Constants.Noise);
}

void HeatHazeEffect::UpdateSettings() {
	Settings.Strength = max(0.0f, TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "Strength"));
	Settings.StartDistance = max(0.0f, TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "StartDistance"));
	Settings.FullDistance = max(Settings.StartDistance + 1.0f, TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "FullDistance"));
	Settings.HorizonBand = std::clamp(TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "HorizonBand"), 0.02f, 1.0f);
	Settings.NoiseScale = max(1.0f, TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "NoiseScale"));
	Settings.Speed = max(0.0f, TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "Speed"));
	Settings.PeakHour = std::clamp(TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "PeakHour"), 8.0f, 18.0f);
	Settings.CloudyScale = std::clamp(TheSettingManager->GetSettingF("Shaders.HeatHaze.Main", "CloudyScale"), 0.0f, 1.0f);
}

static float SmoothStep(float edge0, float edge1, float x) {
	float t = std::clamp((x - edge0) / max(edge1 - edge0, 1e-4f), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

void HeatHazeEffect::UpdateConstants() {
	float elapsed = std::clamp((float)TheFrameRateManager->ElapsedTime, 0.0f, 0.1f);

	// Time of day: nothing before the sun is fully up, building to the hottest hour, gone by sunset.
	float hour = TheShaderManager->ShaderConst.GameTime.y;
	float sunriseEnd = TheShaderManager->ShaderConst.SunTiming.y;
	float sunsetStart = TheShaderManager->ShaderConst.SunTiming.z;
	float peak = std::clamp(Settings.PeakHour, sunriseEnd + 1.0f, sunsetStart - 1.0f);
	float dayHeat = hour < peak ? SmoothStep(sunriseEnd, peak, hour) : 1.0f - SmoothStep(peak, sunsetStart, hour);

	// Weather: clear skies full, cloudy less, rain and snow none; and none while the ground is wet.
	float weatherTarget = 1.0f;
	if (TheShaderManager->GameState.isCloudy) weatherTarget = Settings.CloudyScale;
	if (TheShaderManager->GameState.isRainy || TheShaderManager->GameState.isSnow) weatherTarget = 0.0f;
	WetnessEffectsShaders* wet = TheShaderManager->Shaders.Wetness;
	if (wet) weatherTarget *= 1.0f - std::clamp(wet->RainFactor(), 0.0f, 1.0f);
	// Eased over about ten seconds, so a weather change fades the haze rather than switching it.
	float ease = min(1.0f, elapsed / 10.0f);
	WeatherHeat += (weatherTarget - WeatherHeat) * ease;

	Heat = dayHeat * WeatherHeat;
	if (!TheShaderManager->GameState.isExterior || TheShaderManager->GameState.isUnderwater) Heat = 0.0f;

	// The offset in uv, sized so a given Strength looks the same at any resolution (pixels at 1080p).
	Constants.Data.x = Settings.Strength * Heat / 1080.0f;
	Constants.Data.y = Settings.StartDistance;
	Constants.Data.z = Settings.FullDistance;
	Constants.Data.w = Settings.HorizonBand;

	Constants.Noise.x = Settings.NoiseScale;
	Constants.Noise.y = Settings.Speed;
	Constants.Noise.z = fmodf(Constants.Noise.z + elapsed, 3600.0f);
	Constants.Noise.w = Heat;
}

bool HeatHazeEffect::ShouldRender() {
	return Constants.Data.x > 1e-6f;
}
