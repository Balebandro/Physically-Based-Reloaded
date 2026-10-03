#include <algorithm>

#include "Skin.h"

void SkinShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SkinData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_SkinExtraData", &Constants.ExtraData);
	TheShaderManager->RegisterConstant("TESR_SkinDebugData", &Constants.DebugData);
}

void SkinShaders::UpdateConstants() {
	const bool isExterior = TheShaderManager->GameState.isExterior;
	const MaterialStruct& Material = isExterior ? Exterior : Interior;
	Constants.Data.x = Material.SpecularStrength;
	Constants.Data.y = Material.Roughness;
	Constants.Data.z = Material.PerPixelWidth;   // per-pixel diffusion, where the screen-space blur does not reach
	Constants.Data.w = Material.Translucency;
	Constants.ExtraData.z = Material.ShadowScatter;
	Constants.ExtraData.w = Material.VanillaMatchedHighlights;

	// Nothing occludes the sky the reflection samples, so indoors it would light skin from a sky
	// it cannot see (the object shaders do the same).
	Constants.ExtraData.x = isExterior ? SkyReflectionScale : 0.0f;

	// Rain wets skin: smoother and shinier. Same rain/puddle factor the PBR and terrain shaders use.
	float rainFactor = max(TheShaderManager->Effects.WetWorld->Constants.Data.x, TheShaderManager->Effects.WetWorld->Constants.Data.z);
	Constants.ExtraData.y = isExterior ? std::clamp(rainFactor * RainWetness, 0.0f, 1.0f) : 0.0f;

	// The shader's own views only; the scattering effect's views leave the skin drawn normally.
	Constants.DebugData.x = DebugView < FirstScatteringDebugView ? (float)DebugView : 0.0f;
	Constants.DebugData.y = isExterior ? 0.0f : 1.0f;
}

static void ReadMaterial(SkinShaders::MaterialStruct* Material, const char* Section, const char* ScatteringSection) {
	Material->SpecularStrength = max(0.0f, TheSettingManager->GetSettingF(Section, "SpecularStrength"));
	Material->Roughness = std::clamp(TheSettingManager->GetSettingF(Section, "Roughness"), 0.1f, 1.0f);
	Material->VanillaMatchedHighlights = std::clamp(TheSettingManager->GetSettingF(Section, "VanillaMatchedHighlights"), 0.0f, 1.0f);
	Material->ShadowScatter = max(0.0f, TheSettingManager->GetSettingF(Section, "ShadowScatter"));
	Material->Translucency = max(0.0f, TheSettingManager->GetSettingF(Section, "Translucency"));
	Material->PerPixelWidth = max(0.0f, TheSettingManager->GetSettingF(ScatteringSection, "PerPixelWidth"));
}

void SkinShaders::UpdateSettings() {
	ReadMaterial(&Exterior, "Shaders.Skin.Main", "Shaders.Skin.Scattering");
	ReadMaterial(&Interior, "Shaders.Skin.Interiors", "Shaders.Skin.Interiors");
	SkyReflectionScale = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Main", "SkyReflectionScale"));
	RainWetness = std::clamp(TheSettingManager->GetSettingF("Shaders.Skin.Main", "RainWetness"), 0.0f, 1.0f);
	DebugView = std::clamp(TheSettingManager->GetSettingI("Shaders.Skin.Debug", "DebugView"), 0, DebugViewCount);
}
