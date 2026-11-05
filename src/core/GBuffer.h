#pragma once

// UNOFFICIAL 2026-11-05 G-buffer for the deferred flashlight (core/FlashlightDeferred.h; ported from Vegas Shaders' CapturedNormals /
// MaterialBuffer / AlbedoBuffer, user: "port over the new flashlight we did to PB NVR"). While the world's main opaque list draws (the
// game's RenderBatches(1, 0x25B) call, Render.cpp MainListHook), three screen-sized fp16 targets are bound as render targets 1-3, cleared
// to "nothing" first; NVR's lit templates (ObjectTemplate, ParallaxTemplate, TerrainTemplate, compiled with GBUFFER_ON) write
// COLOR1 = the colour, COLOR2 = the material, COLOR3 = the normal and camera distance (Shaders/Includes/GBuffer.hlsl); the skin template
// writes COLOR3 only (its COLOR1 / COLOR2 are the skin blur's), its colour is copied from the skin blur's albedo target after the list.
// A draw hook keeps everything else out: the targets are written only by those templates drawn opaque (or with the land's SRCALPHA /
// INVSRCALPHA fade) into the scene target; any other draw with ours bound has their write masks off, a draw into another target and
// any Clear has them unbound (MRT targets must match in size; Clear clears every bound target). After the list the multisampled copies
// (the game's MSAA) are resolved. Compiled in only with the flashlight on at startup ([Shaders.Flashlight.Status] Enabled).
#include <d3d9.h>
#include <unordered_set>
#include <string>

namespace GBuffer {
	inline bool Checked = false, CompiledOn = false;
	inline bool Hooked = false, Failed = false, InSpan = false, Drawn = false, SkinDrawn = false;
	inline IDirect3DSurface9* SpanTarget = nullptr;	// the scene target the list began with (a key only)
	// [0] albedo (stage 1), [1] material (stage 2), [2] normals (stage 3): what the readers sample, and with the game's MSAA what the draws write
	inline IDirect3DTexture9* Texture[3] = {};
	inline IDirect3DSurface9* Surface[3] = {};
	inline IDirect3DSurface9* Msaa[3] = {};
	inline bool BoundSlot[3] = {};
	inline DWORD MaskSet[3] = { 0xF, 0xF, 0xF };	// the write mask this hook last set on stage i + 1
	inline D3DSURFACE_DESC Made = {};
	inline std::unordered_set<IDirect3DPixelShader9*> FullWriters, NormalWriters, LandWriters;
	inline IDirect3DPixelShader9* LastPS = nullptr;
	inline int LastKind = 0;	// 0 none, 1 full writer, 2 normal only (skin)
	inline IDirect3DPixelShader9* SkinFillPS = nullptr;
	inline bool SkinFillFailed = false;
	inline UInt32 Frames = 0, Writes = 0, LandWrites = 0, Masked = 0, Unbinds = 0, Busy = 0;

	// At startup, once: the templates compile the outputs in (GBUFFER_ON) while the flashlight is on.
	inline bool Compiled() {
		if (!Checked) { Checked = true; CompiledOn = TheSettingManager->GetSettingI("Shaders.Flashlight.Status", "Enabled") != 0; }
		return CompiledOn;
	}
	// ShaderRecord::LoadShader: a template pixel shader compiled with the outputs (its preprocessed source names them).
	inline void NoteShader(IDirect3DPixelShader9* handle, const char* source, size_t size, bool land) {
		if (!handle || !source || !Compiled()) return;
		const std::string text(source, size);
		if (text.find("gbAlbedo") != std::string::npos) { FullWriters.insert(handle); if (land) LandWriters.insert(handle); }
		else if (text.find("gbNormal") != std::string::npos) NormalWriters.insert(handle);
	}

	inline IDirect3DSurface9* DrawSurface(int i) { return Msaa[i] ? Msaa[i] : Surface[i]; }

	inline void Release() {
		for (int i = 0; i < 3; i++) {
			if (Msaa[i]) { Msaa[i]->Release(); Msaa[i] = nullptr; }
			if (Surface[i]) { Surface[i]->Release(); Surface[i] = nullptr; }
			if (Texture[i]) { Texture[i]->Release(); Texture[i] = nullptr; }
		}
		Made = {};
	}

