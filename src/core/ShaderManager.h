#pragma once
#define FrameFVF D3DFVF_XYZ | D3DFVF_TEX1

#include "../Effects/Animator.h"
#include "ShaderRecord.h"
#include "EffectRecord.h"
#include "ShaderCollection.h"
#include "../Effects/Effects.h"

struct ShaderConstants {
	
	struct OcclusionMapStruct {
		D3DXMATRIX		OcclusionWorldViewProj;
	};

	D3DXMATRIXA16			ShadowWorld;
	D3DXVECTOR4				ReciprocalResolution;
	D3DXVECTOR4				SunDir;
	D3DXVECTOR4				SunPosition;
	D3DXVECTOR4				SunTiming;
	D3DXVECTOR4				SunAmount;
	D3DXVECTOR4				ViewSpaceLightDir;
	D3DXVECTOR4				ScreenSpaceLightDir;
	D3DXVECTOR4				GameTime;
	D3DXVECTOR4				FrameTime;
	TESWeather*				pWeather;
	float					sunGlare;
	float					windSpeed;
	D3DXVECTOR4				fogColor;
	D3DXVECTOR4				horizonColor;
	D3DXVECTOR4				skyLowColor;
	float					skyObjectID;
	D3DXVECTOR4				sunDiskColor;
	D3DXVECTOR4				sunColor;
	D3DXVECTOR4				sunAmbient;
	D3DXVECTOR4				skyColor;
	D3DXVECTOR4				fogData;
	D3DXVECTOR4				fogDistance;
	float					fogStart;
	float					fogEnd;
	float					fogPower;
	OcclusionMapStruct		OcclusionMap;
};


typedef std::map<std::string, EffectRecord**> EffectsList;
typedef std::map<std::string, ShaderCollection**> ShaderList;
typedef std::map<std::string, D3DXVECTOR4> CustomConstants;

struct		FrameVS { float x, y, z, u, v; };

// [Main.Main.Performance] FrameChain, ported from NVR UNOFFICIAL Boutique. The effects drawn on the game's frame
// (RenderEffectsPreTonemapping, RenderEffects) used to copy the whole frame into TESR_RenderedBuffer after every pass.
// With the chain, two buffers take turns: a pass reads the one holding the frame (published as RenderedTexture /
// RenderedSurface, so TESR_RenderedBuffer is always the frame) and draws into the other, which then holds it. With
// ChainUsesGameTexture the game's own target is one of the two. End puts the frame back in the game's target.
// Code that draws on the game's target itself (TAA, SMAA) calls Sync first.
class FrameChain {
public:
	bool					Begin(IDirect3DSurface9* gameTarget);
	void					End();
	bool					IsActive() const { return Active; }
	bool					Owns(IDirect3DSurface9* renderTarget, IDirect3DSurface9* renderedSurface) const;
	IDirect3DSurface9*		Output() const { return Surf[Current ^ 1]; }
	void					Commit();
	void					Sync();		// the game's target and RenderedSurface both hold the frame, for code that draws on the target

private:
	struct Pair {
		D3DFORMAT			Format = D3DFMT_UNKNOWN;
		UINT				Width = 0, Height = 0;
		IDirect3DTexture9*	Texture[2] = {};
		IDirect3DSurface9*	Surface[2] = {};
	};
	bool					EnsureTexture(Pair& pair, int slot);
	void					Publish();

	Pair					Pairs[2];	// one per target format and size (before and after tonemapping)
	IDirect3DTexture9*		Tex[2] = {};
	IDirect3DSurface9*		Surf[2] = {};
	IDirect3DTexture9*		GameTexture = nullptr;
	int						Current = 0;
	bool					Active = false;
	IDirect3DSurface9*		GameTarget = nullptr;
	IDirect3DTexture9*		SavedTexture = nullptr;
	IDirect3DSurface9*		SavedSurface = nullptr;
};

