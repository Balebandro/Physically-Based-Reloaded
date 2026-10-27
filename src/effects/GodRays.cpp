#include "GodRays.h"

// From NVR Optimized, without its GPU profiler and Max Quality switch; its test tools (validation logs) compile out.
#define NVR_TEST_TOOLS 0

void GodRaysEffect::UpdateConstants() {
	Constants.Data.z = std::lerp(nightMult, dayMult, TheShaderManager->GameState.transitionCurve);
	Constants.Ray.w = rayVisibility * sunGlareEnabled ? TheShaderManager->ShaderConst.sunGlare : 1.0;
}

void GodRaysEffect::UpdateSettings(){
	dayMult = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "DayMultiplier");
	nightMult = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "NightMultiplier");
	sunGlareEnabled = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "SunGlareEnabled");
	skipEmpty = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "SkipEmpty") != 0;
	skipIdle = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "SkipIdle") != 0;
	probeLevel = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "ProbeLog");

	Constants.Ray.x = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayIntensity");
	Constants.Ray.y = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayLength");
	Constants.Ray.z = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayDensity");
	rayVisibility = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayVisibility");
	Constants.RayColor.x = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayR");
	Constants.RayColor.y = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayG");
	Constants.RayColor.z = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayB");
	Constants.RayColor.w = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "Saturate");
	Constants.Data.x = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "LightShaftPasses");
	Constants.Data.y = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "Luminance");
	Constants.Data.w = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "TimeEnabled");
}

void GodRaysEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_GodRaysRay", &Constants.Ray);
	TheShaderManager->RegisterConstant("TESR_GodRaysRayColor", &Constants.RayColor);
	TheShaderManager->RegisterConstant("TESR_GodRaysData", &Constants.Data);
}

