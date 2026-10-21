#include "BounceLight.h"
#include "BounceLightMath.h"

// Ported from NVR UNOFFICIAL Optimized (P81, effects/BounceLight.cpp), without its neon spill, GPU timers, ReShade depth
// handling and reduced-quality buffer sizes.

void BounceLightEffect::UpdateConstants() {
}

void BounceLightEffect::UpdateSettings() {
	const char* Section = "Shaders.BounceLight.Main";
	Constants.Data.x = TheSettingManager->GetSettingF(Section, "Strength");
	strength = Constants.Data.x;
	Constants.Data.y = TheSettingManager->GetSettingF(Section, "Radius");
	Constants.Data.z = TheSettingManager->GetSettingF(Section, "DrawDistance");
	Constants.Data.w = TheSettingManager->GetSettingF(Section, "BlurRadius");
	quarterResolution = TheSettingManager->GetSettingI(Section, "QuarterResolution") != 0;
	offScreenLight = std::clamp(TheSettingManager->GetSettingF(Section, "OffScreenLight"), 0.0f, 4.0f);
	multiBounce = std::clamp(TheSettingManager->GetSettingF(Section, "MultiBounce"), 0.0f, 2.0f);
	temporal = TheSettingManager->GetSettingI(Section, "Temporal") != 0;
	halfSamples = TheSettingManager->GetSettingI(Section, "HalfSamples") != 0;
	hardEdges = TheSettingManager->GetSettingI(Section, "HardEdges") != 0;
}

void BounceLightEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_BounceLightData", &Constants.Data);
}

D3DXHANDLE BounceLightEffect::TechniqueHandle(CachedHandle& cache, const char* name) {
	if (cache.Owner != Effect) {
		cache.Owner = Effect;
		cache.Handle = Effect ? Effect->GetTechniqueByName(name) : NULL;
	}
	return cache.Handle;
}

D3DXHANDLE BounceLightEffect::ParameterHandle(CachedHandle& cache, const char* name) {
	if (cache.Owner != Effect) {
		cache.Owner = Effect;
		cache.Handle = Effect ? Effect->GetParameterByName(NULL, name) : NULL;
	}
	return cache.Handle;
}

void BounceLightEffect::EnsureBuffers(bool quarter) {
	if (quarter && !quarterTried) {
		quarterTried = true;
		const int width = TheRenderManager->width / 4, height = TheRenderManager->height / 4;
		TheTextureManager->InitTexture("NVR_BounceBufferQuarter0", &quarterTexture[0], &quarterSurface[0], width, height, D3DFMT_A16B16G16R16F);
		TheTextureManager->InitTexture("NVR_BounceBufferQuarter1", &quarterTexture[1], &quarterSurface[1], width, height, D3DFMT_A16B16G16R16F);
		TheTextureManager->InitTexture("NVR_BouncePrepQuarter", &quarterPrepTexture, &quarterPrepSurface, width, height, D3DFMT_A32B32G32R32F);
	}
	if (!quarter && !halfTried) {
		halfTried = true;
		const int width = TheRenderManager->width / 2, height = TheRenderManager->height / 2;
		TheTextureManager->InitTexture("NVR_BounceBuffer0", &halfTexture[0], &halfSurface[0], width, height, D3DFMT_A16B16G16R16F);
		TheTextureManager->InitTexture("NVR_BounceBuffer1", &halfTexture[1], &halfSurface[1], width, height, D3DFMT_A16B16G16R16F);
		TheTextureManager->InitTexture("NVR_BouncePrep", &halfPrepTexture, &halfPrepSurface, width, height, D3DFMT_A32B32G32R32F);
	}
}