__declspec(align(16)) class ShaderManager : public ShaderManagerBase { // Never disposed
public:
	static void Initialize();

	void* operator new(size_t i) { return _mm_malloc(i, 16); }

	template <typename T> void RegisterEffect(T** Pointer);
	template <typename T> void RegisterShaderCollection(T** Pointer);
	EffectRecord*			GetEffectByName(const char* Name);
	ShaderCollection*		GetShaderCollectionByName(const char* Name);
	void					ClearShaderSamplers(const char* TextureName, size_t Length);
	void					RegisterConstant(const char* Name, D3DXVECTOR4* FloatValue);
	void					CreateFrameVertex(UInt32 Width, UInt32 Height, IDirect3DVertexBuffer9** FrameVertex);
	void					InitializeConstants();
	void					UpdateConstants();
	void					GetNearbyLights(ShadowSceneLight* ShadowLightsList[], NiPointLight* LightsList[], NiSpotLight* SpotLightList[]);
	bool					LoadShader(NiD3DVertexShader* VertexShader);
	bool					LoadShader(NiD3DPixelShader* PixelShader);
	void					ReloadEffects();
	ShaderCollection*		GetShaderCollection(const char* Name);
	float					GetTransitionValue(float Day, float Night, float Interior);
	bool					ShouldRenderShadowMaps();
	void					RenderEffects(IDirect3DSurface9* RenderTarget);
	void					RenderEffectsPreTonemapping(IDirect3DSurface9* RenderTarget);
	void					RenderEffectToRT(IDirect3DSurface9* RenderTarget, EffectRecord* Effect, bool clearRenderTarget, UINT techniqueIndex = 0);
	void					SwitchShaderStatus(const char* Name);
	void					SetCustomConstant(const char* Name, D3DXVECTOR4 Value);
		
	struct	EffectsStruct {
		AmbientOcclusionEffect*	AmbientOcclusion;
		SkinScatteringEffect*	SkinScattering;
		DynamicCubemapsEffect*	DynamicCubemaps;
		AvgLumaEffect*			AvgLuma;
		BloomEffect*			Bloom;
		BloomLegacyEffect*		BloomLegacy;
		ColoringEffect*			Coloring;
		LUTEffect*				LUT;
		CinemaEffect*			Cinema;
		ExposureEffect*			Exposure;
		FlashlightEffect*		Flashlight;
		FlashlightBeamEffect*	FlashlightBeam;
		CombineDepthEffect*		CombineDepth;
		DepthOfFieldEffect*		DepthOfField;
		DebugEffect*			Debug;
		GodRaysEffect*			GodRays;
		ImageAdjustEffect*		ImageAdjust;
		LensEffect*				Lens;
		LowHFEffect*			LowHF;
		MotionBlurEffect*		MotionBlur;
		NormalsEffect*			Normals;
		RainEffect*				Rain;
		SharpeningEffect*		Sharpening;
		HeatHazeEffect*			HeatHaze;
		SandstormEffect*		Sandstorm;
		WetnessReflectionsEffect*	WetnessReflections;
		SnowEffect*				Snow;
		SnowAccumulationEffect*	SnowAccumulation;
		ShadowsExteriorEffect*	ShadowsExteriors;
		ShadowsInteriorsEffect*	ShadowsInteriors;
		PointShadowsEffect*		PointShadows;
		PointShadows2Effect*	PointShadows2;
		SunShadowsEffect*		SunShadows;
		UnderwaterEffect*		Underwater;
		VolumetricLightEffect*	VolumetricLight;
		VolumetricFogEffect*	VolumetricFog;
		WaterLensEffect*		WaterLens;
		HudRaindropsEffect*		HudRaindrops;
		DitherBusterEffect*		DitherBuster;
		SMAAEffect*				SMAA;
		TAAEffect*				TAA;
	};

	struct ShadersStruct{
		WaterShaders*			Water;
		TonemappingShaders*		Tonemapping;
		POMShaders*				POM;
		PBRShaders*				PBR;
		SkyShaders*				Sky;
		SkinShaders*			Skin;
		GrassShaders*			Grass;
		TerrainShaders*			Terrain;
		WetnessEffectsShaders*	Wetness;
	};

	struct GameStateStruct {
		float					isDayTime;
		bool					isDayTimeChanged;
		float					transitionCurve;
		float					dayLight;
		bool					isExterior;
		bool					isUnderwater;
		bool					isDialog;
		bool					isPersuasion;
		bool					isCellChanged;
		bool					VATSIsOn;
		bool					PipBoyIsOn;
		bool					OverlayIsOn;
		bool					isRainy;
		bool					isSnow;
		bool					isCloudy;
	};

	EffectsStruct			Effects;
	ShadersStruct			Shaders;
	EffectsList				EffectsNames;
	ShaderList				ShaderNames;
	GameStateStruct			GameState;
	ShaderConstants			ShaderConst;
	CustomConstants			CustomConst;
	std::map<std::string, D3DXVECTOR4*>	ConstantsTable;
	IDirect3DVertexBuffer9*	FrameVertex;
	FrameChain				Chain;
	NiD3DVertexShader*		WaterVertexShaders[51];
	NiD3DPixelShader*		WaterPixelShaders[51];
    TESObjectCELL*          PreviousCell;
    bool                    IsMenuSwitch;
    bool                    orthoRequired;
    bool                    avglumaRequired;
	bool					EffectReloadQueued;
	D3DXVECTOR4				SpotLightPosition[SpotLightsMax];
	D3DXVECTOR4				SpotLightColor[SpotLightsMax];
	D3DXVECTOR4				SpotLightDirection[SpotLightsMax];
	D3DXVECTOR4				VolumetricData;		// xyz march light position, w first person strength floor
	D3DXMATRIX				SpotLightWorldToLightMatrix[SpotLightsMax];
	D3DXVECTOR4				LightPosition[TrackedLightsMax];
	D3DXVECTOR4				LightColor[TrackedLightsMax + ShadowCubeMapsMax];
	D3DXVECTOR4				LightAttenuation[TrackedLightsMax];
};

