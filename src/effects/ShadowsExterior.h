#pragma once

typedef struct frustum {
	enum PLANE {
		PLANENEAR = 0,
		PLANEFAR = 1,
		PLANELEFT = 2,
		PLANERIGHT = 3,
		PLANETOP = 4,
		PLANEBOTTOM = 5,
	};
	PLANE PLANE;
	D3DXPLANE plane[6];
} frustum;

class ShadowsExteriorEffect : public EffectRecord
{
public:
	ShadowsExteriorEffect() : EffectRecord("ShadowsExteriors") {};

	enum ShadowMapTypeEnum {
		MapNear = 0,
		MapMiddle = 1,
		MapFar = 2,
		MapLod = 3,
		MapOrtho = 4,
	};

	//Constants
	struct ShadowStruct {
		D3DXVECTOR4		SmoothedSunDir;
		D3DXVECTOR4		Data;
		D3DXVECTOR4		FormatData;
		D3DXVECTOR4		ScreenSpaceData;
		D3DXVECTOR4		ContactData;		// x: strength, y: ray length, z: thickness, w: max distance
		D3DXVECTOR4		SunLight;			// rgb: the sun colour the object shaders receive
		D3DXVECTOR4		AmbientLight;		// rgb: the ambient colour the object shaders receive
		D3DXVECTOR4		ContactDebug;		// x: debug view of the contact shadows, 0 off
		D3DXVECTOR4		OrthoData;
		D3DXVECTOR4		ShadowFade;
		D3DXMATRIXA16	ShadowWorld;
		D3DXMATRIX		ShadowViewProj;
		D3DXMATRIX		ShadowSpotlightCameraToLight[SpotLightsMax];
		D3DXVECTOR4		ShadowCubeMapLightPosition;
		D3DXVECTOR4		ShadowLightPosition[ShadowCubeMapsMax];
		D3DXVECTOR4		ShadowMapRadius;
		D3DXVECTOR4		ShadowBlur;
		// Forward sun shadows, runtime side. x: 1 when the forward path is SUPPRESSED.
		//
		// The polarity is deliberate. A constant that fails to reach a shader reads as zero,
		// and zero here means "not suppressed" -- i.e. the current, working behaviour. The
		// opposite polarity would turn a dropped constant into silently missing shadows,
		// which is exactly the failure that made this a compile-time macro in the first place.
		D3DXVECTOR4		ForwardData;
		// [Shaders.ShadowsExteriors.SunSmoothing] CrossFade: the cascades as they were before the sun's last step
		// (camera-relative, moved with the camera) and x: how much of them still shows (Includes/Shadow.hlsl).
		D3DXMATRIX		OldCameraToLight[4];
		D3DXVECTOR4		OldCenter[4];
		D3DXVECTOR4		CrossFade;
	};

	// Settings
	struct FormsStruct {
		bool				AlphaEnabled;
		bool				Activators;
		bool				Actors;
		bool				Apparatus;
		bool				Books;
		bool				Containers;
		bool				Doors;
		bool				Furniture;
		bool				Misc;
		bool				Statics;
		bool				Terrain;
		bool				Trees;
		bool				Lod;
		float				MinRadius;
		float				OrigMinRadius;
	};

	struct ShadowMapSettings {
		D3DXMATRIX				ShadowCameraToLight;
		D3DVIEWPORT9			ShadowMapViewPort;
		frustum					ShadowMapFrustum;
		NiFrustumPlanes			ShadowMapFrustumPlanes;
		D3DXVECTOR4				ShadowMapCascadeCenterRadius;
		D3DXVECTOR3				CameraTranslation;  // Camera translation at the moment the shadow matrix was calculated.
		D3DXVECTOR4				ClearColor;
		FormsStruct				Forms;
		float					ShadowMapResolution;
		float					ShadowMapInverseResolution;
		float					ShadowMapRadius;
		float					ShadowMapNear;
		bool					CustomClearRequired;
		D3DXPLANE				CasterPlanes[4];		// the view's sides, camera-relative, facing in (ShadowManager::CastsIntoView)
		bool					CasterPlanesValid;
	};

	struct ShadowMapStruct {
		D3DFORMAT			Format;
		int					CascadeResolution;
		bool                Prefilter;
		bool				MSAA;
		bool				Mipmaps;
		bool				LimitFrequency;
		int					Anisotropy;
		float				Distance;
		float				CascadeLambda;
		bool				CasterCulling;		// leave out casters whose shadow cannot reach the view
		float				CasterMargin;
		float				CasterDrop;
		bool				Instancing;		// copies of one mesh drawn together (ShadowRenderPass::RenderAccum)
		bool				SkipCoveredCasters;	// leave out of a cascade what only an earlier one shades
		bool				SmoothFilter;		// Mode 3: a 4x4 cubic B-spline filter instead of the 3x3 (TESR_ShadowBlur.z)
	};

	struct OrthoStruct {
		int					Resolution;
		float				Distance;
		bool				LimitFrequency;
	};

	struct ExteriorsStruct {
		bool				Enabled;
		bool				ForwardShadows;
		bool				UsePointShadowsDay;
		bool				UsePointShadowsNight;
		int					Quality;
		float				Darkness;
		float				NightMinDarkness;
	};

	struct InteriorsStruct {
		bool				Enabled;
		bool				TorchesCastShadows;
		FormsStruct			Forms;
		int					LightPoints;
		int					Quality;
		int					ShadowCubeMapSize;
		int					DrawDistance;
		float				Darkness;
		float				LightRadiusMult;
		bool				UseCastShadowFlag;
		bool				PlayerShadowThirdPerson;
		bool				PlayerShadowFirstPerson;
	};

