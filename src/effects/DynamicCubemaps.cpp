#include <algorithm>

#include "DynamicCubemaps.h"

// Farther than this between two frames, the camera went through a door or a load: what the cube
// holds is somewhere else.
static const float DynamicCubemapJumpDistance = 1500.0f;

void DynamicCubemapsEffect::UpdateSettings() {
	Reset = true;
	Constants.Debug.x = (float)std::clamp(TheSettingManager->GetSettingI("Shaders.DynamicCubemaps.Main", "DebugView"), 0, 3);
	Constants.Debug.y = std::clamp(TheSettingManager->GetSettingF("Shaders.DynamicCubemaps.Main", "DebugRoughness"), 0.0f, 1.0f) * (Mips - 1);
}

// Only authored PBR materials reflect the cube.
bool DynamicCubemapsEffect::ShouldRender() {
	return TheShaderManager->Shaders.PBR->Enabled;
}

void DynamicCubemapsEffect::UpdateConstants() {
	const bool isExterior = TheShaderManager->GameState.isExterior;
	D3DXVECTOR3 camera(TheRenderManager->CameraPosition.x, TheRenderManager->CameraPosition.y, TheRenderManager->CameraPosition.z);
	D3DXVECTOR3 moved = camera - LastCameraPosition;
	if (isExterior != WasExterior || D3DXVec3Length(&moved) > DynamicCubemapJumpDistance) Reset = true;
	WasExterior = isExterior;
	LastCameraPosition = camera;

	// Indoors, before anything has been seen, the cube holds the room's ambient light: what the
	// objects reflected before the cube existed (Object.hlsl). The object shaders decode it and
	// scale it by AmbientScale; the cube is linear and is taken back to gamma space by them
	// without LinearLighting.
	TheShaderManager->Effects.ShadowsExteriors->UpdateLightColors();
	const D3DXVECTOR4& ambient = TheShaderManager->Effects.ShadowsExteriors->Constants.AmbientLight;
	PBRShaders* PBR = TheShaderManager->Shaders.PBR;
	const float scale = PBR->Constants.Data.w;
	const bool linear = PBR->MaterialSettings.LinearLighting;
	for (int i = 0; i < 3; i++) {
		float c = ((const float*)&ambient)[i];
		((float*)&Constants.Fallback)[i] = linear ? c * c * scale : (c * scale) * (c * scale);
	}
	Constants.Fallback.w = isExterior ? 1.0f : 0.0f;

	Constants.Face.y = 1.0f / Size;
	Constants.Face.w = 0.995f;   // out of view, a texel's coverage halves in about 140 frames and the fallback returns
}

// --- Textures -------------------------------------------------------------------------------------

void DynamicCubemapsEffect::ReleaseTextures() {
	for (int c = 0; c < 2; c++) for (int f = 0; f < 6; f++) for (UINT m = 0; m < Mips; m++)
		if (CaptureSurfaces[c][f][m]) { CaptureSurfaces[c][f][m]->Release(); CaptureSurfaces[c][f][m] = nullptr; }
	for (int f = 0; f < 6; f++) for (UINT m = 0; m < Mips; m++) {
		if (InferredSurfaces[f][m]) { InferredSurfaces[f][m]->Release(); InferredSurfaces[f][m] = nullptr; }
		if (EnvSurfaces[f][m]) { EnvSurfaces[f][m]->Release(); EnvSurfaces[f][m] = nullptr; }
	}
	for (int c = 0; c < 2; c++) if (CaptureCube[c]) { CaptureCube[c]->Release(); CaptureCube[c] = nullptr; }
	if (Inferred) { Inferred->Release(); Inferred = nullptr; }
	if (Env) { Env->Release(); Env = nullptr; }
	Created = false;
	Valid = false;
}

static bool CreateCube(IDirect3DDevice9* Device, UINT Size, UINT Mips, IDirect3DCubeTexture9** Cube, IDirect3DSurface9* Surfaces[6][DynamicCubemapsEffect::Mips]) {
	if (FAILED(Device->CreateCubeTexture(Size, Mips, D3DUSAGE_RENDERTARGET, D3DFMT_A16B16G16R16F, D3DPOOL_DEFAULT, Cube, NULL))) {
		*Cube = nullptr;
		return false;
	}
	for (UINT f = 0; f < 6; f++) for (UINT m = 0; m < Mips; m++)
		if (FAILED((*Cube)->GetCubeMapSurface((D3DCUBEMAP_FACES)f, m, &Surfaces[f][m]))) return false;
	return true;
}