	inline bool Ensure(IDirect3DDevice9* d, const D3DSURFACE_DESC& t) {
		if (Texture[0] && Made.Width == t.Width && Made.Height == t.Height && Made.MultiSampleType == t.MultiSampleType && Made.MultiSampleQuality == t.MultiSampleQuality) return true;
		Release();
		bool ok = true;
		for (int i = 0; ok && i < 3; i++) {
			ok = SUCCEEDED(d->CreateTexture(t.Width, t.Height, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A16B16G16R16F, D3DPOOL_DEFAULT, &Texture[i], NULL)) &&
				SUCCEEDED(Texture[i]->GetSurfaceLevel(0, &Surface[i]));
			// MRT targets must share the scene's multisampling: a multisampled copy, resolved into the texture after the list.
			if (ok && t.MultiSampleType != D3DMULTISAMPLE_NONE)
				ok = SUCCEEDED(d->CreateRenderTarget(t.Width, t.Height, D3DFMT_A16B16G16R16F, t.MultiSampleType, t.MultiSampleQuality, FALSE, &Msaa[i], NULL));
		}
		if (!ok) {
			Logger::Log("[ERROR] UNOFFICIAL GBuffer: could not make the %ux%u targets (msaa %u): off for the session (the flashlight lights nothing)", t.Width, t.Height, (unsigned)t.MultiSampleType);
			Release();
			Failed = true;
			return false;
		}
		Made = t;
		Logger::Log("UNOFFICIAL GBuffer: targets %ux%u, msaa %u (%u full writer and %u normal-only pixel shaders)", t.Width, t.Height, (unsigned)t.MultiSampleType,
			(unsigned)FullWriters.size(), (unsigned)NormalWriters.size());
		return true;
	}

	inline IDirect3DSurface9* TargetNow(IDirect3DDevice9* d, DWORD i) {
		IDirect3DSurface9* s = nullptr;
		if (SUCCEEDED(d->GetRenderTarget(i, &s)) && s) s->Release();
		return s;
	}
	// Read from the device, not kept: a state block's Apply (BlendDepthFix at the first land draw) puts masks back without telling anyone,
	// and a kept "all" left every land draw after it masked (Vegas Shaders 2026-11-04: the land never reached its G-buffer).
	inline void SetMask(IDirect3DDevice9* d, int i, DWORD v) {
		const D3DRENDERSTATETYPE st = i == 0 ? D3DRS_COLORWRITEENABLE1 : i == 1 ? D3DRS_COLORWRITEENABLE2 : D3DRS_COLORWRITEENABLE3;
		DWORD now = 0xF;
		d->GetRenderState(st, &now);
		if (now != v) d->SetRenderState(st, v);
		MaskSet[i] = v;
	}
	// Ours off every stage that holds them, the write masks back to all (binding a target past 0 leaves the viewport alone in D3D9; it is
	// put back anyway, cheap, and some layers reset it).
	inline void Unbind(IDirect3DDevice9* d) {
		D3DVIEWPORT9 vp; d->GetViewport(&vp);
		bool any = false;
		for (int i = 0; i < 3; i++) {
			if (TargetNow(d, i + 1) == DrawSurface(i)) { d->SetRenderTarget(i + 1, nullptr); any = true; }
			BoundSlot[i] = false;
			SetMask(d, i, 0xF);
		}
		d->SetViewport(&vp);
		if (any) Unbinds++;
	}

