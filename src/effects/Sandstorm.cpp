#include <algorithm>
#include <cctype>
#include <string>

#include "Sandstorm.h"

void SandstormEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SandstormData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_SandstormWind", &Constants.Wind);
	TheShaderManager->RegisterConstant("TESR_SandstormShape", &Constants.Shape);
	TheShaderManager->RegisterConstant("TESR_SandstormColor", &Constants.Color);
	TheShaderManager->RegisterConstant("TESR_SandstormCover", &Constants.Cover);
	TheShaderManager->RegisterConstant("TESR_WindBoost", &Constants.WindBoost);
	TheShaderManager->RegisterConstant("TESR_SandstormLights", &Constants.Lights);
	TheShaderManager->RegisterConstant("TESR_SandstormEmissive", &Constants.Emissive);
	TheShaderManager->RegisterConstant("TESR_SandstormWater", &Constants.Water);
}

void SandstormEffect::UpdateSettings() {
	const char* main = "Shaders.Sandstorm.Main";
	char keyword[MAX_PATH] = "";
	TheSettingManager->GetSettingS(main, "Keyword", keyword);
	std::string k = keyword;
	k.erase(std::remove(k.begin(), k.end(), '"'), k.end());
	if (k.empty()) k = "sandstorm";
	for (auto& c : k) c = (char)tolower((unsigned char)c);
	strncpy_s(Settings.Keyword, k.c_str(), _TRUNCATE);
	LastWeather = LastSecond = nullptr;   // a new keyword: look at the weathers' names again

	Settings.Visibility = std::clamp(TheSettingManager->GetSettingF(main, "Visibility"), 200.0f, 30000.0f);
	Settings.HeightFalloff = std::clamp(TheSettingManager->GetSettingF(main, "HeightFalloff"), 200.0f, 50000.0f);
	Settings.Billowing = std::clamp(TheSettingManager->GetSettingF(main, "Billowing"), 0.0f, 1.0f);
	Settings.NoiseScale = std::clamp(TheSettingManager->GetSettingF(main, "NoiseScale"), 100.0f, 10000.0f);
	Settings.WindSpeed = std::clamp(TheSettingManager->GetSettingF(main, "WindSpeed"), 0.0f, 5000.0f);
	Settings.MinWindSpeed = std::clamp(TheSettingManager->GetSettingF(main, "MinWindSpeed"), 0.0f, 5000.0f);
	Settings.Streaks = std::clamp(TheSettingManager->GetSettingF(main, "Streaks"), 0.0f, 4.0f);
	Settings.SandColor[0] = std::clamp(TheSettingManager->GetSettingF(main, "SandColorR"), 0.0f, 1.0f);
	Settings.SandColor[1] = std::clamp(TheSettingManager->GetSettingF(main, "SandColorG"), 0.0f, 1.0f);
	Settings.SandColor[2] = std::clamp(TheSettingManager->GetSettingF(main, "SandColorB"), 0.0f, 1.0f);
	Settings.SunScattering = std::clamp(TheSettingManager->GetSettingF(main, "SunScattering"), 0.0f, 10.0f);
	Settings.Brightness = std::clamp(TheSettingManager->GetSettingF(main, "Brightness"), 0.0f, 10.0f);
	Settings.FadeSpeed = std::clamp(TheSettingManager->GetSettingF(main, "FadeSpeed"), 0.01f, 10.0f);
	Settings.GrassWind = std::clamp(TheSettingManager->GetSettingF(main, "GrassWind"), 1.0f, 10.0f);
	Settings.TreeWind = std::clamp(TheSettingManager->GetSettingF(main, "TreeWind"), 1.0f, 10.0f);
	Settings.LightScattering = std::clamp(TheSettingManager->GetSettingF(main, "LightScattering"), 0.0f, 20.0f);
	Settings.EmissiveThreshold = std::clamp(TheSettingManager->GetSettingF(main, "EmissiveThreshold"), 0.0f, 50.0f);
	Settings.EmissiveDistance = std::clamp(TheSettingManager->GetSettingF(main, "EmissiveDistance"), 0.0f, 5000.0f);
	Settings.Force = TheSettingManager->GetSettingI(main, "Force") != 0;
	Settings.ThroughBlended = TheSettingManager->GetSettingI(main, "ThroughBlended") != 0;
}

// A sandstorm by name: the weather's editor ID holds the keyword, in any case.
bool SandstormEffect::IsSandstorm(TESWeather* Weather) {
	if (!Weather) return false;
	const char* name = ((TESWeatherEx*)Weather)->GetEditorName();
	if (!name || !*name) return false;
	std::string lower = name;
	for (auto& c : lower) c = (char)tolower((unsigned char)c);
	return lower.find(Settings.Keyword) != std::string::npos;
}