void GodRaysEffect::RegisterTextures() {
	const int width = (TheRenderManager->width + 1) / 2;
	const int height = (TheRenderManager->height + 1) / 2;
	TheTextureManager->InitTexture("NVR_GodRaysBuffer0", &raysTexture[0], &raysSurface[0], width, height, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("NVR_GodRaysBuffer1", &raysTexture[1], &raysSurface[1], width, height, D3DFMT_A16B16G16R16F);
	const int lowWidth = (TheRenderManager->width + 3) / 4;
	const int lowHeight = (TheRenderManager->height + 3) / 4;
	TheTextureManager->InitTexture("NVR_GodRaysBufferLow0", &raysTextureLow[0], &raysSurfaceLow[0], lowWidth, lowHeight, D3DFMT_A16B16G16R16F);
	TheTextureManager->InitTexture("NVR_GodRaysBufferLow1", &raysTextureLow[1], &raysSurfaceLow[1], lowWidth, lowHeight, D3DFMT_A16B16G16R16F);

	static const char* names[2][4] = { { "NVR_GodRaysMax0", "NVR_GodRaysMax1", "NVR_GodRaysMax2", "NVR_GodRaysMax3" },
		{ "NVR_GodRaysMaxLow0", "NVR_GodRaysMaxLow1", "NVR_GodRaysMaxLow2", "NVR_GodRaysMaxLow3" } };
	const UINT sizes[2][2] = { { (UINT)width, (UINT)height }, { (UINT)lowWidth, (UINT)lowHeight } };
	for (int set = 0; set < 2; set++) {
		UINT w = sizes[set][0], h = sizes[set][1];
		maxSteps[set] = 0;
		while ((w > 1 || h > 1) && maxSteps[set] < 4) {
			w = (w + 7) / 8; h = (h + 7) / 8;
			const int i = maxSteps[set]++;
			maxWidth[set][i] = w; maxHeight[set][i] = h;
			TheTextureManager->InitTexture(names[set][i], &maxTexture[set][i], &maxSurface[set][i], w, h, D3DFMT_A16B16G16R16F);
		}
		if (w > 1 || h > 1) maxSteps[set] = 0;
	}
}

bool GodRaysEffect::RunReduce(IDirect3DDevice9* Device, IDirect3DTexture9* source, UINT width, UINT height, int set) {
	D3DXHANDLE technique = TechniqueHandle(techReduce, "GodRaysMaxReduce");
	D3DXHANDLE reduceHandle = ParameterHandle(paramReduce, "NVR_GodRaysReduce");
	if (!technique || !reduceHandle || maxSteps[set] < 1 || !source) return false;
	for (int i = 0; i < maxSteps[set]; i++) if (!maxTexture[set][i] || !maxSurface[set][i]) return false;
	UINT passes = 0;
	HRESULT result = Effect->SetTechnique(technique);
	if (SUCCEEDED(result)) result = Effect->Begin(&passes, 0);
	if (FAILED(result)) return false;
	Device->SetRenderState(D3DRS_SCISSORTESTENABLE, FALSE);
	IDirect3DTexture9* from = source;
	UINT w = width, h = height;
	for (int i = 0; i < maxSteps[set] && SUCCEEDED(result); i++) {
		const D3DXVECTOR4 inverse(1.0f / w, 1.0f / h, 0.0f, 0.0f);
		Effect->SetVector(reduceHandle, &inverse);
		const D3DVIEWPORT9 viewport = { 0, 0, maxWidth[set][i], maxHeight[set][i], 0.0f, 1.0f };
		result = Device->SetRenderTarget(0, maxSurface[set][i]);
		if (SUCCEEDED(result)) result = Device->SetViewport(&viewport);
		if (SUCCEEDED(result)) result = Effect->BeginPass(0);
		if (FAILED(result)) break;
		Device->SetTexture(5, from);
		result = Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
		const HRESULT endResult = Effect->EndPass();
		if (SUCCEEDED(result)) result = endResult;
		Device->SetTexture(5, nullptr);
		from = maxTexture[set][i]; w = maxWidth[set][i]; h = maxHeight[set][i];
	}
	Effect->End();
	return SUCCEEDED(result);
}

static float HalfToFloat(UInt16 h) {
	const int e = (h >> 10) & 31, m = h & 1023;
	float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexpf((float)(m + 1024), e - 25);
	return (h & 0x8000) ? -v : v;
}

#if NVR_TEST_TOOLS
static bool ReadMax(IDirect3DDevice9* Device, IDirect3DSurface9* surface, float& value) {
	static IDirect3DSurface9* read = nullptr;
	if (!surface) return false;
	if (!read && FAILED(Device->CreateOffscreenPlainSurface(1, 1, D3DFMT_A16B16G16R16F, D3DPOOL_SYSTEMMEM, &read, NULL))) return false;
	if (FAILED(Device->GetRenderTargetData(surface, read))) return false;
	D3DLOCKED_RECT locked = {};
	if (FAILED(read->LockRect(&locked, NULL, D3DLOCK_READONLY))) return false;
	const UInt16* p = (const UInt16*)locked.pBits;
	value = (std::max)(HalfToFloat(p[0]), (std::max)(HalfToFloat(p[1]), HalfToFloat(p[2])));
	read->UnlockRect();
	return true;
}
#endif

bool GodRaysEffect::Probe(IDirect3DDevice9* Device, IDirect3DTexture9* const* textures, UINT width, UINT height, int set, bool lowRes) {
#if NVR_TEST_TOOLS
	static int check = 0;
	static unsigned frame = 0;
	if ((frame % 60) == 0) check = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "ProbeLog");
	frame++;
	if (check <= 0 || (frame % 8) != 0 || maxSteps[set] < 1) return false;
	float skyMax = -1.0f, maskMax = -1.0f;
	IDirect3DSurface9* last = maxSurface[set][maxSteps[set] - 1];
	if (RunReduce(Device, textures[0], width, height, set)) ReadMax(Device, last, skyMax);
	if (RunReduce(Device, textures[1], width, height, set)) ReadMax(Device, last, maskMax);
	const ShaderConstants& c = TheShaderManager->ShaderConst;
	const D3DXMATRIX& P = TheRenderManager->projMatrix;
	const float z = c.ViewSpaceLightDir.z;
	const float ndcX = z > 1e-4f ? c.ViewSpaceLightDir.x * P._11 / z : 99.0f, ndcY = z > 1e-4f ? c.ViewSpaceLightDir.y * P._22 / z : 99.0f;
	const float sunZ = c.SunPosition.z, sunHeight = 1.0f - (sunZ > 0.0f ? sunZ : 0.0f);
	const float threshold = 2.0f * (1.0f - powf(fabsf(sunHeight), 8.0f));
	const float azimuth = atan2f(c.SunPosition.x, c.SunPosition.y) * 57.29578f, elevation = asinf(sunZ < -1.0f ? -1.0f : sunZ > 1.0f ? 1.0f : sunZ) * 57.29578f;
	Logger::Log("GODRAYS PROBE: hour %.2f sun az %.1f el %.1f view (%.3f %.3f %.3f) ndc (%.2f %.2f) %s skyMax %.4f maskMax %.6f threshold %.3f %s",
		c.GameTime.y, azimuth, elevation, c.ViewSpaceLightDir.x, c.ViewSpaceLightDir.y, c.ViewSpaceLightDir.z, ndcX, ndcY,
		z <= 0.0f ? "behind" : (fabsf(ndcX) <= 1.0f && fabsf(ndcY) <= 1.0f) ? "ON-SCREEN" : "off-screen", skyMax, maskMax, threshold,
		lowRes ? "lowres" : "half");
	return check >= 2 && maskMax == 0.0f;
#else
	return false;
#endif
}

