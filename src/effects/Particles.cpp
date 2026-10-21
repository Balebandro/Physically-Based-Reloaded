#include "Particles.h"

void ParticleShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_ParticleData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_ParticleAmbient", &Constants.Ambient);
	Constants.Data = D3DXVECTOR4(0.0f, 1.0f, 0.0f, 0.0f);
	Constants.Ambient = D3DXVECTOR4(1.0f, 1.0f, 1.0f, 1.0f);
}

void ParticleShaders::UpdateSettings() {
	Settings.Strength = std::clamp(TheSettingManager->GetSettingF("Shaders.Particles.Main", "Strength"), 0.0f, 1.0f);
	Settings.Brightness = max(TheSettingManager->GetSettingF("Shaders.Particles.Main", "Brightness"), 0.0f);
	Settings.SunShare = max(TheSettingManager->GetSettingF("Shaders.Particles.Main", "SunShare"), 0.0f);
}

void ParticleShaders::UpdateConstants() {
	const bool exterior = TheShaderManager->GameState.isExterior;
	D3DXVECTOR4 ambient = TheShaderManager->ShaderConst.sunAmbient;
	if (!exterior && Player && Player->parentCell && Player->parentCell->IsInterior() && Player->parentCell->lighting)
		ambient = Player->parentCell->lighting->ambient.toD3DXVECTOR4();
	Constants.Ambient = D3DXVECTOR4(ambient.x, ambient.y, ambient.z, 1.0f);
	Constants.Data = D3DXVECTOR4(Settings.Strength, Settings.Brightness, Settings.SunShare, exterior ? 1.0f : 0.0f);
}
