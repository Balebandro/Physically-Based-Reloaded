#pragma once

// The volumetric light, from NVR UNOFFICIAL Optimized (p82): it replaced our own ray-marched one. Their froxel grid path
// is left out: it works with their volumetric fog.
class VolumetricLightEffect : public EffectRecord
{
public:
	VolumetricLightEffect() : EffectRecord("VolumetricLight") {};

	struct LookStruct {
		float	Strength;
		float	Darken;
		float	Density;
		float	MaxDistance;
		float	Anisotropy;
	};
	struct SettingsStruct {
		LookStruct	Day;
		LookStruct	Night;
		int		Steps;
		float	Temporal;
		float	BlurRadius;
		float	RainStrength;
	};
	SettingsStruct	Settings;

	struct ConstantsStruct {
		D3DXVECTOR4	Data;
		D3DXVECTOR4	Data2;
		D3DXVECTOR4	Data3;
		D3DXVECTOR4	Layout;
		D3DXMATRIX	Reproject;
	};
	ConstantsStruct	Constants;

	struct TexturesStruct {
		IDirect3DTexture9* MarchTexture = nullptr;
		IDirect3DSurface9* MarchSurface = nullptr;
		IDirect3DTexture9* BlurTexture = nullptr;
		IDirect3DSurface9* BlurSurface = nullptr;
		IDirect3DTexture9* TempTexture = nullptr;
		IDirect3DSurface9* TempSurface = nullptr;
		IDirect3DTexture9* HistoryTexture = nullptr;
		IDirect3DSurface9* HistorySurface = nullptr;
		// Full res: how much of each pixel blended character surfaces (hair) cover, in alpha (see Hooks/Render.cpp).
		IDirect3DTexture9* CoverageTexture = nullptr;
		IDirect3DSurface9* CoverageSurface = nullptr;
	};
	TexturesStruct	Textures;

	void	UpdateConstants();
	void	RegisterConstants();
	void	RegisterTextures();
	void	UpdateSettings();
	bool	ShouldRender();
	void	RenderBuffers(IDirect3DDevice9* Device);

private:
	D3DXMATRIX	lastView, lastInvView, lastProj;
	UINT		lastRenderedFrame = 0;
	bool		haveHistory = false;
};