#if NVR_TEST_TOOLS
static void CombineCheck(IDirect3DDevice9* Device, IDirect3DSurface9* input, IDirect3DSurface9* output) {
	static IDirect3DSurface9* readA = nullptr;
	static IDirect3DSurface9* readB = nullptr;
	static D3DSURFACE_DESC have = {};
	static unsigned checks = 0;
	D3DSURFACE_DESC d = {};
	if (!input || !output || FAILED(input->GetDesc(&d)) || d.Format != D3DFMT_A16B16G16R16F) return;
	if (!readA || d.Width != have.Width || d.Height != have.Height) {
		if (readA) { readA->Release(); readA = nullptr; }
		if (readB) { readB->Release(); readB = nullptr; }
		if (FAILED(Device->CreateOffscreenPlainSurface(d.Width, d.Height, d.Format, D3DPOOL_SYSTEMMEM, &readA, NULL)) ||
			FAILED(Device->CreateOffscreenPlainSurface(d.Width, d.Height, d.Format, D3DPOOL_SYSTEMMEM, &readB, NULL))) {
			if (readA) { readA->Release(); readA = nullptr; }
			return;
		}
		have = d;
	}
	if (FAILED(Device->GetRenderTargetData(input, readA)) || FAILED(Device->GetRenderTargetData(output, readB))) return;
	D3DLOCKED_RECT la = {}, lb = {};
	if (FAILED(readA->LockRect(&la, NULL, D3DLOCK_READONLY))) return;
	if (FAILED(readB->LockRect(&lb, NULL, D3DLOCK_READONLY))) { readA->UnlockRect(); return; }
	unsigned differ = 0, ulp1 = 0, ulp2 = 0, ulp3 = 0, signs = 0, alphaDiffer = 0;
	float inA0 = 1e30f, inA1 = -1e30f, outA0 = 1e30f, outA1 = -1e30f, worstIn = 0.0f, worstOut = 0.0f;
	unsigned maxUlp = 0;
	for (UINT y = 0; y < d.Height; y++) {
		const UInt16* pa = (const UInt16*)((const UInt8*)la.pBits + (size_t)y * la.Pitch);
		const UInt16* pb = (const UInt16*)((const UInt8*)lb.pBits + (size_t)y * lb.Pitch);
		for (UINT x = 0; x < d.Width; x++, pa += 4, pb += 4) {
			bool any = false;
			unsigned worst = 0;
			for (int c = 0; c < 3; c++) {
				if (pa[c] == pb[c]) continue;
				any = true;
				if ((pa[c] ^ pb[c]) & 0x8000) { signs++; worst = 0xFFFF; continue; }
				const unsigned ulp = pa[c] > pb[c] ? pa[c] - pb[c] : pb[c] - pa[c];
				if (ulp > worst) { worst = ulp; if (ulp > maxUlp) { maxUlp = ulp; worstIn = HalfToFloat(pa[c]); worstOut = HalfToFloat(pb[c]); } }
			}
			if (any) { differ++; if (worst == 1) ulp1++; else if (worst == 2) ulp2++; else ulp3++; }
			const float ai = HalfToFloat(pa[3]), ao = HalfToFloat(pb[3]);
			if (pa[3] != pb[3]) alphaDiffer++;
			inA0 = (std::min)(inA0, ai); inA1 = (std::max)(inA1, ai); outA0 = (std::min)(outA0, ao); outA1 = (std::max)(outA1, ao);
		}
	}
	readB->UnlockRect();
	readA->UnlockRect();
	if (++checks <= 40)
		Logger::Log("GODRAYS COMBINE CHECK (mask empty): %ux%u texels, colour differs in %u (%.3f %%): worst ulp 1: %u, 2: %u, 3+: %u, sign flips %u, max %u ulp (in %.5f -> out %.5f); alpha in %.3f..%.3f out %.3f..%.3f, alpha differs in %u",
			d.Width, d.Height, differ, 100.0 * differ / ((double)d.Width * d.Height), ulp1, ulp2, ulp3, signs, maxUlp, worstIn, worstOut, inA0, inA1, outA0, outA1, alphaDiffer);
}
#endif

