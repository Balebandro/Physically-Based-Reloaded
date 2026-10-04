#include "POM.h"

void POMShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_ParallaxData", &Constants.Data);
}

void POMShaders::UpdateSettings() {
		Constants.Data.x = TheSettingManager->GetSettingF("Shaders.POM.Main", "HeightMapScale");
		Constants.Data.y = TheSettingManager->GetSettingF("Shaders.PBR.Status", "Enabled");
		Constants.Data.w = TheSettingManager->GetSettingI("Main.Main.ReducedQuality", "ParallaxLite") ? 1.0f : 0.0f;   // Parallax.hlsl getParallaxCoordsObjectLite
}

void POMShaders::UpdateConstants() {}