bool DynamicCubemapsEffect::EnsureTextures(IDirect3DDevice9* Device) {
	if (Created) return true;
	if (Failed) return false;

	bool ok = CreateCube(Device, Size, Mips, &CaptureCube[0], CaptureSurfaces[0])
		&& CreateCube(Device, Size, Mips, &CaptureCube[1], CaptureSurfaces[1])
		&& CreateCube(Device, Size, Mips, &Inferred, InferredSurfaces)
		&& CreateCube(Device, Size, Mips, &Env, EnvSurfaces);
	if (!ok) {
		Logger::Log("[ERROR] DynamicCubemaps: could not create the cubemaps; PBR materials reflect the sky and ambient light instead");
		ReleaseTextures();
		Failed = true;
		return false;
	}

	FaceHandle = Effect->GetParameterByName(NULL, "CubeFace");
	FallbackHandle = Effect->GetParameterByName(NULL, "CubeFallback");
	CaptureHandle = Effect->GetParameterByName(NULL, "CubeCapture");
	DebugHandle = Effect->GetParameterByName(NULL, "CubeDebug");
	Created = true;
	Reset = true;
	Logger::Log("DynamicCubemaps: %u px cubemaps, %u mips", Size, Mips);
	return true;
}

// --- Rendering ------------------------------------------------------------------------------------

void DynamicCubemapsEffect::DrawFace(IDirect3DDevice9* Device, IDirect3DSurface9* Target, UINT Face, UINT Mip, float Roughness) {
	Device->SetRenderTarget(0, Target);   // also sets the viewport to the face
	Constants.Face.x = (float)Face;
	Constants.Face.y = (float)(1 << Mip) / Size;
	Constants.Face.z = Roughness;
	Effect->SetVector(FaceHandle, &Constants.Face);
	Effect->CommitChanges();
	Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
}

// A box filter: each mip is half the one above it, averaged by linear filtering. The capture is
// premultiplied by its coverage, so this averages only what was seen.
void DynamicCubemapsEffect::DownsampleMips(IDirect3DDevice9* Device, IDirect3DSurface9* Surfaces[6][Mips]) {
	for (UINT f = 0; f < 6; f++)
		for (UINT m = 1; m < Mips; m++)
			Device->StretchRect(Surfaces[f][m - 1], NULL, Surfaces[f][m], NULL, D3DTEXF_LINEAR);
}