void SandstormEffect::UpdateConstants() {
	float elapsed = std::clamp((float)TheFrameRateManager->ElapsedTime, 0.0f, 0.1f);
	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	// Underwater the storm still blows above the surface: the shader puts dust only on what is seen past it.
	bool exterior = TheShaderManager->GameState.isExterior;

	// How much of the weather is the storm: the current weather fading in over the transition, the last one
	// fading out. Names are looked at only when the weathers change.
	float target = 0.0f;
	if (WorldSky && exterior) {
		TESWeather* first = WorldSky->firstWeather;
		TESWeather* second = WorldSky->secondWeather;
		if (first != LastWeather || second != LastSecond) {
			FirstIsStorm = IsSandstorm(first);
			SecondIsStorm = second && second != first && IsSandstorm(second);
			const char* firstName = first ? ((TESWeatherEx*)first)->GetEditorName() : nullptr;
			const char* secondName = second ? ((TESWeatherEx*)second)->GetEditorName() : nullptr;
			if (first != LoggedWeather || second != LoggedSecond) Logger::Log("Sandstorm: weather %s%s, from %s%s", firstName && *firstName ? firstName : "(no name)", FirstIsStorm ? " (a sandstorm)" : "",
				secondName && *secondName ? secondName : "(none)", SecondIsStorm ? " (a sandstorm)" : "");
			LoggedWeather = first;
			LoggedSecond = second;
			LastWeather = first;
			LastSecond = second;
		}
		float pct = std::clamp(WorldSky->weatherPercent, 0.0f, 1.0f);
		bool transition = second && second != first;
		if (FirstIsStorm) target += transition ? pct : 1.0f;
		if (SecondIsStorm) target += 1.0f - pct;
		target = min(target, 1.0f);
	}
	if (Settings.Force && exterior) target = 1.0f;

	float step = Settings.FadeSpeed * elapsed;
	Intensity = Intensity < target ? min(target, Intensity + step) : max(target, Intensity - step);

	// The weather's wind: its direction (radians, or degrees in some data) and its speed scaling the dust's.
	float windDirection = WorldSky ? WorldSky->windDirection : 0.0f;
	if (windDirection > 6.3f) windDirection *= 0.0174532925f;
	float windSpeed = WorldSky ? std::clamp(WorldSky->windSpeed, 0.0f, 1.0f) : 0.5f;

	// The full storm leaves about 5% of the scene at Visibility.
	Constants.Data = D3DXVECTOR4(Intensity, 3.0f / Settings.Visibility, Settings.Visibility, Settings.HeightFalloff);
	Constants.Wind.x = sinf(windDirection);
	Constants.Wind.y = cosf(windDirection);
	Constants.Wind.z = Settings.MinWindSpeed + (Settings.WindSpeed - Settings.MinWindSpeed) * windSpeed;
	Time = fmodf(Time + elapsed, 3600.0f);
	Constants.Wind.w = Time;
	Constants.Shape = D3DXVECTOR4(Settings.Billowing, Settings.NoiseScale, Settings.Streaks, Settings.SunScattering);
	Constants.Color = D3DXVECTOR4(Settings.SandColor[0], Settings.SandColor[1], Settings.SandColor[2], Settings.Brightness);
	Constants.WindBoost = D3DXVECTOR4(Settings.GrassWind, Settings.TreeWind, Time, Intensity);
	Constants.Lights = D3DXVECTOR4(Settings.LightScattering, 0.0f, 0.0f, 0.0f);
	Constants.Emissive = D3DXVECTOR4(Settings.EmissiveThreshold, Settings.EmissiveDistance, 0.0f, 0.0f);
	Underwater = TheShaderManager->GameState.isUnderwater && Tes && Player && WorldSceneGraph;
	Constants.Water = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
	if (Underwater) {
		TESWaterForm* water = nullptr;
		const float surface = Tes->GetWaterHeight(Player, WorldSceneGraph, &water);
		Constants.Water = D3DXVECTOR4(1.0f, max(surface - TheRenderManager->CameraPosition.z, 0.0f), 0.0f, 0.0f);
		static bool logged = false;
		if (!logged) {
			Logger::Log("Sandstorm: underwater, the surface at %.0f, the camera at %.0f", surface, TheRenderManager->CameraPosition.z);
			logged = true;
		}
	}

	// The streaks keep out of the lee of walls and rocks by NVR's top-down depth map, asked for while they show.
	ShadowsExteriorEffect* shadows = TheShaderManager->Effects.ShadowsExteriors;
	bool cover = shadows && shadows->Enabled && Intensity > 0.0f && Settings.Streaks > 0.0f;
	if (cover) TheShaderManager->orthoRequired = true;
	Constants.Cover = D3DXVECTOR4(cover ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f);
}

bool SandstormEffect::ShouldRender() {
	return Intensity > 0.001f;
}