bool GodRaysEffect::IdleGuard() const {
	const ShaderConstants& c = TheShaderManager->ShaderConst;
	const D3DXMATRIX& P = TheRenderManager->projMatrix;
	const float x = c.ViewSpaceLightDir.x, y = c.ViewSpaceLightDir.y, z = c.ViewSpaceLightDir.z;
	if (!std::isfinite(x + y + z) || !std::isfinite(c.SunPosition.z) || !(P._11 > 0.01f) || !(P._22 > 0.01f)) return false;
	if (c.SunPosition.z < 0.342f) return false;
	const float length = sqrtf(x * x + y * y + z * z);
	if (!(length > 1e-4f)) return false;
	const float sinMargin = 0.20791f;
	const float nx = fabsf(x) / length, ny = fabsf(y) / length, nz = z / length;
	const float hx = 1.0f / sqrtf(1.0f + P._11 * P._11), cx = P._11 * hx;
	const float hy = 1.0f / sqrtf(1.0f + P._22 * P._22), cy = P._22 * hy;
	return nx * cx - nz * hx >= sinMargin || ny * cy - nz * hy >= sinMargin;
}

void GodRaysEffect::IdlePoll() {
	if (!idleQuery || !idlePending) return;
	DWORD pixels = 0;
	const HRESULT result = idleQuery->GetData(&pixels, sizeof(DWORD), 0);
	if (result == S_FALSE) {
		if (++idleAge > 8) idleEmptyKnown = false;
		return;
	}
	idlePending = false;
	if (result != S_OK) { idleEmptyKnown = false; return; }
	idleEmptyKnown = pixels == 0 && TheFrameRateManager->FrameNumber - idleIssueFrame <= 8;
	idleLastPixels = pixels;
#if NVR_TEST_TOOLS
	if (idleTruth >= 0.0f) {
		const bool truthBright = !(idleTruth < idleLimitAtIssue);
		idleValidated++;
		if (truthBright != (pixels != 0)) {
			idleValidateBad++;
			if (idleValidateBad <= 8) Logger::Log("GODRAYS IDLE QUERY CHECK: DISAGREE: query counted %u pixels, read-back sky max %.4f, limit %.4f", (unsigned)pixels, idleTruth, idleLimitAtIssue);
		}
		else if (truthBright) idleValidateBright++;
		if (idleValidated % 25 == 0)
			Logger::Log("GODRAYS IDLE QUERY CHECK: %u results, %u agree with the read-back, %u disagree (%u of the agreeing were bright)", idleValidated, idleValidated - idleValidateBad, idleValidateBad, idleValidateBright);
		idleTruth = -1.0f;
	}
#endif
}

