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
	Settings->RoughnessScale = TheSettingManager->GetSettingF(Section, "RoughnessScale");
	Settings->Saturation = TheSettingManager->GetSettingF(Section, "Saturation");
	Settings->SkylightingScale = TheSettingManager->GetSettingF(Section, "SkylightingScale");
	Settings->SpecularStrength = TheSettingManager->GetSettingF(Section, "SpecularStrength");
	Settings->VanillaMatchedHighlights = TheSettingManager->GetSettingF(Section, "VanillaMatchedHighlights");
	Settings->DefaultRoughness = TheSettingManager->GetSettingF(Section, "DefaultRoughness");
	Settings->SkyReflectionScale = TheSettingManager->GetSettingF(Section, "SkyReflectionScale");
	Settings->AmbientNormalDetail = TheSettingManager->GetSettingF(Section, "AmbientNormalDetail");
}

void PBRShaders::UpdateSettings() {
	ReadWeatherSettings(&Settings.Default, "Shaders.PBR.Main");
	ReadWeatherSettings(&Settings.Rain, "Shaders.PBR.Rain");
	ReadWeatherSettings(&Settings.Night, "Shaders.PBR.Night");
	ReadWeatherSettings(&Settings.NightRain, "Shaders.PBR.NightRain");
	ReadWeatherSettings(&Settings.Interiors, "Shaders.PBR.Interiors");

	MaterialSettings.LinearLighting = TheSettingManager->GetSettingI("Shaders.PBR.Main", "LinearLighting");
	MaterialSettings.SpecularOnAll = TheSettingManager->GetSettingI("Shaders.PBR.Main", "SpecularOnAll");
	MaterialSettings.SpecularOcclusion = TheSettingManager->GetSettingI("Shaders.PBR.Main", "SpecularOcclusion");
	MaterialSettings.DebugView = TheSettingManager->GetSettingI("Shaders.PBR.Main", "DebugView");
}

// The value of one per-weather setting for the current weather, time and rain.
float PBRShaders::Blend(float PBRSettings::* Member, float rainFactor) {
	float dry = TheShaderManager->GetTransitionValue(Settings.Default.*Member, Settings.Night.*Member, Settings.Interiors.*Member);
	float wet = TheShaderManager->GetTransitionValue(Settings.Rain.*Member, Settings.NightRain.*Member, Settings.Interiors.*Member);
	return std::lerp(dry, wet, rainFactor);
}

void PBRShaders::UpdateConstants() {
	// get max value between rain animator and puddle animator
	float rainFactor = max(TheShaderManager->Effects.WetWorld->Constants.Data.x, TheShaderManager->Effects.WetWorld->Constants.Data.z);

	Constants.Data.x = max(0.0f, Blend(&PBRSettings::SpecularStrength, rainFactor));
	Constants.Data.y = max(0.0f, Blend(&PBRSettings::RoughnessScale, rainFactor));
	Constants.Data.z = Blend(&PBRSettings::LightScale, rainFactor);
	Constants.Data.w = Blend(&PBRSettings::AmbientScale, rainFactor);   // the rain side used the Main value indoors before

	Constants.ExtraData.x = Blend(&PBRSettings::Saturation, rainFactor);
	Constants.ExtraData.y = Blend(&PBRSettings::SkylightingScale, rainFactor);   // hemisphere skylight; 0 disables it
	Constants.ExtraData.z = std::clamp(Blend(&PBRSettings::VanillaMatchedHighlights, rainFactor), 0.0f, 1.0f);
	Constants.ExtraData.w = MaterialSettings.LinearLighting ? 1.0f : 0.0f;

	Constants.SpecularData.x = MaterialSettings.SpecularOnAll ? std::clamp(Blend(&PBRSettings::DefaultRoughness, rainFactor), 0.05f, 1.0f) : -1.0f;
	// Nothing occludes the sky the reflection samples, so indoors it would light every surface
	// from a sky it cannot see.
	Constants.SpecularData.y = TheShaderManager->GameState.isExterior ? max(0.0f, Blend(&PBRSettings::SkyReflectionScale, rainFactor)) : 0.0f;
	Constants.SpecularData.z = MaterialSettings.SpecularOcclusion ? 1.0f : 0.0f;
	Constants.SpecularData.w = std::clamp(Blend(&PBRSettings::AmbientNormalDetail, rainFactor), 0.0f, 1.0f);

	Constants.DebugData.x = (float)std::clamp(MaterialSettings.DebugView, 0, 4);
}
