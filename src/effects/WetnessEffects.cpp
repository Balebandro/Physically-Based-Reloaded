#include <algorithm>

#include "WetnessEffects.h"

void WetnessEffectsShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_WetnessData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_WetnessParams", &Constants.Params);
	TheShaderManager->RegisterConstant("TESR_WetnessParams2", &Constants.Params2);
	TheShaderManager->RegisterConstant("TESR_WetnessDrops", &Constants.Drops);
	TheShaderManager->RegisterConstant("TESR_WetnessSplash", &Constants.Splash);
	TheShaderManager->RegisterConstant("TESR_WetnessRipple", &Constants.Ripple);
	TheShaderManager->RegisterConstant("TESR_WetnessCamera", &Constants.Camera);
	TheShaderManager->RegisterConstant("TESR_WetnessFlags", &Constants.Flags);
	TheShaderManager->RegisterConstant("TESR_WetnessSun", &Constants.Sun);
}

void WetnessEffectsShaders::UpdateSettings() {
	const char* main = "Shaders.WetnessEffects.Main";
	const char* drops = "Shaders.WetnessEffects.Raindrops";
	const char* debug = "Shaders.WetnessEffects.Debug";

	Settings.MaxRainWetness = std::clamp(TheSettingManager->GetSettingF(main, "MaxRainWetness"), 0.0f, 2.5f);
	Settings.MaxPuddleWetness = std::clamp(TheSettingManager->GetSettingF(main, "MaxPuddleWetness"), 0.0f, 6.0f);
	Settings.MaxShoreWetness = std::clamp(TheSettingManager->GetSettingF(main, "MaxShoreWetness"), 0.0f, 1.0f);
	Settings.ShoreRange = std::clamp(TheSettingManager->GetSettingF(main, "ShoreRange"), 1.0f, 256.0f);
	Settings.PuddleRadius = std::clamp(TheSettingManager->GetSettingF(main, "PuddleRadius"), 0.1f, 3.0f);
	Settings.PuddleMaxAngle = std::clamp(TheSettingManager->GetSettingF(main, "PuddleMaxAngle"), 0.6f, 1.0f);
	Settings.PuddleMinWetness = std::clamp(TheSettingManager->GetSettingF(main, "PuddleMinWetness"), 0.0f, 1.0f);
	Settings.MinRainWetness = std::clamp(TheSettingManager->GetSettingF(main, "MinRainWetness"), 0.0f, 0.9f);
	Settings.SkinWetness = std::clamp(TheSettingManager->GetSettingF(main, "SkinWetness"), 0.0f, 1.0f);
	Settings.WeatherTransitionSpeed = std::clamp(TheSettingManager->GetSettingF(main, "WeatherTransitionSpeed"), 0.2f, 8.0f);

	Settings.EnableRaindropFx = TheSettingManager->GetSettingI(drops, "EnableRaindropFx") != 0;
	Settings.EnableSplashes = TheSettingManager->GetSettingI(drops, "EnableSplashes") != 0;
	Settings.EnableRipples = TheSettingManager->GetSettingI(drops, "EnableRipples") != 0;
	Settings.RaindropFxRange = std::clamp(TheSettingManager->GetSettingF(drops, "RaindropFxRange"), 0.0f, 4096.0f);
	Settings.RaindropGridSize = std::clamp(TheSettingManager->GetSettingF(drops, "RaindropGridSize"), 1.0f, 32.0f);
	Settings.RaindropInterval = std::clamp(TheSettingManager->GetSettingF(drops, "RaindropInterval"), 0.1f, 4.0f);
	Settings.RaindropChance = std::clamp(TheSettingManager->GetSettingF(drops, "RaindropChance"), 0.0f, 1.0f);
	Settings.SplashesLifetime = std::clamp(TheSettingManager->GetSettingF(drops, "SplashesLifetime"), 0.1f, 20.0f);
	Settings.SplashesStrength = std::clamp(TheSettingManager->GetSettingF(drops, "SplashesStrength"), 0.0f, 2.0f);
	Settings.SplashesMinRadius = std::clamp(TheSettingManager->GetSettingF(drops, "SplashesMinRadius"), 0.0f, 1.0f);
	Settings.SplashesMaxRadius = std::clamp(TheSettingManager->GetSettingF(drops, "SplashesMaxRadius"), Settings.SplashesMinRadius, 1.0f);
	// 0 (a missing key) reads as the default 1.
	float splashSize = TheSettingManager->GetSettingF(drops, "SplashSize");
	Settings.SplashSize = splashSize > 0.0f ? std::clamp(splashSize, 0.1f, 3.0f) : 1.0f;
	Settings.RippleStrength = std::clamp(TheSettingManager->GetSettingF(drops, "RippleStrength"), 0.0f, 3.0f);
	Settings.RippleRadius = std::clamp(TheSettingManager->GetSettingF(drops, "RippleRadius"), 0.1f, 2.0f);
	Settings.RippleBreadth = std::clamp(TheSettingManager->GetSettingF(drops, "RippleBreadth"), 0.05f, 1.0f);
	Settings.RippleLifetime = std::clamp(TheSettingManager->GetSettingF(drops, "RippleLifetime"), 0.05f, 4.0f);

	Settings.WetnessOverride = TheSettingManager->GetSettingF(debug, "WetnessOverride");
	Settings.PuddleOverride = TheSettingManager->GetSettingF(debug, "PuddleOverride");
	Settings.RainOverride = TheSettingManager->GetSettingF(debug, "RainOverride");
	Settings.ShowCover = TheSettingManager->GetSettingI(debug, "ShowCover") != 0;
}

