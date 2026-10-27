#pragma once

class GodRaysEffect : public EffectRecord
{
public:
	GodRaysEffect() : EffectRecord("GodRays") {};

	struct GodRaysStruct {
		D3DXVECTOR4		Ray;
		D3DXVECTOR4		RayColor;
		D3DXVECTOR4		Data;
	};
	GodRaysStruct	Constants;

	void	UpdateConstants();
	void	RegisterConstants();
	void	RegisterTextures();
	void	UpdateSettings();
	bool	ShouldRender();

	float dayMult;
	float nightMult;
	bool sunGlareEnabled;
	float rayVisibility;
	bool packedRenderFailed = false;
	bool dedicatedRenderFailed = false;
	CachedHandle techDedicated, paramLayout;
	bool skipEmpty = true;
	CachedHandle techReduce, paramReduce, paramSkip;
	IDirect3DTexture9* maxTexture[2][4] = {};
	IDirect3DSurface9* maxSurface[2][4] = {};
	UINT maxWidth[2][4] = {}, maxHeight[2][4] = {};
	int maxSteps[2] = {};
	bool RunReduce(IDirect3DDevice9* Device, IDirect3DTexture9* source, UINT width, UINT height, int set);
	bool skipIdle = false;
	bool idleEmptyKnown = false;
	bool idleCheckFrame = false, idleCheckSkipped = false;
	unsigned idleIssueFrame = 0;
	int idleSinceCheck = 0, idleAge = 0, probeLevel = 0;
	bool idlePending = false, idleQueryBroken = false;
	float idleLimit = 0.0f, idleTruth = -1.0f, idleLimitAtIssue = 0.0f;
	DWORD idleLastPixels = 0;
	IDirect3DQuery9* idleQuery = nullptr;
	CachedHandle techIdle;
	unsigned idleWindow = 0, idleSkipped = 0, idleChecks = 0, idleCheckOnly = 0, idleFull = 0, idleGuardRefused = 0, idleValidated = 0, idleValidateBad = 0, idleValidateBright = 0, idleValidateTick = 0;
	bool IdleGuard() const;
	void IdlePoll();
	bool IdleIssue(IDirect3DDevice9* Device, IDirect3DTexture9* skyMask, UINT width, UINT height, int set);
	void IdleStats();
	bool Probe(IDirect3DDevice9* Device, IDirect3DTexture9* const* textures, UINT width, UINT height, int set, bool lowRes);
	IDirect3DTexture9* raysTexture[2] = {};
	IDirect3DSurface9* raysSurface[2] = {};
	IDirect3DTexture9* raysTextureLow[2] = {};
	IDirect3DSurface9* raysSurfaceLow[2] = {};

	bool RenderDedicated(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
		IDirect3DSurface9* RenderedSurface);
	void Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
		IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget,
		IDirect3DSurface9* SourceBuffer) override;
};
