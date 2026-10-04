#pragma once

class SunShadowsEffect : public EffectRecord
{
public:

	SunShadowsEffect() : EffectRecord("SunShadows") {};

	struct SunShadowStruct {
	};
	SunShadowStruct	Constants;

	void	SetCT();
	void	RegisterTextures();
	void	Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer);

	void	UpdateConstants() {};
	void	RegisterConstants() {};
	void	UpdateSettings() {};

private:
	// Two targets the passes alternate through, so none reads the texture it renders to (ported
	// from NVR UNOFFICIAL Optimized, P8-P26).
	IDirect3DTexture9*	scratchTexture[2] = {};
	IDirect3DSurface9*	scratchSurface[2] = {};
	bool				pingPongFailed = false;
};
