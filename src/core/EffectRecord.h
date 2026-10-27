#pragma once

class EffectRecord : public ShaderProgram {
public:
	EffectRecord(const char* effectName);
	virtual ~EffectRecord();

	virtual void			SetCT();
	virtual void			CreateCT(ID3DXBuffer* ShaderSource, ID3DXConstantTable* ConstantTable);
	virtual void			UpdateConstants() {};
	virtual void			UpdateSettings() {};
	virtual void			RegisterConstants() {};
	virtual void			RegisterTextures() {};
	virtual bool			ShouldRender() { return true; }; // reimplement in subclasses to disable render under certain conditions
	virtual bool			SwitchEffect();
	virtual void			Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer);
	// ClearSampler is inherited from ShaderProgram -- game shaders need the same thing.
	void					DisposeEffect();
	bool					LoadEffect();
	// Shared with ShaderPrecompile, which must look at exactly the files and defines LoadEffect does.
	static bool				EffectPaths(const char* Name, char* SourcePath, char* PreprocessedPath, char* CompiledPath);
	static void				EffectMacros(D3DXMACRO (&Macros)[3]);

	bool 					IsLoaded();
	bool					Enabled;
	bool					usesSourceBuffer = true;	// reads TESR_SourceBuffer (CreateCT)
	bool					needsPrefill = true;		// has passes that leave pixels untouched (CreateCT)
	// When set, the render target is copied here before every pass, for effects that read what they draw into (they
	// sample this copy instead: reading the target itself is undefined, and blurs read neighbours being overwritten).
	IDirect3DSurface9*		PassCopy = nullptr;
	void					RebindSlotTextures();
	// Handles looked up once per load (from NVR Optimized): a cache goes stale when the effect loads again.
	struct CachedHandle { unsigned Generation = 0; D3DXHANDLE Handle = NULL; };
	unsigned				LoadGeneration = 1;
	D3DXHANDLE				TechniqueHandle(CachedHandle& cache, const char* name);
	D3DXHANDLE				ParameterHandle(CachedHandle& cache, const char* name);
	// Textures an effect sets by stage for its next passes (from NVR Optimized), bound after each pass's own states.
	IDirect3DBaseTexture9*	PassTextures[16] = {};
	void					SetPassTexture(UINT stage, IDirect3DBaseTexture9* texture) { if (stage < 16) PassTextures[stage] = texture; }
	void					BindPassTextures();
	void					ClearPassTextures();
	float					renderTime;
	float					constantUpdateTime;

	ID3DXEffect* Effect;
	const char* Name;
};
