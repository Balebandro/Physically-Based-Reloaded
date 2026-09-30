#pragma once

// CREDIT: TAA for New Vegas Reloaded by Conor. See TAA.fx.hlsl for upstream credits.

// Temporal anti-aliasing: temporal accumulation with camera reprojection, plus sub-pixel jitter of
// the world render so a still image gets anti-aliased too. Ported from Oblivion Reloaded E3's TAA;
// see TAA.fx.hlsl for what changed and why, and BeginJitter below for how the jitter is applied.
//
// Two passes per frame, both full resolution, over a pair of FP16 history buffers used in turn:
//   Resolve: current frame + reprojected last frame (one buffer) -> this frame (the other buffer)
//   Output:  this frame's buffer -> the frame
// The buffers then swap roles, so this frame's resolve is next frame's history with no copy. Resolve
// cannot write the history it is reading, hence two of them. The history is FP16
// rather than the frame's 8 bits because at a 0.9 blend weight each frame moves the history only
// 10% of the way to the current value, and in 8 bits any difference under about 5/255 rounds
// straight back to the old value -- a ghost that stops fading and never clears.
class TAAEffect : public EffectRecord
{
public:
	TAAEffect() : EffectRecord("TAA") {};

	struct TAASettingsStruct {
		float	HistoryWeight;
		float	ClipGamma;
		int		DebugView;
		bool	Jitter;
		float	WeaponTAA;
	};
	TAASettingsStruct	Settings;

	struct TAAStruct {
		D3DXVECTOR4	Data;				// x: history weight, y: clip gamma, z: history valid (0/1), w: debug view (0 = off)
		D3DXVECTOR4	PrevProjection;		// x: last frame's projMatrix._11, y: its _22
		D3DXVECTOR4	CameraDelta;		// xyz: camera position this frame minus last frame's
		D3DXVECTOR4	Weapon;				// x: history weight scale on first-person weapon pixels
		D3DXMATRIX	PrevViewTransform;	// last frame's viewMatrix; the shader reads only its rotation
	};
	TAAStruct	Constants;

	// Two history buffers used in turn: each frame resolves into one while reading last frame's result
	// from the other, then the roles swap. No copy between them, and the pair is the only full-size
	// storage TAA needs.
	struct TAATexturesStruct {
		IDirect3DTexture9*	HistoryTexture[2] = { nullptr, nullptr };
		IDirect3DSurface9*	HistorySurface[2] = { nullptr, nullptr };
	};
	TAATexturesStruct	Textures;

	void	UpdateConstants();
	void	RegisterConstants();
	void	RegisterTextures();
	void	UpdateSettings();

	void	Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer);

	// Bracket the world scene render (RenderWorldSceneGraphHook) with these. Begin shifts the
	// world camera's frustum by this frame's sub-pixel offset; End puts it back. Both are no-ops
	// unless TAA will actually resolve this frame, and End is safe to call when Begin did nothing.
	void	BeginJitter();
	void	EndJitter();
	bool	IsJitterActive() const { return jitterActive; }

private:
	bool		historyValid = false;
	D3DXVECTOR4	prevCameraPosition = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);

	static const int JitterSequenceLength = 8;
	int			jitterIndex = 0;
	bool		jitterActive = false;
	NiCamera*	jitterCamera = nullptr;
	float		frustumShiftX = 0.0f;
	float		frustumShiftY = 0.0f;

	int			historyRead = 0;	// which HistoryTexture holds last frame's resolve

	bool	WillResolveThisFrame();
	bool	HasTextures() const;

	void	RememberCamera();

	// Technique handles, looked up once per loaded Effect rather than by name on every draw.
	enum Technique { TechniqueResolve, TechniqueOutput, TechniqueDebug, TechniqueCount };
	D3DXHANDLE	techniques[TechniqueCount] = {};
	UInt32		techniquesGeneration = 0;	// the Effect LoadGeneration the handles belong to; 0 = none yet
	bool	DrawTechnique(Technique technique);
};