bool GodRaysEffect::IdleIssue(IDirect3DDevice9* Device, IDirect3DTexture9* skyMask, UINT width, UINT height, int set) {
	if (idlePending || idleQueryBroken || maxSteps[set] < 2) return false;
	if (!idleQuery && FAILED(Device->CreateQuery(D3DQUERYTYPE_OCCLUSION, &idleQuery))) { idleQuery = nullptr; idleQueryBroken = true; Logger::Log("God rays SkipIdle: no occlusion queries on this device; the option does nothing."); return false; }
	D3DXHANDLE technique = TechniqueHandle(techIdle, "GodRaysIdleTest");
	D3DXHANDLE skipHandle = ParameterHandle(paramSkip, "NVR_GodRaysSkip");
	if (!technique || !skipHandle) return false;
	const float sunHeight = 1.0f - (std::max)(TheShaderManager->ShaderConst.SunPosition.z, 0.0f);
	idleLimit = 0.8f * 2.0f * (1.0f - powf(fabsf(sunHeight), 8.0f));
	if (!RunReduce(Device, skyMask, width, height, set)) return false;
#if NVR_TEST_TOOLS
	idleTruth = -1.0f;
	if (probeLevel >= 3) {
		float truth = -1.0f;
		if (ReadMax(Device, maxSurface[set][maxSteps[set] - 1], truth)) { idleTruth = truth; idleLimitAtIssue = idleLimit; }
	}
#endif
	UINT passes = 0;
	HRESULT result = Effect->SetTechnique(technique);
	if (SUCCEEDED(result)) { const D3DXVECTOR4 skip(0.0f, 0.0f, idleLimit, 0.0f); Effect->SetVector(skipHandle, &skip); result = Effect->Begin(&passes, 0); }
	if (FAILED(result)) return false;
	Device->SetRenderState(D3DRS_SCISSORTESTENABLE, FALSE);
	const D3DVIEWPORT9 viewport = { 0, 0, 1, 1, 0.0f, 1.0f };
	result = Device->SetRenderTarget(0, maxSurface[set][0]);
	if (SUCCEEDED(result)) result = Device->SetViewport(&viewport);
	if (SUCCEEDED(result)) result = Effect->BeginPass(0);
	if (SUCCEEDED(result)) {
		Device->SetTexture(6, maxTexture[set][maxSteps[set] - 1]);
		idleQuery->Issue(D3DISSUE_BEGIN);
		result = Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
		idleQuery->Issue(D3DISSUE_END);
		Effect->EndPass();
		Device->SetTexture(6, nullptr);
	}
	Effect->End();
	if (FAILED(result)) return false;
	idlePending = true;
	idleAge = 0;
	idleSinceCheck = 0;
	idleIssueFrame = TheFrameRateManager->FrameNumber;
	return true;
}

void GodRaysEffect::IdleStats() {
#if NVR_TEST_TOOLS
	if (!skipIdle || !GpuTimer::Enabled) return;
	if (++idleWindow < 120) return;
	Logger::Log("GODRAYS IDLE: last %u frames: skipped %u, check frames %u (of which only the check %u), full %u, guard refused %u; last query pixels %u limit %.3f, known empty %d",
		idleWindow, idleSkipped, idleChecks, idleCheckOnly, idleFull, idleGuardRefused, (unsigned)idleLastPixels, idleLimit, idleEmptyKnown ? 1 : 0);
	idleWindow = idleSkipped = idleChecks = idleCheckOnly = idleFull = idleGuardRefused = 0;
#endif
}

bool GodRaysEffect::ShouldRender() {
	return TheShaderManager->GameState.isExterior && !TheShaderManager->GameState.isUnderwater && TheShaderManager->GameState.dayLight > 0.5;
}

