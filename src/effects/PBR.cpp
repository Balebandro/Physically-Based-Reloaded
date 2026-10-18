#include <algorithm>

#include "PBR.h"

void PBRShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_PBRData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_PBRExtraData", &Constants.ExtraData);
	TheShaderManager->RegisterConstant("TESR_PBRSpecularData", &Constants.SpecularData);
	TheShaderManager->RegisterConstant("TESR_PBRDebugData", &Constants.DebugData);
}

static void ReadWeatherSettings(PBRShaders::PBRSettings* Settings, const char* Section) {
	Settings->LightScale = TheSettingManager->GetSettingF(Section, "LightingScale");
	Settings->AmbientScale = TheSettingManager->GetSettingF(Section, "AmbientScale");
	Settings->SkylightingScale = TheSettingManager->GetSettingF(Section, "SkylightingScale");
	Settings->MetalnessScale = std::clamp(TheSettingManager->GetSettingF(Section, "MetalnessScale"), 0.0f, 1.0f);
	Settings->AOScale = std::clamp(TheSettingManager->GetSettingF(Section, "AOScale"), 0.0f, 1.0f);
	Settings->RoughnessScale = std::clamp(TheSettingManager->GetSettingF(Section, "RoughnessScale"), 1.0f, 2.0f);   // rougher only
}

void PBRShaders::UpdateSettings() {
	ReadWeatherSettings(&Settings.Default, "Shaders.PBR.Main");
	ReadWeatherSettings(&Settings.Rain, "Shaders.PBR.Rain");
	ReadWeatherSettings(&Settings.Night, "Shaders.PBR.Night");
	ReadWeatherSettings(&Settings.NightRain, "Shaders.PBR.NightRain");
	ReadWeatherSettings(&Settings.Interiors, "Shaders.PBR.Interiors");

	MaterialSettings.LinearLighting = TheSettingManager->GetSettingI("Shaders.PBR.Main", "LinearLighting");
	MaterialSettings.MergeLightPasses = TheSettingManager->GetSettingI("Shaders.PBR.Main", "MergeLightPasses");
	MaterialSettings.KeepOffscreenLights = TheSettingManager->GetSettingI("Shaders.PBR.Main", "KeepOffscreenLights");
	MaterialSettings.VanillaEnvMapOnPBR = TheSettingManager->GetSettingI("Shaders.PBR.Main", "VanillaEnvMapOnPBR");
	MaterialSettings.PBRLinearLighting = std::clamp(TheSettingManager->GetSettingF("Shaders.PBR.Main", "PBRLinearLighting"), 0.0f, 1.0f);
	MaterialSettings.LightingModel = std::clamp(TheSettingManager->GetSettingI("Shaders.PBR.Main", "LightingModel"), 0, 1);
	MaterialSettings.DebugView = TheSettingManager->GetSettingI("Shaders.PBR.Main", "DebugView");
}

// The value of one per-weather setting for the current weather, time and rain.
float PBRShaders::Blend(float PBRSettings::* Member, float rainFactor) {
	float dry = TheShaderManager->GetTransitionValue(Settings.Default.*Member, Settings.Night.*Member, Settings.Interiors.*Member);
	float wet = TheShaderManager->GetTransitionValue(Settings.Rain.*Member, Settings.NightRain.*Member, Settings.Interiors.*Member);
	return std::lerp(dry, wet, rainFactor);
}

void PBRShaders::UpdateConstants() {
	// how wet the weather has made things (Wetness Effects' rain and wetness)
	float rainFactor = TheShaderManager->Shaders.Wetness ? TheShaderManager->Shaders.Wetness->RainFactor() : 0.0f;

	Constants.Data.x = Blend(&PBRSettings::MetalnessScale, rainFactor);   // the _rmaos metalness scale (Object.hlsl setupMaterial)
	Constants.Data.y = Blend(&PBRSettings::AOScale, rainFactor);   // the _rmaos AO strength (Object.hlsl setupMaterial)
	Constants.Data.z = Blend(&PBRSettings::LightScale, rainFactor);
	Constants.Data.w = Blend(&PBRSettings::AmbientScale, rainFactor);

	Constants.ExtraData.x = Blend(&PBRSettings::RoughnessScale, rainFactor);   // the _rmaos roughness scale (Object.hlsl setupMaterial)
	Constants.ExtraData.y = Blend(&PBRSettings::SkylightingScale, rainFactor);   // hemisphere skylight; 0 disables it
	Constants.ExtraData.z = MaterialSettings.PBRLinearLighting;   // authored materials' linear lighting amount (Object.hlsl)
	Constants.ExtraData.w = MaterialSettings.LinearLighting ? 1.0f : 0.0f;

	Constants.SpecularData = D3DXVECTOR4((float)MaterialSettings.LightingModel, TheShaderManager->GameState.isExterior ? 1.0f : 0.0f, 0.0f, 1.0f);   // x: lighting model of authored materials
	Constants.DebugData.x = (float)std::clamp(MaterialSettings.DebugView, 0, 5);
}
