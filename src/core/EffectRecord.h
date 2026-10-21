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
	void					RebindSlotTextures();
	float					renderTime;
	float					constantUpdateTime;

	ID3DXEffect* Effect;
	const char* Name;
};