	struct ScreenSpaceStruct {
		bool				Enabled;
		float				BlurRadius;
		float				RenderDistance;
	};

	struct SunSmoothingStruct {
		bool				SmoothSun;
		bool				QuantizeSun;
		float				SmoothingFactor;
		float				YawStepSize;
		float				PitchStepSize;
		float				MaxJumpAngle;
		float				GlideSeconds;	// with QuantizeSun and SmoothSun: each step eased over this long
		bool				CrossFade;		// with forward shadows: a step fades from the old cascades to the new
	};

	// [Shaders.ContactHardening]: sun shadows sharp where a caster touches, softer further off (Mode 3, forward).
	struct ContactHardeningStruct {
		bool				Enabled;
		float				SunSize;
		float				MaxSoftness;
		bool				Smooth;
		bool				AtNight;
	};

	struct SettingsShadowStruct {
		ShadowMapStruct     ShadowMaps;
		OrthoStruct			OrthoMap;
		ScreenSpaceStruct	ScreenSpace;
		ExteriorsStruct		Exteriors;
		InteriorsStruct		Interiors;
		SunSmoothingStruct  SunSmoothing;
		ContactHardeningStruct ContactHardening;
	};
	SettingsShadowStruct	Settings;
	ShadowStruct			Constants;
	ShadowMapSettings		ShadowMaps[5];

	struct ShadowTextures {
		IDirect3DTexture9* ShadowPassTexture;
		IDirect3DSurface9* ShadowPassSurface;
		// TESR_PointShadowCopy: the shadow pass as it was before each pass of PointShadows2 / SunShadows (their PassCopy),
		// which read that instead of the buffer they draw into.
		IDirect3DTexture9* ShadowPassCopyTexture;
		IDirect3DSurface9* ShadowPassCopySurface;
		IDirect3DCubeTexture9* ShadowCubeMapTexture[ShadowCubeMapsMax];
		IDirect3DSurface9* ShadowCubeMapSurface[ShadowCubeMapsMax][6];
		IDirect3DTexture9* ShadowSpotlightTexture[SpotLightsMax];
		IDirect3DSurface9* ShadowSpotlightSurface[SpotLightsMax];
		IDirect3DSurface9* ShadowCubeMapDepthSurface;
	};
	ShadowTextures	Textures;

	// Main shadow atlas, used for cascades.
	IDirect3DTexture9* ShadowAtlasTexture;
	IDirect3DSurface9* ShadowAtlasSurface;
	IDirect3DSurface9* ShadowAtlasSurfaceMSAA;
	IDirect3DSurface9* ShadowAtlasDepthSurface;

	// Ping-pong target for the separable prefilter blur, so that neither pass samples the atlas
	// while the atlas is bound as the render target -- undefined in D3D9, and a read/write
	// feedback loop on Vulkan under DXVK.
	// Initialised here because they are only allocated when Prefilter is on -- unlike the
	// members above, which RegisterTextures always assigns before anything tests them.
	IDirect3DTexture9* ShadowAtlasBlurTexture = nullptr;
	IDirect3DSurface9* ShadowAtlasBlurSurface = nullptr;

	IDirect3DVertexBuffer9* ShadowAtlasVertexBuffer;

	// Ortho shadows for various effects.
	IDirect3DTexture9* ShadowMapOrthoTexture;
	IDirect3DSurface9* ShadowMapOrthoSurface;
	IDirect3DSurface9* ShadowMapOrthoDepthSurface;

	void		clearShadowsBuffer();
	void		UpdateConstants();
	void		UpdateLightColors();
	void		UpdateSettings();
	void		RegisterConstants();
	void		RegisterTextures();
	void		RecreateTextures(bool cascades, bool ortho, bool cubemaps);

	D3DXVECTOR3	CalculateSmoothedSunDir();

	// Set by ShadowManager::RenderShadowMaps when it skipped the sun/moon cascades because the light
	// is below the horizon. The atlas and the camera-relative ShadowCameraToLight transforms are then
	// stale -- see UpdateConstants for why they must not be sampled.
	bool		SunMapsStale = false;

	// Sun step glide and cross-fade (NVR UNOFFICIAL Optimized).
	D3DXVECTOR3	SunGlideFrom = D3DXVECTOR3(0.0f, 0.0f, 1.0f);
	D3DXVECTOR3	SunGlideTo = D3DXVECTOR3(0.0f, 0.0f, 1.0f);
	ULONGLONG	SunGlideStart = 0;
	bool		SunGlideValid = false;
	bool		SunCrossFadeReady = false;
	bool		SunCrossFading = false;
	IDirect3DTexture9* ShadowAtlasOldTexture = nullptr;
	IDirect3DSurface9* ShadowAtlasOldSurface = nullptr;
	D3DXMATRIX	SunFadeMatrix[4];
	D3DXVECTOR4	SunFadeCenter[4];
	D3DXVECTOR3	SunFadeCamera[4];
	bool		StartSunCrossFade();
	void		UpdateSunCrossFade(float oldWeight);

	void		GetCascadeDepths();
	D3DXMATRIX	GetCascadeViewProj(ShadowMapSettings* ShadowMap, D3DXVECTOR3* SunDir);

private:
	bool		texturesInitialized;

	bool		UpdateSettingsFromQuality(int quality);
};