void BounceLightEffect::EnsureHistory(bool quarter) {
	bool& tried = quarter ? quarterHistoryTried : halfHistoryTried;
	if (tried) return;
	tried = true;
	const int width = TheRenderManager->width / (quarter ? 4 : 2), height = TheRenderManager->height / (quarter ? 4 : 2);
	IDirect3DTexture9** textures = quarter ? quarterHistory : halfHistory;
	IDirect3DSurface9** surfaces = quarter ? quarterHistorySurface : halfHistorySurface;
	TheTextureManager->InitTexture(quarter ? "NVR_BounceHistoryQuarter0" : "NVR_BounceHistory0", &textures[0], &surfaces[0], width, height, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture(quarter ? "NVR_BounceHistoryQuarter1" : "NVR_BounceHistory1", &textures[1], &surfaces[1], width, height, D3DFMT_A16B16G16R16F);
	for (int i = 0; i < 2; i++) if (surfaces[i]) TheRenderManager->device->ColorFill(surfaces[i], NULL, D3DCOLOR_ARGB(0, 0, 0, 0));
}

static float BounceLinear(float c) {
	c = std::clamp(c, 0.0f, 1.0f);
	return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

void BounceLightEffect::Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
	IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget,
	IDirect3DSurface9* SourceBuffer) {
	if (!Enabled || !Effect || !ShouldRender()) { renderTime = 0; lastValid = historyValid = false; return; }
	EnsureBuffers(quarterResolution);
	if (quarterResolution && !quarterTexture[0]) EnsureBuffers(false);
	D3DXHANDLE layoutHandle = ParameterHandle(paramLayout, "NVR_BounceLayout");
	D3DXTECHNIQUE_DESC description = {};
	IDirect3DTexture9* scene = TheTextureManager->RenderedTexture;
	const bool quarter = quarterResolution && quarterTexture[0] && quarterTexture[1] && quarterSurface[0] && quarterSurface[1] &&
		quarterPrepTexture && quarterPrepSurface;
	IDirect3DTexture9* const* lowTexture = quarter ? quarterTexture : halfTexture;
	IDirect3DSurface9* const* lowSurface = quarter ? quarterSurface : halfSurface;
	IDirect3DTexture9* prepTexture = quarter ? quarterPrepTexture : halfPrepTexture;
	IDirect3DSurface9* prepSurface = quarter ? quarterPrepSurface : halfPrepSurface;

	// The technique: the plain one, or with the extras (off-screen light, multi-bounce, the last frame reused).
	D3DXHANDLE technique = Effect->GetTechnique(0);
	IDirect3DTexture9* const* historyTexture = nullptr;
	IDirect3DSurface9* const* historySurface = nullptr;
	D3DXHANDLE temporalHandle = NULL, ambientHandle = NULL, reprojectHandle = NULL;
	if (offScreenLight > 0.0f || multiBounce > 0.0f || temporal) {
		temporalHandle = ParameterHandle(paramTemporal, "NVR_BounceTemporal");
		ambientHandle = ParameterHandle(paramAmbient, "NVR_BounceAmbient");
		reprojectHandle = ParameterHandle(paramReproject, "NVR_BounceReproject");
		D3DXHANDLE wanted = NULL;
		if (temporal) {
			EnsureHistory(quarter);
			IDirect3DTexture9* const* textures = quarter ? quarterHistory : halfHistory;
			IDirect3DSurface9* const* surfaces = quarter ? quarterHistorySurface : halfHistorySurface;
			wanted = halfSamples ? TechniqueHandle(techTemporalHalf, "BounceLightTemporalHalf") : TechniqueHandle(techTemporal, "BounceLightTemporal");
			if (wanted && textures[0] && textures[1] && surfaces[0] && surfaces[1]) { historyTexture = textures; historySurface = surfaces; }
			else wanted = NULL;
		}
		if (!wanted) wanted = TechniqueHandle(techPlus, "BounceLightPlus");
		if (wanted && temporalHandle && ambientHandle && reprojectHandle) technique = wanted;
		else historyTexture = nullptr;
	}
	const bool plus = technique != Effect->GetTechnique(0);
	if (hardEdges) {
		D3DXHANDLE hard = NULL;
		if (technique == TechniqueHandle(techPlus, "BounceLightPlus")) hard = TechniqueHandle(techPlusHard, "BounceLightPlusHardEdges");
		else if (technique == TechniqueHandle(techTemporal, "BounceLightTemporal")) hard = TechniqueHandle(techTemporalHard, "BounceLightTemporalHardEdges");
		else if (technique == TechniqueHandle(techTemporalHalf, "BounceLightTemporalHalf")) hard = TechniqueHandle(techTemporalHalfHard, "BounceLightTemporalHalfHardEdges");
		if (hard) technique = hard;
	}

	D3DVIEWPORT9 original = {};
	D3DSURFACE_DESC half = {};
	if (!layoutHandle || !scene || !lowTexture[0] || !lowTexture[1] || !lowSurface[0] || !lowSurface[1] ||
		!prepTexture || !prepSurface || FAILED(Effect->GetTechniqueDesc(technique, &description)) ||
		description.Passes != 5 || FAILED(Device->GetViewport(&original)) || FAILED(lowSurface[0]->GetDesc(&half))) {
		static bool reported = false;
		if (!reported) Logger::Log("BounceLight: buffers missing or BounceLight.fx.hlsl is not the matching version (5 passes), effect skipped.");
		reported = true;
		renderTime = 0;
		lastValid = historyValid = false;
		return;
	}
	auto timer = TimeLogger();
	FrameChain& chain = TheShaderManager->Chain;
	const bool chained = chain.Owns(RenderTarget, RenderedSurface);
	IDirect3DSurface9* finalTarget = chained ? chain.Output() : RenderTarget;
	D3DVIEWPORT9 reduced = original;
	reduced.Width = half.Width;
	reduced.Height = half.Height;
	D3DXVECTOR4 layout((float)half.Width / original.Width, (float)half.Height / original.Height, 1.0f / half.Width, 1.0f / half.Height);
	IDirect3DSurface9* depthSurface = nullptr;
	Device->GetDepthStencilSurface(&depthSurface);
	Device->SetDepthStencilSurface(nullptr);

	const double now = TheFrameRateManager->Time;
	const bool continuous = lastValid && lastQuarter == quarter && now - lastTime >= 0.0 && now - lastTime < 0.5 &&
		!TheShaderManager->GameState.isCellChanged;

	Constants.Data.x = strength;
	Effect->SetTechnique(technique);
	SetCT();
	Effect->SetVector(layoutHandle, &layout);
	const bool useHistory = historyTexture != nullptr;
	const int writeIndex = historyIndex ^ 1;
	if (plus) {
		static const float HistoryShare = 0.9f;
		D3DXVECTOR4 temporalData(useHistory && continuous && historyValid ? HistoryShare : 0.0f, continuous ? multiBounce : 0.0f,
			(float)(frameNumber % 1024), 0.0f);
		// The light off-screen samples are guessed from: the sky's (or the cell's) ambient.
		D3DXVECTOR4 ambient = TheShaderManager->ShaderConst.sunAmbient;
		if (!TheShaderManager->GameState.isExterior && Player && Player->parentCell && Player->parentCell->IsInterior() &&
			Player->parentCell->lighting)
			ambient = Player->parentCell->lighting->ambient.toD3DXVECTOR4();
		D3DXVECTOR4 ambientData(0.25f * BounceLinear(ambient.x), 0.25f * BounceLinear(ambient.y), 0.25f * BounceLinear(ambient.z), offScreenLight);
		D3DXMATRIX reproject;
		D3DXMatrixIdentity(&reproject);
		if (continuous) BounceLightReprojection(TheRenderManager->viewMatrix, TheRenderManager->InvViewMatrix, lastView, lastInvView, lastProj, &reproject);
		Effect->SetVector(temporalHandle, &temporalData);
		Effect->SetVector(ambientHandle, &ambientData);
		Effect->SetMatrix(reprojectHandle, &reproject);
	}
	// No neon spill: its parameters at their "off" values.
	if (D3DXHANDLE spillHandle = ParameterHandle(paramSpill, "NVR_BounceSpill")) {
		D3DXVECTOR4 spillOff(0.0f, 1.0f, 1.0f, 1.5f);
		Effect->SetVector(spillHandle, &spillOff);
	}
	if (D3DXHANDLE debugHandle = ParameterHandle(paramSpillDebug, "NVR_SpillDebug")) {
		D3DXVECTOR4 debugOff(0.0f, 0.0f, 0.0f, 0.0f);
		Effect->SetVector(debugHandle, &debugOff);
	}

	// Prepare (0), gather (1), blur X (2), blur Y (3) at the reduced size; combine (4) into the frame.
	UINT passes = 0;
	HRESULT result = Effect->Begin(&passes, 0);
	if (SUCCEEDED(result)) {
		for (UINT p = 0; p < 5 && SUCCEEDED(result); ++p) {
			const bool combine = p == 4;
			IDirect3DSurface9* destination = combine ? finalTarget : p == 0 ? prepSurface :
				p == 1 && useHistory ? historySurface[writeIndex] : lowSurface[p == 2 ? 1 : 0];
			Device->SetTexture(5, nullptr);
			Device->SetTexture(6, nullptr);
			if (plus) Device->SetTexture(7, nullptr);
			result = Device->SetRenderTarget(0, destination);
			if (SUCCEEDED(result)) result = Device->SetViewport(combine ? &original : &reduced);
			if (SUCCEEDED(result)) result = Effect->BeginPass(p);
			if (FAILED(result)) break;
			if (p == 0 && plus) Device->SetTexture(7, lowTexture[0]);
			if (p == 1) {
				Device->SetTexture(6, prepTexture);
				if (useHistory) Device->SetTexture(7, historyTexture[historyIndex]);
			}
			else if (p == 2 && useHistory) Device->SetTexture(5, historyTexture[writeIndex]);
			else if (p == 2 || p == 4) Device->SetTexture(5, lowTexture[0]);
			else if (p == 3) Device->SetTexture(5, lowTexture[1]);
			Device->SetTexture(8, nullptr);
			Device->SetTexture(2, scene);
			result = Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
			HRESULT endResult = Effect->EndPass();
			if (SUCCEEDED(result)) result = endResult;
		}
		Effect->End();
	}
	Device->SetTexture(5, nullptr);
	Device->SetTexture(6, nullptr);
	if (plus) Device->SetTexture(7, nullptr);
	Device->SetTexture(2, TheTextureManager->SourceTexture);
	if (SUCCEEDED(result)) {
		lastView = TheRenderManager->viewMatrix;
		lastInvView = TheRenderManager->InvViewMatrix;
		lastProj = TheRenderManager->projMatrix;
		lastValid = true;
		lastQuarter = quarter;
		lastTime = now;
		frameNumber++;
		historyValid = useHistory;
		if (useHistory) historyIndex = writeIndex;
	}
	else lastValid = historyValid = false;
	Device->SetRenderTarget(0, RenderTarget);
	Device->SetViewport(&original);
	Device->SetDepthStencilSurface(depthSurface);
	if (depthSurface) depthSurface->Release();
	if (SUCCEEDED(result)) {
		if (chained) chain.Commit();
		else Device->StretchRect(RenderTarget, NULL, RenderedSurface, NULL, D3DTEXF_NONE);
	}
	else {
		static bool reported = false;
		if (!reported) Logger::Log("BounceLight: render failed (%08lx).", result);
		reported = true;
	}
	renderTime = timer.LogTime("BounceLight::Render");
}