	inline void BeforeDraw(IDirect3DDevice9* d) {
		if (!InSpan) return;
		if (TargetNow(d, 0) != SpanTarget) { if (BoundSlot[0] || BoundSlot[1] || BoundSlot[2]) Unbind(d); return; }	// a copy, a mask: never with ours
		IDirect3DPixelShader9* ps = nullptr;
		d->GetPixelShader(&ps);
		if (ps) ps->Release();
		if (ps != LastPS) { LastPS = ps; LastKind = !ps ? 0 : FullWriters.count(ps) ? 1 : NormalWriters.count(ps) ? 2 : 0; }
		bool write = LastKind != 0;
		if (write) {
			DWORD mask = 0xF, blend = FALSE, src = D3DBLEND_ONE, dst = D3DBLEND_ZERO;
			d->GetRenderState(D3DRS_COLORWRITEENABLE, &mask);
			d->GetRenderState(D3DRS_ALPHABLENDENABLE, &blend);
			if (blend) { d->GetRenderState(D3DRS_SRCBLEND, &src); d->GetRenderState(D3DRS_DESTBLEND, &dst); }
			// opaque, or a SRCALPHA / INVSRCALPHA fade (the land over objects)
			write = (mask & 7) && (!blend || (src == D3DBLEND_SRCALPHA && dst == D3DBLEND_INVSRCALPHA));
		}
		for (int i = 0; i < 3; i++) {
			IDirect3DSurface9* now = TargetNow(d, i + 1);
			const bool ours = now && now == DrawSurface(i);
			BoundSlot[i] = ours;
			const bool wants = write && (i == 2 || LastKind == 1);	// the skin (normal only) leaves stages 1-2 to the skin blur
			if (wants && (!now || ours)) {
				if (!now) { D3DVIEWPORT9 vp; d->GetViewport(&vp); d->SetRenderTarget(i + 1, DrawSurface(i)); d->SetViewport(&vp); BoundSlot[i] = true; }
				SetMask(d, i, 0xF);
			}
			else if (ours) SetMask(d, i, 0);
			else {
				if (wants) Busy++;	// the stage is someone else's (the skin blur's targets round skin draws)
				SetMask(d, i, 0xF);	// someone else's target keeps its writes
			}
		}
		if (write) { Writes++; Drawn = true; if (LastKind == 2) SkinDrawn = true; if (LastKind == 1 && LandWriters.count(ps)) LandWrites++; }
		else if (BoundSlot[0] || BoundSlot[1] || BoundSlot[2]) Masked++;
	}