bool GodRaysEffect::RenderDedicated(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
	IDirect3DSurface9* RenderedSurface) {
	if (dedicatedRenderFailed) return false;
	const bool lowRes = TheSettingManager->SettingsMain.Main.GodRaysLowRes &&
		raysTextureLow[0] && raysTextureLow[1] && raysSurfaceLow[0] && raysSurfaceLow[1];
	IDirect3DTexture9** textures = lowRes ? raysTextureLow : raysTexture;
	IDirect3DSurface9** surfaces = lowRes ? raysSurfaceLow : raysSurface;
	const UINT divisor = lowRes ? 4 : 2;
	D3DXHANDLE technique = TechniqueHandle(techDedicated, "DedicatedGodRays");
	D3DXHANDLE layoutHandle = ParameterHandle(paramLayout, "NVR_GodRaysLayout");
	D3DXTECHNIQUE_DESC description = {};
	D3DVIEWPORT9 original = {};
	D3DSURFACE_DESC target = {}, scratch = {}, rays = {};
	if (!technique || !layoutHandle || FAILED(Effect->GetTechniqueDesc(technique, &description)) ||
		description.Passes != 6 || !RenderedSurface || !textures[0] || !textures[1] ||
		!surfaces[0] || !surfaces[1] ||
		FAILED(Device->GetViewport(&original)) || FAILED(RenderTarget->GetDesc(&target)) ||
		FAILED(RenderedSurface->GetDesc(&scratch)) || FAILED(surfaces[0]->GetDesc(&rays)) ||
		original.X || original.Y ||
		original.Width != target.Width || original.Height != target.Height ||
		scratch.Width != target.Width || scratch.Height != target.Height ||
		rays.Width != (target.Width + divisor - 1) / divisor || rays.Height != (target.Height + divisor - 1) / divisor ||
		target.MultiSampleType != D3DMULTISAMPLE_NONE)
		return false;

	FrameChain& chain = TheShaderManager->Chain;
	const bool chained = chain.Owns(RenderTarget, RenderedSurface);
	IDirect3DSurface9* finalTarget = chained ? chain.Output() : RenderTarget;
	D3DVIEWPORT9 reduced = original;
	reduced.Width = rays.Width;
	reduced.Height = rays.Height;
	D3DXVECTOR4 layout((float)reduced.Width / original.Width,
		(float)reduced.Height / original.Height, 1.0f / reduced.Width, 1.0f / reduced.Height);
	IDirect3DSurface9* depthSurface = nullptr;
	DWORD oldScissorEnabled = FALSE;
	HRESULT result = Device->GetRenderState(D3DRS_SCISSORTESTENABLE, &oldScissorEnabled);
	if (SUCCEEDED(result)) result = Device->GetDepthStencilSurface(&depthSurface);
	if (SUCCEEDED(result) && !ReShadeIntegration::KeepDepthBound()) result = Device->SetDepthStencilSurface(nullptr);
	if (FAILED(result)) {
		if (depthSurface) depthSurface->Release();
		dedicatedRenderFailed = true;
		return false;
	}

	const int set = lowRes ? 1 : 0;
	D3DXHANDLE skipHandle = ParameterHandle(paramSkip, "NVR_GodRaysSkip");
	bool maskReduced = false;
	bool combineCheck = false;
	bool heavySkipped = false;
	const bool checkOnly = idleCheckFrame && idleEmptyKnown;
	UINT passes = 0;
	for (int stage = 0; stage < 2 && SUCCEEDED(result); stage++) {
	Effect->SetTechnique(technique);
	SetCT();
	Effect->SetVector(layoutHandle, &layout);
	if (skipHandle) { const D3DXVECTOR4 skip(maskReduced ? 1.0f : 0.0f, skipIdle ? 1.0f : 0.0f, idleLimit, 0.0f); Effect->SetVector(skipHandle, &skip); }
	result = Effect->Begin(&passes, 0);
	if (SUCCEEDED(result)) {
		const UINT first = stage == 0 ? 0 : 2, last = stage == 0 ? (passes < 2 ? passes : (checkOnly ? 1 : 2)) : passes;
		for (UINT p = first; p < last && SUCCEEDED(result); ++p) {
			const bool combine = p == passes - 1;
			Device->SetTexture(5, nullptr);
			result = Device->SetRenderTarget(0, combine ? finalTarget : surfaces[p & 1]);
			if (SUCCEEDED(result)) result = Device->SetViewport(combine ? &original : &reduced);
			if (SUCCEEDED(result)) result = Device->SetRenderState(D3DRS_SCISSORTESTENABLE, combine ? oldScissorEnabled : FALSE);
			if (FAILED(result)) break;
			result = Effect->BeginPass(p);
			if (FAILED(result)) break;
			if (p > 0) Device->SetTexture(5, textures[combine ? 0 : (p - 1) & 1]);
			if (p >= 2) Device->SetTexture(6, maskReduced ? maxTexture[set][maxSteps[set] - 1] : nullptr);
			result = Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
			HRESULT endResult = Effect->EndPass();
			if (SUCCEEDED(result)) result = endResult;
		}
		Effect->End();
	}
	if (stage == 0 && SUCCEEDED(result)) {
		if (idleCheckFrame) {
			idleChecks++;
			const bool issued = IdleIssue(Device, textures[0], reduced.Width, reduced.Height, set);
			if (!issued && !idlePending) idleEmptyKnown = false;
			if (checkOnly) { heavySkipped = true; break; }
		}
		combineCheck = Probe(Device, textures, reduced.Width, reduced.Height, set, lowRes);
		if (skipEmpty && skipHandle) maskReduced = RunReduce(Device, textures[1], reduced.Width, reduced.Height, set);
	}
	}
#if NVR_TEST_TOOLS
	if (combineCheck && SUCCEEDED(result) && !heavySkipped) CombineCheck(Device, RenderedSurface, finalTarget);
#endif
	Device->SetTexture(6, nullptr);
	Device->SetTexture(5, nullptr);
	Device->SetRenderTarget(0, RenderTarget);
	Device->SetViewport(&original);
	Device->SetRenderState(D3DRS_SCISSORTESTENABLE, oldScissorEnabled);
	Device->SetDepthStencilSurface(depthSurface);
	if (depthSurface) depthSurface->Release();
	if (SUCCEEDED(result) && !heavySkipped) {
		if (chained) chain.Commit();
		else result = Device->StretchRect(RenderTarget, NULL, RenderedSurface, NULL, D3DTEXF_NONE);
	}
	idleCheckSkipped = heavySkipped;
	if (FAILED(result)) {
		Device->StretchRect(RenderedSurface, NULL, RenderTarget, NULL, D3DTEXF_NONE);
		dedicatedRenderFailed = true;
		Logger::Log("Dedicated god rays failed (%08lx); using packed path until restart.", result);
		return false;
	}
	static bool reported[2] = {};
	if (!reported[lowRes]) {
		Logger::Log("UNOFFICIAL dedicated god rays active: %ux%u A16B16G16R16F ping-pong, six passes%s.",
			reduced.Width, reduced.Height, lowRes ? " (GodRaysLowRes)" : "");
		reported[lowRes] = true;
	}
	return true;
}

