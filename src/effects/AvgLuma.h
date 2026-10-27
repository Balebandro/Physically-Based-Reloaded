#pragma once

class AvgLumaEffect : public EffectRecord
{
public:
	AvgLumaEffect() : EffectRecord("AvgLuma") {};

	struct AvgLumaStruct {
	};
	AvgLumaStruct	Constants;

	struct AvgLumaTextures {
		IDirect3DTexture9* AvgLumaTexture;
		IDirect3DSurface9* AvgLumaSurface;
		// Last frame's result, copied before the pass: the shader reads this one and writes AvgLumaTexture (reading the
		// texture it renders to is undefined, and under DXVK it read stale values now and then: exposure flickered).
		IDirect3DTexture9* AvgLumaPrevTexture;
		IDirect3DSurface9* AvgLumaPrevSurface;
	};
	AvgLumaTextures	Textures;

	void	UpdateConstants() {};
	void	RegisterTextures();
};