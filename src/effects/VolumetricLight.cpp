// CREDIT: VolumetricLight effect / shader by mcstfuerson. Used with permission.
//         Ported to New Vegas Reloaded by Conor.
// See the credit header in src/hlsl/NewVegas/Effects/VolumetricLight.fx.hlsl.

#include <algorithm>
#include <cmath>

#include "VolumetricLight.h"

// Advance the march's dither each frame when something will average the frames back together.
//
// This effect's own Temporal pass is that something, and so is TAA: either blends roughly the last ten
// frames, so a dither that moves each frame averages out into smooth shafts, where a fixed one leaves
// the same grain in every frame and accumulation cannot touch it. So while either is on the dither
// moves by itself; DitherMotion forces it without them, where it only trades a still pattern for
// shimmer.
//
// The step is the golden ratio per frame, the additive sequence that spreads any run of frames most
// evenly over [0, 1). Counted in frames rather than seconds, so it is the same at any frame rate.
// Kept in double and wrapped here: the shader only ever sees the fractional offset.
void VolumetricLightEffect::UpdateConstants() {
	bool temporal = TemporalActive() || (TheShaderManager->Effects.TAA && TheShaderManager->Effects.TAA->Enabled);
	if (Settings.DitherMotion || temporal) {
		ditherPhase = std::fmod(ditherPhase + 0.6180339887498949, 1.0);
		Constants.Data4.w = (float)ditherPhase;
	}
	else {
		Constants.Data4.w = 0.0f;
	}
}

void VolumetricLightEffect::UpdateSettings() {
	Settings.Strength = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "Strength");
	Settings.Anisotropy = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "Anisotropy");
	Settings.Dither = TheSettingManager->GetSettingI("Shaders.VolumetricLight.Main", "Dither");
	Settings.AccumDistance = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "AccumDistance");
	Settings.NightDistance = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "NightDistance");
	Settings.ScatterReference = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "ScatterReference");
	Settings.FogInfluence = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "FogInfluence");
	Settings.Extinction = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "Extinction");
	Settings.HeightFalloff = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "HeightFalloff");
	Settings.DitherMotion = TheSettingManager->GetSettingI("Shaders.VolumetricLight.Main", "DitherMotion");

	// A missing key reads as 0. For the weight and the gamma 0 would mean no history or a box
	// collapsed onto the mean, so those fall back to their defaults; Temporal itself is a plain toggle.
	Settings.Temporal = TheSettingManager->GetSettingI("Shaders.VolumetricLight.Main", "Temporal") != 0;
	float weight = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "TemporalWeight");
	Settings.TemporalWeight = weight > 0.0f ? (std::min)((std::max)(weight, 0.5f), 0.97f) : 0.9f;
	float gamma = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Main", "TemporalClipGamma");
	Settings.TemporalClipGamma = gamma > 0.0f ? (std::min)((std::max)(gamma, 0.5f), 3.0f) : 1.25f;

	Settings.ScatterColor.x = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Coloring", "ScatterR");
	Settings.ScatterColor.y = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Coloring", "ScatterG");
	Settings.ScatterColor.z = TheSettingManager->GetSettingF("Shaders.VolumetricLight.Coloring", "ScatterB");

	Constants.Data1 = D3DXVECTOR4(Settings.ScatterColor.x, Settings.ScatterColor.y, Settings.ScatterColor.z, Settings.AccumDistance);
	// A missing key reads as 0, which falls back to AccumDistance: no separate night range. Never
	// longer than AccumDistance either -- this only ever shortens the reach at night.
	float nightDistance = Settings.NightDistance > 0.0f ? (std::min)(Settings.NightDistance, Settings.AccumDistance) : Settings.AccumDistance;
	Constants.Data2 = D3DXVECTOR4(max(nightDistance, 1.0f), 0.0f, 0.0f, 0.0f);
	// Extinction floored above zero rather than at it: the shader divides by sigmaT to integrate
	// each step analytically. It carries its own epsilon for that, but keeping a real value here
	// means the medium always has some attenuation, which is what makes transmittance meaningful.
	Constants.Data3 = D3DXVECTOR4(Settings.Strength, max(Settings.Extinction, 0.001f), Settings.FogInfluence, Settings.Anisotropy);
	// HeightFalloff passes through unclamped: 0 is a real setting, meaning a uniform medium with
	// no altitude gradient, and the shader tests for it explicitly.
	//
	// ScatterReference is floored hard because the shader divides by it. It is the path length
	// the scattering and extinction coefficients are expressed against, and it is deliberately
	// NOT AccumDistance any more -- see the note at invReference in VolumetricLight.fx.hlsl.
	// w, the dither's per-frame offset, is set every frame in UpdateConstants.
	Constants.Data4 = D3DXVECTOR4(max(Settings.ScatterReference, 1.0f), Settings.Dither ? 1.0f : 0.0f,
		max(Settings.HeightFalloff, 0.0f), Constants.Data4.w);
}

void VolumetricLightEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData1", &Constants.Data1);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData2", &Constants.Data2);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData3", &Constants.Data3);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightData4", &Constants.Data4);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightTemporal", &Constants.Temporal);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightPrevProjection", &Constants.PrevProjection);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightCameraDelta", &Constants.CameraDelta);
	TheShaderManager->RegisterConstant("TESR_VolumetricLightPrevViewTransform", (D3DXVECTOR4*)&Constants.PrevViewTransform);
}

void VolumetricLightEffect::RegisterTextures() {
	// Half resolution: the march is the expensive part (14 cascade-shadow samples per pixel) and
	// the shaft has no fine detail that needs full res. Composite reads it through a bilinear
	// sampler, which upsamples it. Mirrors FlashlightBeamEffect's TESR_VolumetricBuffer.
	TheTextureManager->InitTexture("TESR_VolumetricLightBuffer", &Textures.VolumetricTexture, &Textures.VolumetricSurface,
		TheRenderManager->width / 2, TheRenderManager->height / 2, D3DFMT_A16B16G16R16F);

	// The temporal filter's pair, same size and format so the copies between them are plain
	// StretchRects. History is last frame's filtered march; Accum is this frame's, written by the
	// Temporal pass, which cannot write the History it is reading.
	TheTextureManager->InitTexture("TESR_VolumetricLightAccum", &Textures.AccumTexture, &Textures.AccumSurface,
		TheRenderManager->width / 2, TheRenderManager->height / 2, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_VolumetricLightHistory", &Textures.HistoryTexture, &Textures.HistorySurface,
		TheRenderManager->width / 2, TheRenderManager->height / 2, D3DFMT_A16B16G16R16F);
}

bool VolumetricLightEffect::ShouldRender() {
	return TheShaderManager->GameState.isExterior && !TheShaderManager->GameState.isUnderwater;
}

bool VolumetricLightEffect::TemporalActive() {
	return Settings.Temporal && Textures.AccumSurface && Textures.HistorySurface;
}

// Record the camera this frame's march used, for next frame's reprojection. The same camera TAA
// remembers: ShaderManager sets the scene camera up right before the effect chains run.
void VolumetricLightEffect::RememberCamera() {
	Constants.PrevViewTransform = TheRenderManager->viewMatrix;
	Constants.PrevProjection = D3DXVECTOR4(TheRenderManager->projMatrix._11, TheRenderManager->projMatrix._22, 0.0f, 0.0f);
	prevCameraPosition = TheRenderManager->CameraPosition;
}

// Temporal filter over the half-res march, run right after it. Its result replaces the raw march in
// TESR_VolumetricLightBuffer, so Composite reads the filtered one without knowing, and is kept in
// History for next frame.
//
// The history is only trusted when this pass also ran on the frame immediately before. Any gap -- an
// interior, underwater, the effect or Temporal switched off, a menu that stopped the effect chain --
// means the history shows somewhere else or some other time, so it starts over. A new cell (a load or
// a teleport) starts over too.
void VolumetricLightEffect::RenderTemporal(IDirect3DDevice9* Device) {
	if (!TemporalActive() || !Enabled || Effect == nullptr || !ShouldRender()) {
		historyValid = false;
		return;
	}

	double now = TheFrameRateManager->Time;
	double previousFrame = now - TheFrameRateManager->ElapsedTime;
	bool consecutive = lastTemporalTime >= 0.0 && std::fabs(previousFrame - lastTemporalTime) < 1e-6;
	if (!consecutive || TheShaderManager->GameState.isCellChanged) historyValid = false;
	lastTemporalTime = now;

	// With no usable history, last frame's camera becomes this frame's: the reprojection is the
	// identity, and the shader ignores the history anyway because Temporal.y is 0.
	if (!historyValid) RememberCamera();

	D3DXVECTOR4 delta = TheRenderManager->CameraPosition - prevCameraPosition;
	Constants.CameraDelta = D3DXVECTOR4(delta.x, delta.y, delta.z, 0.0f);
	Constants.Temporal = D3DXVECTOR4(Settings.TemporalWeight, historyValid ? 1.0f : 0.0f, Settings.TemporalClipGamma, 0.0f);

	// Technique 2 into Accum; Render's RenderedSurface copy then puts the result into the march
	// buffer for Composite. History gets its own copy for next frame.
	Device->SetRenderTarget(0, Textures.AccumSurface);
	Render(Device, Textures.AccumSurface, Textures.VolumetricSurface, 2, false, NULL);
	Device->StretchRect(Textures.AccumSurface, NULL, Textures.HistorySurface, NULL, D3DTEXF_NONE);

	RememberCamera();
	historyValid = true;
}
