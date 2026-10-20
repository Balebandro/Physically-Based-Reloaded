#include <algorithm>

#include "SMAA.h"

void SMAAEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SMAAResolution", &Constants.Resolution);
	TheShaderManager->RegisterConstant("TESR_SMAAData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_SMAADepthData", &Constants.DepthData);
};

void SMAAEffect::RegisterTextures() {
	int width = TheRenderManager->width;
	int height = TheRenderManager->height;

	TheTextureManager->InitTexture("TESR_SMAA_Edges", &Textures.SMAA_Edges_Texture, &Textures.SMAA_Edges_Surface, width, height, D3DFMT_A8R8G8B8);
	TheTextureManager->InitTexture("TESR_SMAA_Blend", &Textures.SMAA_Blend_Texture, &Textures.SMAA_Blend_Surface, width, height, D3DFMT_A8R8G8B8);
};

void SMAAEffect::UpdateSettings() {
	Settings.Main.EdgeDetection = static_cast<Input>(std::clamp(TheSettingManager->GetSettingI("Shaders.SMAA.Main", "EdgeDetection"), 0, 3));
	// A key absent from the toml reads as 0, which the clamps below would floor to the bottom of
	// each range rather than to the documented default - a much more sensitive threshold and a
	// far shorter search than intended, silently, for anyone who updates the plugin without the
	// defaults file. Fall back to the SMAA_PRESET_ULTRA values instead, matching what the shader
	// does when the constants themselves are missing.
	float threshold = TheSettingManager->GetSettingF("Shaders.SMAA.Main", "Threshold");
	Settings.Main.Threshold = threshold > 0.0f ? std::clamp(threshold, 0.005f, 0.5f) : 0.05f;

	float depthThreshold = TheSettingManager->GetSettingF("Shaders.SMAA.Main", "DepthThreshold");
	Settings.Main.DepthThreshold = depthThreshold > 0.0f ? std::clamp(depthThreshold, 0.0001f, 0.5f) : 0.005f;

	int searchSteps = TheSettingManager->GetSettingI("Shaders.SMAA.Main", "MaxSearchSteps");
	Settings.Main.MaxSearchSteps = searchSteps > 0 ? (float)std::clamp(searchSteps, 4, 112) : 32.0f;
	Settings.Main.SubpixelShift = std::clamp(TheSettingManager->GetSettingF("Shaders.SMAA.Main", "SubpixelShift"), -2.0f, 2.0f);
	Settings.Main.DepthOffset = std::clamp(TheSettingManager->GetSettingF("Shaders.SMAA.Main", "DepthOffset"), -2.0f, 2.0f);
	float localContrast = TheSettingManager->GetSettingF("Shaders.SMAA.Main", "LocalContrast");
	Settings.Main.LocalContrast = localContrast > 0.0f ? std::clamp(localContrast, 1.0f, 20.0f) : 2.0f;
};

void SMAAEffect::UpdateConstants() {
	Constants.Resolution.x = 1.0f / (float) TheRenderManager->width;
	Constants.Resolution.y = 1.0f / (float) TheRenderManager->height;
	// SMAA_RT_METRICS is float4(1/width, 1/height, width, height) - see the definition in the
	// include. z and w were filled the other way round, and because SMAABlendingWeightCalculation
	// derives pixcoord from the same swapped pair, the error is self consistent per axis rather
	// than obviously broken: horizontal edge distances came out scaled by height/width and
	// vertical ones by width/height. At 16:9 that is 44% short horizontally, so every edge looked
	// shorter than it was and got less blending, and 78% long vertically, which clamps against
	// SMAA_AREATEX_MAX_DISTANCE. It reads as SMAA being too weak, in every edge detection mode,
	// because it is downstream of all three.
	Constants.Resolution.z = (float)TheRenderManager->width;
	Constants.Resolution.w = (float)TheRenderManager->height;

	Constants.Data.x = Settings.Main.Threshold;
	Constants.Data.y = Settings.Main.DepthThreshold;
	Constants.Data.z = Settings.Main.MaxSearchSteps;
	Constants.Data.w = Settings.Main.SubpixelShift;
	Constants.DepthData.x = Settings.Main.DepthOffset;
	Constants.DepthData.y = Settings.Main.LocalContrast;
	Constants.DepthData.z = 0.0f;
	Constants.DepthData.w = 0.0f;
};