	typedef HRESULT(STDMETHODCALLTYPE* DPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT);
	typedef HRESULT(STDMETHODCALLTYPE* DIPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT);
	typedef HRESULT(STDMETHODCALLTYPE* DPUPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, CONST void*, UINT);
	typedef HRESULT(STDMETHODCALLTYPE* DIPUPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT, UINT, CONST void*, D3DFORMAT, CONST void*, UINT);
	typedef HRESULT(STDMETHODCALLTYPE* ClearFn)(IDirect3DDevice9*, DWORD, CONST D3DRECT*, DWORD, D3DCOLOR, float, DWORD);
	inline DPFn NextDP = nullptr;  inline DIPFn NextDIP = nullptr;  inline DPUPFn NextDPUP = nullptr;  inline DIPUPFn NextDIPUP = nullptr;  inline ClearFn NextClear = nullptr;
	inline HRESULT STDMETHODCALLTYPE DPHook(IDirect3DDevice9* d, D3DPRIMITIVETYPE t, UINT s, UINT pc) { BeforeDraw(d); return NextDP(d, t, s, pc); }
	inline HRESULT STDMETHODCALLTYPE DIPHook(IDirect3DDevice9* d, D3DPRIMITIVETYPE t, INT b, UINT mi, UINT nv, UINT s, UINT pc) { BeforeDraw(d); return NextDIP(d, t, b, mi, nv, s, pc); }
	inline HRESULT STDMETHODCALLTYPE DPUPHook(IDirect3DDevice9* d, D3DPRIMITIVETYPE t, UINT pc, CONST void* v, UINT stride) { BeforeDraw(d); return NextDPUP(d, t, pc, v, stride); }
	inline HRESULT STDMETHODCALLTYPE DIPUPHook(IDirect3DDevice9* d, D3DPRIMITIVETYPE t, UINT mi, UINT nv, UINT pc, CONST void* i, D3DFORMAT f, CONST void* v, UINT stride) {
		BeforeDraw(d); return NextDIPUP(d, t, mi, nv, pc, i, f, v, stride);
	}
	inline HRESULT STDMETHODCALLTYPE ClearHook(IDirect3DDevice9* d, DWORD count, CONST D3DRECT* rects, DWORD flags, D3DCOLOR color, float z, DWORD stencil) {
		if (InSpan && (BoundSlot[0] || BoundSlot[1] || BoundSlot[2])) Unbind(d);	// D3D9's Clear clears every bound target; the next writing draw binds them again
		return NextClear(d, count, rects, flags, color, z, stencil);
	}
	// In the device's table, chained: other hooks (DrawProfiler, the sandstorm's) keep what they find there.
	inline void Hook(IDirect3DDevice9* d) {
		if (Hooked || !d) return;
		void** table = *(void***)d;
		DWORD old = 0;
		if (!VirtualProtect(&table[43], sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) return;
		NextClear = (ClearFn)table[43];  table[43] = (void*)&ClearHook;
		VirtualProtect(&table[43], sizeof(void*), old, &old);
		if (!VirtualProtect(&table[81], 4 * sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) return;
		NextDP = (DPFn)table[81];  table[81] = (void*)&DPHook;
		NextDIP = (DIPFn)table[82];  table[82] = (void*)&DIPHook;
		NextDPUP = (DPUPFn)table[83];  table[83] = (void*)&DPUPHook;
		NextDIPUP = (DIPUPFn)table[84];  table[84] = (void*)&DIPUPHook;
		VirtualProtect(&table[81], 4 * sizeof(void*), old, &old);
		Hooked = true;
		Logger::Log("UNOFFICIAL GBuffer: draw hook on");
	}

	// Render.cpp MainListHook, around the game's RenderBatches(1, 0x25B) call in the world scene's main view. wanted: a reader will use it.
	inline void BeginSpan(IDirect3DDevice9* d, bool wanted) {
		Drawn = SkinDrawn = false;
		if (!wanted || !Compiled() || Failed || InSpan) return;
		IDirect3DSurface9* rt0 = TargetNow(d, 0);
		D3DSURFACE_DESC t = {};
		if (!rt0 || FAILED(rt0->GetDesc(&t)) || !Ensure(d, t)) return;
		Hook(d);
		SpanTarget = rt0;
		for (int i = 0; i < 3; i++) { d->ColorFill(DrawSurface(i), NULL, D3DCOLOR_ARGB(0, 0, 0, 0)); BoundSlot[i] = false; }	// "nothing here"
		DWORD m = 0xF;
		d->GetRenderState(D3DRS_COLORWRITEENABLE1, &m); MaskSet[0] = m;
		d->GetRenderState(D3DRS_COLORWRITEENABLE2, &m); MaskSet[1] = m;
		d->GetRenderState(D3DRS_COLORWRITEENABLE3, &m); MaskSet[2] = m;
		LastPS = nullptr;
		InSpan = true;
	}

	// The skin's colour and material (class 6) from the skin blur's albedo target, where the normals mark skin (a 2).
	inline void SkinFill(IDirect3DDevice9* d);

	inline void EndSpan(IDirect3DDevice9* d) {
		if (!InSpan) return;
		Unbind(d);
		InSpan = false;
		SpanTarget = nullptr;
		for (int i = 0; i < 3; i++) if (Msaa[i]) d->StretchRect(Msaa[i], NULL, Surface[i], NULL, D3DTEXF_NONE);	// the game's MSAA: resolved for the readers
		if (Drawn && SkinDrawn) SkinFill(d);
		if (++Frames >= 600) {
			Logger::Log("UNOFFICIAL GBuffer: per frame %.1f draws wrote it (%.1f land), %.1f masked, %.1f found a stage taken, %.2f unbinds", Writes / (double)Frames, LandWrites / (double)Frames,
				Masked / (double)Frames, Busy / (double)Frames, Unbinds / (double)Frames);
			Frames = Writes = LandWrites = Masked = Busy = Unbinds = 0;
		}
	}

	inline void SkinFill(IDirect3DDevice9* d) {
		SkinScatteringEffect* skin = TheShaderManager->Effects.SkinScattering;
		if (SkinFillFailed || !skin || !skin->AlbedoTexture || !skin->AlbedoTextureSurface) return;
		if (!SkinFillPS) {
			// s0 the normals (a 2: skin), s1 the skin blur's albedo (its colour, gamma); out: COLOR0 albedo, COLOR1 material (class 6, roughness 0.45)
			static const char* kPS =
				"sampler2D N : register(s0); sampler2D A : register(s1);"
				"struct O { float4 albedo : COLOR0; float4 material : COLOR1; };"
				"O main(float2 uv : TEXCOORD0) { clip(tex2D(N, uv).a - 1.5); O o; o.albedo = float4(saturate(tex2D(A, uv).rgb), 1.0); o.material = float4(6.0, 1.0, 0.45, 1.0); return o; }";
			ID3DXBuffer* code = nullptr; ID3DXBuffer* errors = nullptr;
			if (FAILED(D3DXCompileShader(kPS, (UINT)strlen(kPS), NULL, NULL, "main", "ps_3_0", 0, &code, &errors, NULL)) || !code ||
				FAILED(d->CreatePixelShader((const DWORD*)code->GetBufferPointer(), &SkinFillPS))) {
				Logger::Log("[ERROR] UNOFFICIAL GBuffer: the skin fill's shader failed (%s): skin stays out of the flashlight's light pass", errors ? (const char*)errors->GetBufferPointer() : "?");
				SkinFillFailed = true;
			}
			if (errors) errors->Release();
			if (code) code->Release();
			if (SkinFillFailed) return;
		}
		if (skin->AlbedoMSAASurface) d->StretchRect(skin->AlbedoMSAASurface, NULL, skin->AlbedoTextureSurface, NULL, D3DTEXF_NONE);
		IDirect3DStateBlock9* state = nullptr;
		if (FAILED(d->CreateStateBlock(D3DSBT_ALL, &state)) || !state) return;
		IDirect3DSurface9* rt[4] = {}; IDirect3DSurface9* depth = nullptr;
		for (DWORD i = 0; i < 4; i++) d->GetRenderTarget(i, &rt[i]);
		d->GetDepthStencilSurface(&depth);
		D3DVIEWPORT9 vp; d->GetViewport(&vp);
		d->SetRenderTarget(0, Surface[0]);
		d->SetRenderTarget(1, Surface[1]);
		d->SetRenderTarget(2, nullptr);
		d->SetRenderTarget(3, nullptr);
		d->SetDepthStencilSurface(nullptr);
		static const D3DRENDERSTATETYPE kRS[] = { D3DRS_ZENABLE, D3DRS_ZWRITEENABLE, D3DRS_ALPHATESTENABLE, D3DRS_ALPHABLENDENABLE, D3DRS_CULLMODE, D3DRS_STENCILENABLE,
			D3DRS_SCISSORTESTENABLE, D3DRS_SRGBWRITEENABLE, D3DRS_FOGENABLE, D3DRS_CLIPPLANEENABLE };
		for (const D3DRENDERSTATETYPE s : kRS) d->SetRenderState(s, s == D3DRS_CULLMODE ? D3DCULL_NONE : FALSE);
		d->SetRenderState(D3DRS_COLORWRITEENABLE, 0xF);
		d->SetRenderState(D3DRS_COLORWRITEENABLE1, 0xF);
		const D3DVIEWPORT9 full = { 0, 0, Made.Width, Made.Height, 0.0f, 1.0f };
		d->SetViewport(&full);
		d->SetVertexShader(nullptr);
		d->SetPixelShader(SkinFillPS);
		d->SetTexture(0, Texture[2]);
		d->SetTexture(1, skin->AlbedoTexture);
		for (DWORD s = 0; s < 2; s++) {
			d->SetSamplerState(s, D3DSAMP_MINFILTER, D3DTEXF_POINT); d->SetSamplerState(s, D3DSAMP_MAGFILTER, D3DTEXF_POINT); d->SetSamplerState(s, D3DSAMP_MIPFILTER, D3DTEXF_NONE);
			d->SetSamplerState(s, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP); d->SetSamplerState(s, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP); d->SetSamplerState(s, D3DSAMP_SRGBTEXTURE, FALSE);
		}
		d->SetFVF(D3DFVF_XYZRHW | D3DFVF_TEX1);
		const float x1 = (float)Made.Width - 0.5f, y1 = (float)Made.Height - 0.5f;
		const float quad[4][6] = { { -0.5f, -0.5f, 0, 1, 0, 0 }, { x1, -0.5f, 0, 1, 1, 0 }, { -0.5f, y1, 0, 1, 0, 1 }, { x1, y1, 0, 1, 1, 1 } };
		d->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]));
		state->Apply();
		state->Release();
		for (DWORD i = 0; i < 4; i++) { d->SetRenderTarget(i, rt[i]); if (rt[i]) rt[i]->Release(); }
		d->SetDepthStencilSurface(depth); if (depth) depth->Release();
		d->SetViewport(&vp);
	}
}