void GodRaysEffect::Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
	IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget,
	IDirect3DSurface9* SourceBuffer) {
	if (!Enabled || !Effect || !ShouldRender()) { renderTime = 0; idleEmptyKnown = false; idleSinceCheck = 4; return; }

	idleCheckFrame = false;
	idleCheckSkipped = false;
	if (skipIdle && !dedicatedRenderFailed) {
		IdlePoll();
		if (IdleGuard()) {
			idleSinceCheck++;
			if (idleEmptyKnown && idleSinceCheck < 4) { idleSkipped++; renderTime = 0; IdleStats(); return; }
			idleCheckFrame = true;
		}
		else {
			idleEmptyKnown = false;
			idleGuardRefused++;
			if (probeLevel >= 3 && (++idleValidateTick % 8) == 0) idleCheckFrame = true;
		}
	}
	else { idleEmptyKnown = false; idleSinceCheck = 4; }

	{
		auto timer = TimeLogger();
		if (RenderDedicated(Device, RenderTarget, RenderedSurface)) {
			if (idleCheckSkipped) idleCheckOnly++; else idleFull++;
			renderTime = timer.LogTime("GodRays::DedicatedRender");
			IdleStats();
			return;
		}
	}

	D3DXHANDLE technique = Effect->GetTechnique(techniqueIndex);
	D3DXTECHNIQUE_DESC description = {};
	D3DSURFACE_DESC target = {}, scratch = {};
	DWORD oldScissorEnabled = FALSE;
	RECT oldScissor = {};
	if (packedRenderFailed || !technique || !RenderedSurface || !SourceBuffer ||
		FAILED(Effect->GetTechniqueDesc(technique, &description)) || description.Passes != 6 ||
		FAILED(RenderTarget->GetDesc(&target)) || FAILED(RenderedSurface->GetDesc(&scratch)) ||
		target.Width != scratch.Width || target.Height != scratch.Height ||
		FAILED(Device->GetRenderState(D3DRS_SCISSORTESTENABLE, &oldScissorEnabled)) ||
		FAILED(Device->GetScissorRect(&oldScissor))) {
		EffectRecord::Render(Device, RenderTarget, RenderedSurface, techniqueIndex, ClearRenderTarget, SourceBuffer);
		return;
	}

	auto timer = TimeLogger();
	TheShaderManager->Chain.Sync();
	RECT packed = {0, 0, (LONG)(target.Width / 2), (LONG)(target.Height / 2)};
	D3DRECT packedClear = {packed.left, packed.top, packed.right, packed.bottom};
	HRESULT result = Device->StretchRect(RenderTarget, NULL, SourceBuffer, NULL, D3DTEXF_LINEAR);
	if (SUCCEEDED(result)) result = Effect->SetTechnique(technique);
	if (SUCCEEDED(result)) SetCT();
	UINT passes = 0;
	if (SUCCEEDED(result)) result = Effect->Begin(&passes, 0);
	if (SUCCEEDED(result)) {
		for (UINT p = 0; p < passes && SUCCEEDED(result); ++p) {
			const bool combine = p == passes - 1;
			if (combine) {
				result = Device->SetScissorRect(&oldScissor);
				if (SUCCEEDED(result)) result = Device->SetRenderState(D3DRS_SCISSORTESTENABLE, oldScissorEnabled);
				if (SUCCEEDED(result) && ClearRenderTarget)
					result = Device->Clear(0, NULL, D3DCLEAR_TARGET, D3DCOLOR_ARGB(255, 0, 0, 0), 1.0f, 0);
			}
			else {
				result = Device->SetScissorRect(&packed);
				if (SUCCEEDED(result)) result = Device->SetRenderState(D3DRS_SCISSORTESTENABLE, TRUE);
				if (SUCCEEDED(result) && ClearRenderTarget)
					result = Device->Clear(1, &packedClear, D3DCLEAR_TARGET, D3DCOLOR_ARGB(255, 0, 0, 0), 1.0f, 0);
			}
			if (FAILED(result)) break;
			result = Effect->BeginPass(p);
			if (FAILED(result)) break;
			result = Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
			HRESULT endResult = Effect->EndPass();
			if (SUCCEEDED(result)) result = endResult;
			if (SUCCEEDED(result)) result = Device->StretchRect(RenderTarget, combine ? NULL : &packed,
				RenderedSurface, combine ? NULL : &packed, D3DTEXF_LINEAR);
		}
		Effect->End();
	}
	Device->SetScissorRect(&oldScissor);
	Device->SetRenderState(D3DRS_SCISSORTESTENABLE, oldScissorEnabled);

	if (FAILED(result)) {
		Device->StretchRect(SourceBuffer, NULL, RenderTarget, NULL, D3DTEXF_NONE);
		Device->StretchRect(SourceBuffer, NULL, RenderedSurface, NULL, D3DTEXF_NONE);
		packedRenderFailed = true;
		Logger::Log("Packed god rays failed (%08lx); using legacy path until restart.", result);
		EffectRecord::Render(Device, RenderTarget, RenderedSurface, techniqueIndex, ClearRenderTarget, SourceBuffer);
		return;
	}
	static bool reported = false;
	if (!reported) {
		Logger::Log("UNOFFICIAL packed god rays active: %ux%u intermediate region.", packed.right, packed.bottom);
		reported = true;
	}
	renderTime = timer.LogTime("GodRays::PackedRender");
}