static float LinearStep(float edge0, float edge1, float x) {
	return std::clamp((x - edge0) / max(edge1 - edge0, 1e-4f), 0.0f, 1.0f);
}

static bool IsRainy(TESWeather* weather) {
	return weather && weather->GetWeatherType() == TESWeather::WeatherType::kType_Rainy;
}

void WetnessEffectsShaders::UpdateConstants() {
	float elapsed = std::clamp((float)TheFrameRateManager->ElapsedTime, 0.0f, 0.25f);
	bool exterior = TheShaderManager->GameState.isExterior;
	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	bool on = Enabled && exterior && WorldSky;

	// How rainy the weather is, as CS reads it: the current weather fading in over the transition, the
	// last one fading out. Wetness follows the rain in; puddles grow as its square and outlast it,
	// holding while the old rainy weather fades. Interiors keep the state they were entered with.
	if (on) {
		TESWeather* current = WorldSky->firstWeather;
		TESWeather* last = WorldSky->secondWeather;
		float pct = std::clamp(WorldSky->weatherPercent, 0.0f, 1.0f);

		float raining = 0.0f, wetness = 0.0f, puddles = 0.0f;
		if (IsRainy(current)) {
			float w = LinearStep(0.25f, 1.0f, pct);
			raining += w;
			wetness += w;
			puddles += w * w;
		}
		if (IsRainy(last) && last != current) {
			raining += 1.0f - LinearStep(0.0f, 0.75f, pct);
			float w = 1.0f - LinearStep(0.5f, 1.0f, pct);
			wetness += w;
			puddles += powf(max(w, 1.0f - pct), 0.25f);
		}
		raining = min(raining, 1.0f);
		wetness = min(wetness, 1.0f);
		puddles = min(puddles, 1.0f);


		if (Settings.WetnessOverride >= 0.0f) wetness = Settings.WetnessOverride;
		if (Settings.PuddleOverride >= 0.0f) puddles = Settings.PuddleOverride;
		if (Settings.RainOverride >= 0.0f) raining = Settings.RainOverride;

		// Eased: WeatherTransitionSpeed 3 takes about 20 s to soak or dry; puddles dry three times slower.
		float rate = Settings.WeatherTransitionSpeed / 60.0f * elapsed;
		auto approach = [](float value, float target, float step) {
			return value < target ? min(target, value + step) : max(target, value - step);
		};
		Wetness = approach(Wetness, wetness, rate);
		PuddleWetness = approach(PuddleWetness, puddles, puddles > PuddleWetness ? rate : rate / 3.0f);
		Raining = approach(Raining, raining, rate * 4.0f);
		if (Settings.WetnessOverride >= 0.0f) Wetness = wetness;
		if (Settings.PuddleOverride >= 0.0f) PuddleWetness = puddles;
		if (Settings.RainOverride >= 0.0f) Raining = raining;
	}

	RainTime += elapsed;
	if (RainTime > 3600.0) RainTime -= 3600.0;   // keeps the drop hashes precise; one jump an hour

	// The cell's water, for shore wetness.
	float waterHeight = -1e9f;
	if (on && Settings.MaxShoreWetness > 0.0f && Tes && Player && WorldSceneGraph) {
		TESWaterForm* water = nullptr;
		float height = Tes->GetWaterHeight(Player, WorldSceneGraph, &water);
		if (water && fabsf(height) < 1e7f) waterHeight = height;
	}

	bool active = on && (Wetness > 0.0f || PuddleWetness > 0.0f || Raining > 0.0f || waterHeight > -1e8f);
	SkinWetnessValue = on ? Wetness * Settings.SkinWetness : 0.0f;

	Constants.Data = D3DXVECTOR4(Wetness, PuddleWetness, Raining, (float)RainTime);
	Constants.Params = D3DXVECTOR4(Settings.MaxRainWetness, Settings.MaxPuddleWetness, Settings.MinRainWetness, Settings.PuddleRadius);
	Constants.Params2 = D3DXVECTOR4(Settings.PuddleMaxAngle, Settings.PuddleMinWetness, Settings.MaxShoreWetness, Settings.ShoreRange);
	Constants.Drops = D3DXVECTOR4(1.0f / Settings.RaindropGridSize, 1.0f / Settings.RaindropInterval,
		Settings.RaindropChance * Raining * Raining, Settings.RaindropInterval / Settings.RippleLifetime);
	// SplashSize scales both radii. They are in raindrop cells, and the shader looks one cell around
	// (Includes/Wetness.hlsl, WetRainDrops), so a radius past one cell would be cut off at the cell edges.
	Constants.Splash = D3DXVECTOR4(Settings.SplashesStrength, Settings.SplashesLifetime,
		min(Settings.SplashesMinRadius * Settings.SplashSize, 1.0f), min(Settings.SplashesMaxRadius * Settings.SplashSize, 1.0f));
	Constants.Ripple = D3DXVECTOR4(Settings.RippleStrength, Settings.RippleRadius, Settings.RippleBreadth, Settings.EnableRaindropFx ? Settings.RaindropFxRange : 0.0f);

	Constants.Camera = D3DXVECTOR4(TheRenderManager->CameraPosition.x, TheRenderManager->CameraPosition.y, TheRenderManager->CameraPosition.z, waterHeight);

	// Rain occlusion: NVR's top-down ortho depth map, asked for while anything is wet.
	float orthoTexel = 0.0f;
	ShadowsExteriorEffect* shadows = TheShaderManager->Effects.ShadowsExteriors;
	if (active && shadows) {
		TheShaderManager->orthoRequired = true;
		orthoTexel = shadows->ShadowMaps[ShadowsExteriorEffect::MapOrtho].ShadowMapInverseResolution;
	}

	Constants.Flags = D3DXVECTOR4(active ? 1.0f : 0.0f,
		Settings.EnableRaindropFx && Settings.EnableSplashes ? 1.0f : 0.0f,
		Settings.EnableRaindropFx && Settings.EnableRipples ? 1.0f : 0.0f,
		orthoTexel);
	Constants.Sun = TheShaderManager->ShaderConst.SunDir;
	Constants.Sun.w = Settings.ShowCover && exterior ? 1.0f : 0.0f;

	// The debug view needs the ortho map even when nothing is wet.
	if (Settings.ShowCover && exterior && shadows && Enabled) {
		TheShaderManager->orthoRequired = true;
		Constants.Flags.w = shadows->ShadowMaps[ShadowsExteriorEffect::MapOrtho].ShadowMapInverseResolution;
	}
}