/*
 * Render SMAA by performing the three main passes (edge detection, blending weight calculation, and final blending). 
 */
void SMAAEffect::Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer) {
	if (!Enabled) {
		renderTime = 0.0f;
		return; // skip rendering if the effect is disabled
	}

	auto timer = TimeLogger();

	// It draws on the game's target itself: with the frame chain on, the frame is put there first.
	if (TheShaderManager->Chain.IsActive()) {
		TheShaderManager->Chain.Sync();
		RenderedSurface = TheTextureManager->RenderedSurface;
	}

	// Clear the stencil buffer.
	Device->Clear(0, nullptr, D3DCLEAR_STENCIL, D3DCOLOR_ARGB(0, 0, 0, 0), 1.0f, 0);

	SetCT();

	EdgesDetectionPass(Settings.Main.EdgeDetection);
	BlendingWeightsCalculationPass();
	NeighborhoodBlendingPass(RenderTarget);

	if (RenderedSurface) Device->StretchRect(RenderTarget, NULL, RenderedSurface, NULL, D3DTEXF_LINEAR);

	renderTime = timer.LogTime("EffectRecord::Render SMAA");
}

void SMAAEffect::EdgesDetectionPass(Input input) {
    IDirect3DDevice9* Device = TheRenderManager->device;

    // Set the render target and clear both the color and the stencil buffers.
    Device->SetRenderTarget(0, Textures.SMAA_Edges_Surface);
    Device->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_ARGB(0, 0, 0, 0), 1.0f, 0);

    // Select the technique accordingly.
    switch (input) {
    case INPUT_LUMA:
        Effect->SetTechnique(Effect->GetTechniqueByName("LumaEdgeDetection"));
        break;
    case INPUT_COLOR:
        Effect->SetTechnique(Effect->GetTechniqueByName("ColorEdgeDetection"));
        break;
    case INPUT_DEPTH:
        Effect->SetTechnique(Effect->GetTechniqueByName("DepthEdgeDetection"));
        break;
    case INPUT_LUMADEPTH:
        Effect->SetTechnique(Effect->GetTechniqueByName("LumaDepthEdgeDetection"));
        break;
    default:
		return;
    }

    UINT passes;
    Effect->Begin(&passes, 0);
    Effect->BeginPass(0);
	Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
    Effect->EndPass();
    Effect->End();
}


void SMAAEffect::BlendingWeightsCalculationPass() {
	IDirect3DDevice9* Device = TheRenderManager->device;

    // Set the render target and clear it.
    Device->SetRenderTarget(0, Textures.SMAA_Blend_Surface);
    Device->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_ARGB(0, 0, 0, 0), 1.0f, 0);

    Effect->SetTechnique(Effect->GetTechniqueByName("BlendWeightCalculation"));

	UINT passes;
	Effect->Begin(&passes, 0);
	Effect->BeginPass(0);
	Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
	Effect->EndPass();
	Effect->End();
}


void SMAAEffect::NeighborhoodBlendingPass(IDirect3DSurface9* RenderTarget) {
	IDirect3DDevice9* Device = TheRenderManager->device;

    Device->SetRenderTarget(0, RenderTarget);
    Effect->SetTechnique(Effect->GetTechniqueByName("NeighborhoodBlending"));

	UINT passes;
	Effect->Begin(&passes, 0);
	Effect->BeginPass(0);
	Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
	Effect->EndPass();
	Effect->End();
}