// Called on the scene exactly as drawn, with RenderedSurface holding a copy of it. Leaves the
// render target as it found it.
void DynamicCubemapsEffect::RenderCubemaps(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget) {
	if (!Enabled || Effect == nullptr || !ShouldRender()) {
		renderTime = 0.0f;
		Valid = false;
		Reset = true;
		return;
	}
	if (!EnsureTextures(Device)) return;

	auto timer = TimeLogger();
	const int next = Current ^ 1;

	// The cube may still be bound to the stage the objects sample it from.
	Device->SetTexture(11, NULL);

	// No depth: the scene's may be multisampled, which a plain render target cannot be paired with.
	IDirect3DSurface9* DepthStencil = nullptr;
	Device->GetDepthStencilSurface(&DepthStencil);
	Device->SetDepthStencilSurface(NULL);

	Constants.Capture.y = Reset ? 1.0f : 0.0f;

	Effect->SetTechnique(Effect->GetTechnique(0));
	SetCT();   // the scene, depth and view model mask on s0-s2; the TESR_ constants
	Effect->SetVector(FallbackHandle, &Constants.Fallback);
	Effect->SetVector(CaptureHandle, &Constants.Capture);

	UINT passes = 0;
	Effect->Begin(&passes, 0);   // restores the device's states at End
	Device->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
	Device->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);
	Device->SetRenderState(D3DRS_STENCILENABLE, FALSE);
	Device->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
	Device->SetRenderState(D3DRS_ALPHATESTENABLE, FALSE);
	Device->SetRenderState(D3DRS_SCISSORTESTENABLE, FALSE);
	Device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
	Device->SetRenderState(D3DRS_COLORWRITEENABLE, 0xF);

	// 1 Capture into the other cube, reading last frame's.
	Effect->BeginPass(0);
	Device->SetTexture(4, CaptureCube[Current]);
	for (UINT f = 0; f < 6; f++) DrawFace(Device, CaptureSurfaces[next][f][0], f, 0, 0.0f);
	Effect->EndPass();
	DownsampleMips(Device, CaptureSurfaces[next]);

	// 2 Infer what was never seen.
	Effect->BeginPass(1);
	Device->SetTexture(4, NULL);
	Device->SetTexture(5, CaptureCube[next]);
	for (UINT f = 0; f < 6; f++) DrawFace(Device, InferredSurfaces[f][0], f, 0, 0.0f);
	Effect->EndPass();
	DownsampleMips(Device, InferredSurfaces);

	// 3 Prefilter: mip 0 is the mirror, a copy; each mip below it one roughness step more.
	for (UINT f = 0; f < 6; f++) Device->StretchRect(InferredSurfaces[f][0], NULL, EnvSurfaces[f][0], NULL, D3DTEXF_NONE);
	Effect->BeginPass(2);
	Device->SetTexture(5, NULL);
	Device->SetTexture(6, Inferred);
	for (UINT m = 1; m < Mips; m++)
		for (UINT f = 0; f < 6; f++) DrawFace(Device, EnvSurfaces[f][m], f, m, (float)m / (Mips - 1));
	Effect->EndPass();
	Device->SetTexture(6, NULL);

	Effect->End();
	Device->SetRenderTarget(0, RenderTarget);
	Device->SetDepthStencilSurface(DepthStencil);
	if (DepthStencil) DepthStencil->Release();

	// The stages this pass bound on the device (SetCT's samplers on 0-2, the cubes on 4-6, 11 cleared)
	// get back what the game's render state has cached for them. The game skips binding a texture its
	// cache says is already there, so a stage left empty here stayed empty for the next draw that
	// wanted the same texture: decals lost their environment map and highlights, depending on which
	// draws happened to rebind those stages first -- and so on the view.
	static const UINT TouchedStages[] = { 0, 1, 2, 4, 5, 6, 11 };
	for (UINT Stage : TouchedStages)
		Device->SetTexture(Stage, TheRenderManager->renderState->GetTexture(Stage));

	Current = next;
	Reset = false;
	Valid = true;
	renderTime = timer.LogTime("DynamicCubemapsEffect::RenderCubemaps");
}

// The debug view (technique Debug in DynamicCubemaps.fx.hlsl), drawn over the finished frame. Uses
// the cubes RenderCubemaps built this frame: Env for the panorama and mirror views, the latest
// capture (CaptureCube[Current]) for coverage.
void DynamicCubemapsEffect::RenderDebug(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget) {
	if (Constants.Debug.x < 0.5f || !Enabled || Effect == nullptr || !Valid || !ShouldRender()) return;
	D3DXHANDLE Technique = Effect->GetTechniqueByName("Debug");
	if (!Technique) return;

	Effect->SetTechnique(Technique);
	SetCT();   // depth and normals buffers, TESR_ camera constants
	Effect->SetVector(DebugHandle, &Constants.Debug);

	Device->SetRenderTarget(0, RenderTarget);
	UINT passes = 0;
	Effect->Begin(&passes, 0);   // restores the device's states at End
	Device->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
	Device->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);
	Device->SetRenderState(D3DRS_STENCILENABLE, FALSE);
	Device->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
	Device->SetRenderState(D3DRS_ALPHATESTENABLE, FALSE);
	Device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
	Device->SetRenderState(D3DRS_COLORWRITEENABLE, 0xF);
	Effect->BeginPass(0);
	Device->SetTexture(5, CaptureCube[Current]);
	Device->SetTexture(7, Env);
	Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
	Effect->EndPass();
	Effect->End();

	// As in RenderCubemaps: the stages bound on the device get back what the game's render state caches.
	static const UINT TouchedStages[] = { 0, 1, 2, 3, 5, 7 };
	for (UINT Stage : TouchedStages)
		Device->SetTexture(Stage, TheRenderManager->renderState->GetTexture(Stage));
}
