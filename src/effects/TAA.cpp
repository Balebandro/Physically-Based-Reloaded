// CREDIT: TAA for New Vegas Reloaded by Conor. See TAA.fx.hlsl for upstream credits.

#include <algorithm>

#include "TAA.h"

void TAAEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_TAAData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_TAAPrevProjection", &Constants.PrevProjection);
	TheShaderManager->RegisterConstant("TESR_TAACameraDelta", &Constants.CameraDelta);
	TheShaderManager->RegisterConstant("TESR_TAAWeapon", &Constants.Weapon);
	TheShaderManager->RegisterConstant("TESR_TAAPrevViewTransform", (D3DXVECTOR4*)&Constants.PrevViewTransform);
}

void TAAEffect::RegisterTextures() {
	int width = TheRenderManager->width;
	int height = TheRenderManager->height;

	TheTextureManager->InitTexture("TESR_TAAResolveBuffer", &Textures.ResolveTexture, &Textures.ResolveSurface, width, height, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("TESR_TAAHistoryBuffer", &Textures.HistoryTexture, &Textures.HistorySurface, width, height, D3DFMT_A16B16G16R16F);
}

void TAAEffect::UpdateSettings() {
	// A key absent from the toml reads as 0. Both settings would be useless at 0 -- no history at
	// all, or a box collapsed onto the neighbourhood mean -- so 0 falls back to the default rather
	// than silently turning the effect into a blur or a no-op for anyone without the defaults file.
	float weight = TheSettingManager->GetSettingF("Shaders.TAA.Main", "HistoryWeight");
	Settings.HistoryWeight = weight > 0.0f ? std::clamp(weight, 0.5f, 0.97f) : 0.9f;

	float gamma = TheSettingManager->GetSettingF("Shaders.TAA.Main", "ClipGamma");
	Settings.ClipGamma = gamma > 0.0f ? std::clamp(gamma, 0.5f, 2.5f) : 1.0f;

	// 0 is off, which is also what a missing key reads as.
	Settings.DebugView = std::clamp(TheSettingManager->GetSettingI("Shaders.TAA.Main", "DebugView"), 0, 5);

	Settings.Jitter = TheSettingManager->GetSettingI("Shaders.TAA.Main", "Jitter") != 0;

	// 0 is a real value here -- the weapon skipped entirely -- so a missing key reading as 0 is taken
	// at its word rather than replaced by the default.
	Settings.WeaponTAA = std::clamp(TheSettingManager->GetSettingF("Shaders.TAA.Main", "WeaponTAA"), 0.0f, 1.0f);
}

void TAAEffect::UpdateConstants() {
	Constants.Data.x = Settings.HistoryWeight;
	Constants.Data.y = Settings.ClipGamma;
	Constants.Data.w = (float)Settings.DebugView;
	Constants.Weapon = D3DXVECTOR4(Settings.WeaponTAA, 0.0f, 0.0f, 0.0f);
}

// Record the camera that rendered the frame now in the history buffer, for next frame's
// reprojection. Called after the resolve, never before it: at that point TheRenderManager holds
// the camera the frame was drawn with, because RenderEffects rebuilds it right before this effect.
void TAAEffect::RememberCamera() {
	Constants.PrevViewTransform = TheRenderManager->viewMatrix;
	Constants.PrevProjection = D3DXVECTOR4(TheRenderManager->projMatrix._11, TheRenderManager->projMatrix._22, 0.0f, 0.0f);
	prevCameraPosition = TheRenderManager->CameraPosition;
}

bool TAAEffect::DrawTechnique(const char* TechniqueName) {
	D3DXHANDLE technique = Effect->GetTechniqueByName(TechniqueName);
	if (!technique) {
		Logger::Log("[ERROR] TAA : technique %s not found", TechniqueName);
		return false;
	}

	Effect->SetTechnique(technique);
	UINT passes;
	Effect->Begin(&passes, 0);
	Effect->BeginPass(0);
	TheRenderManager->device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
	Effect->EndPass();
	Effect->End();
	return true;
}

// Halton low-discrepancy sequence: the radical inverse of index in the given base. Bases 2 and 3
// give well-spread 2D points, so any run of consecutive frames covers the pixel evenly rather than
// clumping, which is why it is the standard TAA jitter pattern.
static float Halton(int index, int base) {
	float result = 0.0f;
	float fraction = 1.0f / (float)base;
	while (index > 0) {
		result += (float)(index % base) * fraction;
		index /= base;
		fraction /= (float)base;
	}
	return result;
}

// The same gates RenderEffects applies before running any effect, plus TAA's own. Jitter without a
// resolve to average it is just the whole world shaking by half a pixel, so it must only be applied
// on frames where this effect is going to run.
bool TAAEffect::WillResolveThisFrame() {
	return Enabled && Effect != nullptr && ShouldRender() && Settings.Jitter &&
		Textures.ResolveSurface && Textures.HistorySurface &&
		TheSettingManager->SettingsMain.Main.RenderEffects &&
		Player && Player->parentCell &&
		!TheShaderManager->GameState.OverlayIsOn;
}

// Jitter the world render by shifting the camera frustum a fraction of a pixel.
//
// Gamebryo builds the projection from the camera's frustum, so an off-centre frustum IS a jittered
// projection -- the same _31/_32 offsets NVR's own SetupSceneCamera derives from Left+Right and
// Top+Bottom. Shifting the frustum rather than patching a matrix means every path agrees: whether
// the game rebuilds its projection from the frustum when it sets the camera, or keeps the matrix
// NVR last wrote, it gets the jittered one, because SetupSceneCamera is re-run right here.
//
// Applied around the world scene only. Shadow maps are rendered before it -- their cascades are
// fitted to the view frustum, and at the far cascade half a pixel is several world units, about a
// shadow texel, so jittering them would make shadow edges shimmer (RenderShadowMapHook logs if
// that ordering is ever violated). The first-person weapon has its own camera and stays unjittered,
// which matches TAA giving it zero motion. Everything after End -- image space, every NVR effect,
// and TAA's own reprojection -- sees the unjittered camera, exactly as without jitter.
void TAAEffect::BeginJitter() {
	EndJitter(); // never stack two shifts, whatever happened last frame

	if (!WillResolveThisFrame()) return;
	NiCamera* camera = WorldSceneGraph ? WorldSceneGraph->camera : nullptr;
	if (!camera || camera->Frustum.Ortho) return;

	// Pixel offset in (-0.5, 0.5), from Halton(2,3) indices 1..8.
	int index = (jitterIndex % JitterSequenceLength) + 1;
	float jitterX = Halton(index, 2) - 0.5f;
	float jitterY = Halton(index, 3) - 0.5f;

	// Frustum edges are in view-plane units at distance 1, so one pixel is (Right - Left) / width.
	frustumShiftX = jitterX * (camera->Frustum.Right - camera->Frustum.Left) / (float)TheRenderManager->width;
	frustumShiftY = jitterY * (camera->Frustum.Top - camera->Frustum.Bottom) / (float)TheRenderManager->height;

	camera->Frustum.Left += frustumShiftX;
	camera->Frustum.Right += frustumShiftX;
	camera->Frustum.Top += frustumShiftY;
	camera->Frustum.Bottom += frustumShiftY;

	jitterCamera = camera;
	jitterActive = true;
	TheRenderManager->SetupSceneCamera();
}

void TAAEffect::EndJitter() {
	if (!jitterActive) return;

	if (jitterCamera) {
		jitterCamera->Frustum.Left -= frustumShiftX;
		jitterCamera->Frustum.Right -= frustumShiftX;
		jitterCamera->Frustum.Top -= frustumShiftY;
		jitterCamera->Frustum.Bottom -= frustumShiftY;
	}

	jitterActive = false;
	jitterCamera = nullptr;
	frustumShiftX = 0.0f;
	frustumShiftY = 0.0f;
	TheRenderManager->SetupSceneCamera();
}

void TAAEffect::Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer) {
	if (!Enabled || Effect == nullptr || !ShouldRender() || !Textures.ResolveSurface || !Textures.HistorySurface) {
		// Whatever is in the history now will be stale, or somewhere else entirely, by the time
		// this runs again.
		historyValid = false;
		renderTime = 0.0f;
		return;
	}

	auto timer = TimeLogger();

	// A new cell means a loading screen or a teleport: last frame's history shows another place.
	if (TheShaderManager->GameState.isCellChanged) historyValid = false;

	// With no usable history, make last frame's camera this frame's. The reprojection becomes the
	// identity, and the shader ignores the history anyway because Data.z is 0.
	if (!historyValid) RememberCamera();

	D3DXVECTOR4 delta = TheRenderManager->CameraPosition - prevCameraPosition;
	Constants.CameraDelta = D3DXVECTOR4(delta.x, delta.y, delta.z, 0.0f);
	Constants.Data.z = historyValid ? 1.0f : 0.0f;

	if (SourceBuffer) Device->StretchRect(RenderTarget, NULL, SourceBuffer, NULL, D3DTEXF_NONE);
	SetCT();

	Device->SetRenderTarget(0, Textures.ResolveSurface);
	bool resolved = DrawTechnique("Resolve");

	// A debug view goes to the screen BEFORE the resolve is copied into the history. The history
	// still holds last frame at this point, so the view sees exactly what the resolve saw, and the
	// history keeps the real TAA result -- the debug picture never becomes next frame's input.
	Device->SetRenderTarget(0, RenderTarget);
	bool debugDrawn = resolved && Settings.DebugView > 0 && DrawTechnique("Debug");

	if (resolved) Device->StretchRect(Textures.ResolveSurface, NULL, Textures.HistorySurface, NULL, D3DTEXF_NONE);

	if (resolved && (debugDrawn || DrawTechnique("Output"))) {
		if (RenderedSurface) Device->StretchRect(RenderTarget, NULL, RenderedSurface, NULL, D3DTEXF_NONE);
		RememberCamera();
		historyValid = true;
		jitterIndex = (jitterIndex + 1) % JitterSequenceLength;
	}
	else {
		historyValid = false;
	}

	renderTime = timer.LogTime("EffectRecord::Render TAA");
}
