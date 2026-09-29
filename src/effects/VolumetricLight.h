#pragma once

// CREDIT: VolumetricLight effect / shader by mcstfuerson. Used with permission.
//         Ported to New Vegas Reloaded by Conor.
// See the credit header in src/hlsl/NewVegas/Effects/VolumetricLight.fx.hlsl.

// Ray-marched sun light shaft: camera to visible surface, testing the sun's VSM/EVSM cascade
// shadow atlas at each step. A pixel only lights up where that shadow value varies along the
// ray -- i.e. an actual occluder -- there is no ambient fog/haze term. Marches into its own half
// resolution buffer (mirrors FlashlightBeamEffect's pattern), then upsamples/combines onto the
// scene at full resolution.
class VolumetricLightEffect : public EffectRecord
{
public:
	VolumetricLightEffect() : EffectRecord("VolumetricLight") {
		Textures.VolumetricTexture = nullptr;
		Textures.VolumetricSurface = nullptr;
	};

	struct VolumetricLightSettingsStruct {
		float	Strength;
		float	Anisotropy;
		bool	Dither;
		D3DXVECTOR3	ScatterColor;
		float	AccumDistance;
		float	NightDistance;
		float	ScatterReference;
		float	FogInfluence;
		float	Extinction;
		float	HeightFalloff;
		bool	DitherMotion;
		bool	Temporal;
		float	TemporalWeight;
		float	TemporalClipGamma;
	};
	VolumetricLightSettingsStruct	Settings;

	struct VolumetricLightStruct {
		D3DXVECTOR4	Data1;	// xyz: scatter color tint, w: reference path length / march range
		D3DXVECTOR4	Data2;	// x: march range at night
		D3DXVECTOR4	Data3;	// x: strength, y: extinction, z: fog influence, w: anisotropy
		D3DXVECTOR4	Data4;	// x: scatter reference, y: dither, z: height falloff, w: dither offset this frame (0-1)
		D3DXVECTOR4	Temporal;			// x: history weight, y: history valid (0/1), z: clip gamma
		D3DXVECTOR4	PrevProjection;		// x: last frame's projMatrix._11, y: its _22
		D3DXVECTOR4	CameraDelta;		// xyz: camera position this frame minus last frame's
		D3DXMATRIX	PrevViewTransform;	// last frame's viewMatrix; the shader reads only its rotation
	};
	VolumetricLightStruct	Constants;

	struct VolumetricLightTextures {
		IDirect3DTexture9* VolumetricTexture;
		IDirect3DSurface9* VolumetricSurface;
		IDirect3DTexture9* AccumTexture = nullptr;		// this frame's filtered march
		IDirect3DSurface9* AccumSurface = nullptr;
		IDirect3DTexture9* HistoryTexture = nullptr;	// last frame's, read by the Temporal pass
		IDirect3DSurface9* HistorySurface = nullptr;
	};
	VolumetricLightTextures	Textures;

	void	UpdateConstants();
	void	RegisterConstants();
	void	RegisterTextures();
	void	UpdateSettings();
	bool	ShouldRender();

	void	RenderTemporal(IDirect3DDevice9* Device);

private:
	double	ditherPhase = 0.0;	// golden-ratio sequence position, advanced once per frame while the dither moves

	bool		historyValid = false;
	double		lastTemporalTime = -1.0;	// TheFrameRateManager->Time of the last frame the Temporal pass ran
	D3DXVECTOR4	prevCameraPosition = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);

	bool	TemporalActive();
	void	RememberCamera();
};
