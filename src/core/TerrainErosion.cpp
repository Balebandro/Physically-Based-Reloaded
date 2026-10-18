#include "TerrainErosion.h"

namespace TerrainErosion {

	static const char* kSection = "Shaders.Terrain.Erosion";
	static D3DXVECTOR4 sData = {};	// x gully depth (0 off), y widest gully spacing (units), z gully floor darkening

	void Initialize() {
		TheShaderManager->RegisterConstant("TESR_TerrainErosionData", &sData);
	}

	void Update() {
		sData.x = 0.0f;
		if (!TheSettingManager || TheSettingManager->GetSettingI(kSection, "Enabled") == 0) return;
		sData.x = std::clamp(TheSettingManager->GetSettingF(kSection, "Depth"), 0.0f, 4.0f);
		sData.y = std::clamp(TheSettingManager->GetSettingF(kSection, "Spacing"), 128.0f, 16384.0f);
		sData.z = std::clamp(TheSettingManager->GetSettingF(kSection, "GullyDarkening"), 0.0f, 1.0f);
	}
}
