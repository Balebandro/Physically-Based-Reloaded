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
	virtual bool			PartialCopyRect(IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, RECT* Rect) { return false; } // reimplement to copy only Rect after intermediate passes (return true); the last pass always copies the whole target
	virtual bool			SwitchEffect();
	virtual void			Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer);
	// ClearSampler is inherited from ShaderProgram -- game shaders need the same thing.
	void					DisposeEffect();
	bool					LoadEffect();

	bool 					IsLoaded();
	bool					Enabled;
	bool					ReadsSourceBuffer; // false when no shader code samples TESR_SourceBuffer, so Render skips that copy
	float					renderTime;
	float					constantUpdateTime;

	ID3DXEffect* Effect;
	const char* Name;
};
