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
	void	UpdateSettings();
	bool	ShouldRender();
	bool	PartialCopyRect(IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, RECT* Rect);

	float dayMult;
	float nightMult;
	bool sunGlareEnabled;
	float rayVisibility;
};