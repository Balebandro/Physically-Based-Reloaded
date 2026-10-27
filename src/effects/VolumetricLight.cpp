#include "VolumetricLight.h"

static void ReadLook(const char* section, VolumetricLightEffect::LookStruct& look) {
	look.Strength = std::clamp(TheSettingManager->GetSettingF(section, "Strength"), 0.0f, 10.0f);
	look.Darken = std::clamp(TheSettingManager->GetSettingF(section, "Darken"), 0.0f, 1.0f);
	look.Density = std::clamp(TheSettingManager->GetSettingF(section, "Density"), 0.0f, 10.0f);
	look.MaxDistance = std::clamp(TheSettingManager->GetSettingF(section, "MaxDistance"), 100.0f, 30000.0f);
	look.Anisotropy = std::clamp(TheSettingManager->GetSettingF(section, "Anisotropy"), 0.0f, 0.9f);
}

void VolumetricLightEffect::UpdateSettings() {
	const char* section = "Shaders.VolumetricLight.Main";
	ReadLook(section, Settings.Day);
	ReadLook("Shaders.VolumetricLight.Night", Settings.Night);
	Settings.Steps = std::clamp(TheSettingManager->GetSettingI(section, "Steps"), 4, 48);
	Settings.Temporal = std::clamp(TheSettingManager->GetSettingF(section, "Temporal"), 0.0f, 0.97f);
	Settings.BlurRadius = std::clamp(TheSettingManager->GetSettingF(section, "BlurRadius"), 0.0f, 8.0f);
	Settings.RainStrength = std::clamp(TheSettingManager->GetSettingF(section, "RainStrength"), 0.0f, 1.0f);
}

void VolumetricLightEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData2", &Constants.Data2);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData3", &Constants.Data3);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightLayout", &Constants.Layout);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightReproject", (D3DXVECTOR4*)&Constants.Reproject);
}

void VolumetricLightEffect::RegisterTextures() {
	const UINT w = (TheRenderManager->width + 1) / 2, h = (TheRenderManager->height + 1) / 2;
	TheTextureManager->InitTexture("TESR_VolumetricLightMarch", &Textures.MarchTexture, &Textures.MarchSurface, w, h, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_VolumetricLightBuffer", &Textures.BlurTexture, &Textures.BlurSurface, w, h, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_VolumetricLightTemp", &Textures.TempTexture, &Textures.TempSurface, w, h, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_VolumetricLightHistory", &Textures.HistoryTexture, &Textures.HistorySurface, w, h, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_VolumetricLightCoverage", &Textures.CoverageTexture, &Textures.CoverageSurface, TheRenderManager->width, TheRenderManager->height, D3DFMT_A8R8G8B8);
	Constants.Layout = D3DXVECTOR4(1.0f / w, 1.0f / h, 0.0f, 0.0f);
}

void VolumetricLightEffect::UpdateConstants() {
	const float day = std::clamp(TheShaderManager->GameState.isDayTime, 0.0f, 1.0f);
	const LookStruct& d = Settings.Day;
	const LookStruct& n = Settings.Night;

	const ShadowsExteriorEffect* shadows = TheShaderManager->Effects.ShadowsExteriors;
	float fade = 1.0f - std::clamp(shadows->Constants.ShadowFade.x, 0.0f, 1.0f);
	fade *= std::lerp(1.0f, Settings.RainStrength, std::clamp(TheShaderManager->Effects.Rain->Constants.RainAnimator.GetValue(), 0.0f, 1.0f));

	Constants.Data.x = std::lerp(n.Strength, d.Strength, day);
	Constants.Data.y = std::lerp(n.Darken, d.Darken, day);
	Constants.Data.z = std::lerp(n.Density, d.Density, day) * 0.001f;
	Constants.Data.w = std::lerp(n.MaxDistance, d.MaxDistance, day);
	Constants.Data2.x = (float)Settings.Steps;
	Constants.Data2.y = std::lerp(n.Anisotropy, d.Anisotropy, day);
	Constants.Data2.z = fade;
	Constants.Data3.y = Settings.BlurRadius;
}

bool VolumetricLightEffect::ShouldRender() {
	const ShadowsExteriorEffect* shadows = TheShaderManager->Effects.ShadowsExteriors;
	return TheShaderManager->GameState.isExterior && !TheShaderManager->GameState.isUnderwater &&
		shadows && shadows->Constants.ShadowFade.y > 0.0f &&
		Constants.Data2.z > 0.001f && (Constants.Data.x > 0.0f || Constants.Data.y > 0.0f) &&
		Textures.MarchSurface && Textures.BlurSurface && Textures.TempSurface && Textures.HistorySurface;
}

void VolumetricLightEffect::RenderBuffers(IDirect3DDevice9* Device) {
	const bool temporal = Settings.Temporal > 0.0f;
	const D3DXMATRIX& view = TheRenderManager->viewMatrix;
	const D3DXMATRIX& invView = TheRenderManager->InvViewMatrix;

	const UINT now = TheFrameRateManager->FrameNumber;
	const bool drewLastFrame = lastRenderedFrame + 1 == now;
	bool usable = temporal && haveHistory && drewLastFrame;
	if (usable) {
		const double dx = (double)invView._41 - lastInvView._41, dy = (double)invView._42 - lastInvView._42,
			dz = (double)invView._43 - lastInvView._43;
		usable = dx * dx + dy * dy + dz * dz < 500.0 * 500.0;
	}
	if (usable) {
		const double move[3] = { (double)invView._41 - lastInvView._41, (double)invView._42 - lastInvView._42,
			(double)invView._43 - lastInvView._43 };
		D3DXMATRIX toLastView;
		for (int i = 0; i < 3; i++) {
			for (int j = 0; j < 3; j++) toLastView.m[i][j] = lastView.m[i][j];
			toLastView.m[i][3] = 0.0f;
		}
		for (int j = 0; j < 3; j++)
			toLastView.m[3][j] = (float)(move[0] * lastView.m[0][j] + move[1] * lastView.m[1][j] + move[2] * lastView.m[2][j]);
		toLastView.m[3][3] = 1.0f;
		D3DXMatrixMultiply(&Constants.Reproject, &toLastView, &lastProj);
	}
	Constants.Data3.x = usable ? Settings.Temporal : 0.0f;
	Constants.Data2.w = temporal ? (float)(now % 64) : 0.0f;

	auto pass = [&](IDirect3DSurface9* target, UINT technique) {
		Device->SetRenderTarget(0, target);
		Render(Device, target, target, technique, false, target);
	};
	if (temporal) {
		pass(Textures.MarchSurface, 1);
		pass(Textures.TempSurface, 3);
		Device->StretchRect(Textures.TempSurface, NULL, Textures.HistorySurface, NULL, D3DTEXF_NONE);
	}
	else
		pass(Textures.TempSurface, 1);
	pass(Textures.MarchSurface, 2);
	pass(Textures.BlurSurface, 4);

	haveHistory = temporal;
	lastRenderedFrame = now;
	lastView = view;
	lastInvView = invView;
	lastProj = TheRenderManager->projMatrix;
}
