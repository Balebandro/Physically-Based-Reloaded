#pragma once

// Bounce light ([Shaders.BounceLight]), ported from NVR UNOFFICIAL Optimized (P81): one bounce of indirect light from
// what is on screen, worked out at half or quarter resolution (prepare, gather, blur X, blur Y, combine:
// Effects/BounceLight.fx). Lit surfaces pass their light on to nearby ones in their colour; optionally with light guessed
// for samples off the screen, a second bounce carried over from the last frame, the last frame's bounce reused
// (reprojected), and edges it never crosses. Their neon spill is not ported (off in their defaults too).
class BounceLightEffect : public EffectRecord
{
public:
	BounceLightEffect() : EffectRecord("BounceLight") {};

	struct BounceLightStruct {
		D3DXVECTOR4		Data;		// x strength, y radius, z draw distance, w blur radius
	};
	BounceLightStruct	Constants;
	bool				quarterResolution = false;
	float				offScreenLight = 0.0f;
	float				multiBounce = 0.0f;
	bool				temporal = false;
	bool				halfSamples = false;
	bool				hardEdges = false;
	float				strength = 0.0f;

	// A technique or parameter looked up once per loaded effect.
	struct CachedHandle { ID3DXEffect* Owner = nullptr; D3DXHANDLE Handle = NULL; };
	D3DXHANDLE	TechniqueHandle(CachedHandle& cache, const char* name);
	D3DXHANDLE	ParameterHandle(CachedHandle& cache, const char* name);
	CachedHandle paramLayout, paramTemporal, paramAmbient, paramReproject, paramSpill, paramSpillDebug;
	CachedHandle techTemporalHalf, techTemporal, techPlus, techPlusHard, techTemporalHard, techTemporalHalfHard;

	IDirect3DTexture9*	halfHistory[2] = {};
	IDirect3DSurface9*	halfHistorySurface[2] = {};
	IDirect3DTexture9*	quarterHistory[2] = {};
	IDirect3DSurface9*	quarterHistorySurface[2] = {};
	bool				halfHistoryTried = false;
	bool				quarterHistoryTried = false;
	void	EnsureHistory(bool quarter);
	D3DXMATRIX			lastView, lastInvView, lastProj;
	bool				lastValid = false;
	bool				lastQuarter = false;
	bool				historyValid = false;
	int					historyIndex = 0;
	unsigned			frameNumber = 0;
	double				lastTime = 0.0;
	IDirect3DTexture9*	halfTexture[2] = {};
	IDirect3DSurface9*	halfSurface[2] = {};
	IDirect3DTexture9*	quarterTexture[2] = {};
	IDirect3DSurface9*	quarterSurface[2] = {};
	IDirect3DTexture9*	halfPrepTexture = nullptr;
	IDirect3DSurface9*	halfPrepSurface = nullptr;
	IDirect3DTexture9*	quarterPrepTexture = nullptr;
	IDirect3DSurface9*	quarterPrepSurface = nullptr;
	bool				halfTried = false;
	bool				quarterTried = false;
	void	EnsureBuffers(bool quarter);

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	void	Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget,
		IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget,
		IDirect3DSurface9* SourceBuffer) override;
};
