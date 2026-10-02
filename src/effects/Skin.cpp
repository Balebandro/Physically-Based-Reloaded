#include <algorithm>

#include "Skin.h"

void SkinShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SkinData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_SkinExtraData", &Constants.ExtraData);
}

void SkinShaders::UpdateConstants() {
	// Nothing occludes the sky the reflection samples, so indoors it would light skin from a sky
	// it cannot see (the object shaders do the same).
	Constants.ExtraData.x = TheShaderManager->GameState.isExterior ? SkyReflectionScale : 0.0f;

	// Rain wets skin: smoother and shinier. Same rain/puddle factor the PBR and terrain shaders use.
	float rainFactor = max(TheShaderManager->Effects.WetWorld->Constants.Data.x, TheShaderManager->Effects.WetWorld->Constants.Data.z);
	Constants.ExtraData.y = TheShaderManager->GameState.isExterior ? std::clamp(rainFactor * RainWetness, 0.0f, 1.0f) : 0.0f;
}

void SkinShaders::UpdateSettings() {
	Constants.Data.x = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Main", "SpecularStrength"));
	Constants.Data.y = std::clamp(TheSettingManager->GetSettingF("Shaders.Skin.Main", "Roughness"), 0.1f, 1.0f);
	// Per-pixel diffusion from curvature, used where the screen-space blur does not reach.
	Constants.Data.z = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Scattering", "PerPixelWidth"));
	Constants.Data.w = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Main", "Translucency"));
	Constants.ExtraData.z = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Main", "ShadowScatter"));
	Constants.ExtraData.w = std::clamp(TheSettingManager->GetSettingF("Shaders.Skin.Main", "VanillaMatchedHighlights"), 0.0f, 1.0f);
	SkyReflectionScale = max(0.0f, TheSettingManager->GetSettingF("Shaders.Skin.Main", "SkyReflectionScale"));
	RainWetness = std::clamp(TheSettingManager->GetSettingF("Shaders.Skin.Main", "RainWetness"), 0.0f, 1.0f);
}
