#include "DitherBuster.h"

void DitherBusterEffect::UpdateConstants() {
	Constants.Data.x = Settings.Strength;
	Constants.Data.y = Settings.MaskPower;
	Constants.Data.z = Settings.DitherThreshold;
	Constants.Data.w = Settings.Radius;
	Constants.Gate = D3DXVECTOR4(Settings.GateSoftness, Settings.DeDither ? 1.0f : 0.0f, (float)Settings.DebugView, 0.0f);
}

void DitherBusterEffect::UpdateSettings() {
	Settings.Strength  = TheSettingManager->GetSettingF("Shaders.DitherBuster.Main", "Strength");
	Settings.MaskPower = TheSettingManager->GetSettingF("Shaders.DitherBuster.Main", "MaskPower");
	Settings.DitherThreshold = TheSettingManager->GetSettingF("Shaders.DitherBuster.Main", "DitherThreshold");
	Settings.Radius = TheSettingManager->GetSettingF("Shaders.DitherBuster.Main", "Radius");
	Settings.GateSoftness = std::clamp(TheSettingManager->GetSettingF("Shaders.DitherBuster.Main", "GateSoftness"), 0.0f, 1.0f);
	Settings.DeDither = TheSettingManager->GetSettingI("Shaders.DitherBuster.Main", "DeDither") != 0;
	Settings.DebugView = TheSettingManager->GetSettingI("Shaders.DitherBuster.Main", "DebugView");
}

void DitherBusterEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_DitherBusterData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_DitherBusterGate", &Constants.Gate);
}
