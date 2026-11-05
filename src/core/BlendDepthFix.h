#pragma once

// UNOFFICIAL 2026-11-05 (from Vegas Shaders' SkyCoverage::FixBlendDepth; user: white blotches at the foot of every bush with terrain
// blending): with the game's MSAA, terrain blending reads one depth per pixel (the nearest sample's), but the land is shown per sample.
// A pixel half twig, half nothing faded the land over the nothing too, and the empty frame showed through. Right after the blend depth
// copy (Terrain.cpp), every pixel the objects cover only in part is set to "nothing there" in the copy: the land fades only where the
// objects cover the whole pixel and stays solid in the mixed ones, as without blending. The objects' share comes from a full-screen quad
// at the far plane drawn against the multisampled depth buffer into a multisampled mask, then resolved. Without MSAA nothing is done.
#include <d3dx9.h>

namespace BlendDepthFix {
	inline IDirect3DSurface9* MaskMS = nullptr;				// the multisampled mask the quad is drawn into
	inline IDirect3DTexture9* ObjectTexture = nullptr;		// the objects' share of each pixel (resolved mask)
	inline IDirect3DSurface9* ObjectSurface = nullptr;
	inline IDirect3DTexture9* Scratch = nullptr;			// a colour target nothing is written to (the depth-only pass)
	inline IDirect3DSurface9* ScratchSurface = nullptr;
	inline IDirect3DPixelShader9* WhitePS = nullptr;
	inline IDirect3DPixelShader9* PartialPS = nullptr;		// keeps only the pixels the objects cover in part (s0: ObjectTexture)
	inline IDirect3DStateBlock9* State = nullptr;
	inline D3DSURFACE_DESC Made = {};
	inline bool Failed = false, Told = false;

	inline void Release() {
		if (MaskMS) { MaskMS->Release(); MaskMS = nullptr; }
		if (ObjectSurface) { ObjectSurface->Release(); ObjectSurface = nullptr; }
		if (ObjectTexture) { ObjectTexture->Release(); ObjectTexture = nullptr; }
		if (ScratchSurface) { ScratchSurface->Release(); ScratchSurface = nullptr; }
		if (Scratch) { Scratch->Release(); Scratch = nullptr; }
	}

	inline IDirect3DPixelShader9* Compile(IDirect3DDevice9* d, const char* source) {
		IDirect3DPixelShader9* shader = nullptr;
		ID3DXBuffer* code = nullptr; ID3DXBuffer* errors = nullptr;
		if (FAILED(D3DXCompileShader(source, (UINT)strlen(source), NULL, NULL, "main", "ps_3_0", 0, &code, &errors, NULL)) || !code ||
			FAILED(d->CreatePixelShader((const DWORD*)code->GetBufferPointer(), &shader))) {
			Logger::Log("UNOFFICIAL BlendDepthFix: shader failed (%s): off for the session", errors ? (const char*)errors->GetBufferPointer() : "?");
			shader = nullptr;
		}
		if (errors) errors->Release();
		if (code) code->Release();
		return shader;
	}

	inline bool Ensure(IDirect3DDevice9* d, const D3DSURFACE_DESC& t) {
		if (Failed) return false;
		if (MaskMS && Made.Width == t.Width && Made.Height == t.Height && Made.MultiSampleType == t.MultiSampleType && Made.MultiSampleQuality == t.MultiSampleQuality) return true;
		Release();
		if (FAILED(d->CreateRenderTarget(t.Width, t.Height, D3DFMT_A8R8G8B8, t.MultiSampleType, t.MultiSampleQuality, FALSE, &MaskMS, NULL)) ||
			FAILED(d->CreateTexture(t.Width, t.Height, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &ObjectTexture, NULL)) ||
			FAILED(ObjectTexture->GetSurfaceLevel(0, &ObjectSurface)) ||
			FAILED(d->CreateTexture(t.Width, t.Height, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &Scratch, NULL)) ||
			FAILED(Scratch->GetSurfaceLevel(0, &ScratchSurface))) {
			Logger::Log("UNOFFICIAL BlendDepthFix: could not make the masks (%ux%u, msaa %u): off for the session", t.Width, t.Height, (unsigned)t.MultiSampleType);
			Release();
			Failed = true;
			return false;
		}
		if (!WhitePS) WhitePS = Compile(d, "float4 main() : COLOR0 { return 1.0; }");
		if (!PartialPS) PartialPS = Compile(d, "sampler2D C : register(s0); float4 main(float2 uv : TEXCOORD0) : COLOR0 { clip(0.999 - tex2D(C, uv).r); return 0.0; }");
		if (!WhitePS || !PartialPS) { Release(); Failed = true; return false; }
		Made = t;
		return true;
	}

	// A full-screen quad at the far plane into the bound target, against the bound depth buffer with zFunc.
	inline void Quad(IDirect3DDevice9* d, const D3DSURFACE_DESC& t, DWORD zFunc, BOOL zWrite, DWORD colourWrite, IDirect3DPixelShader9* ps) {
		static const D3DRENDERSTATETYPE kStates[] = { D3DRS_ZENABLE, D3DRS_ZWRITEENABLE, D3DRS_ZFUNC, D3DRS_STENCILENABLE, D3DRS_ALPHATESTENABLE,
			D3DRS_ALPHABLENDENABLE, D3DRS_CULLMODE, D3DRS_COLORWRITEENABLE, D3DRS_SCISSORTESTENABLE, D3DRS_CLIPPLANEENABLE, D3DRS_FOGENABLE,
			D3DRS_SRGBWRITEENABLE, D3DRS_MULTISAMPLEANTIALIAS, D3DRS_MULTISAMPLEMASK };
		const DWORD want[] = { D3DZB_TRUE, (DWORD)zWrite, zFunc, FALSE, FALSE, FALSE, D3DCULL_NONE, colourWrite, FALSE, 0, FALSE, FALSE, TRUE, 0xFFFFFFFF };
		for (unsigned i = 0; i < sizeof(kStates) / sizeof(kStates[0]); i++) d->SetRenderState(kStates[i], want[i]);
		const D3DVIEWPORT9 full = { 0, 0, t.Width, t.Height, 0.0f, 1.0f };
		d->SetViewport(&full);
		d->SetVertexShader(nullptr);
		d->SetPixelShader(ps);
		d->SetFVF(D3DFVF_XYZRHW | D3DFVF_TEX1);
		const float z = TheRenderManager->IsReversedDepth() ? 0.0f : 1.0f;
		const float x0 = -0.5f, y0 = -0.5f, x1 = (float)t.Width - 0.5f, y1 = (float)t.Height - 0.5f;
		const float quad[4][6] = { { x0, y0, z, 1.0f, 0.0f, 0.0f }, { x1, y0, z, 1.0f, 1.0f, 0.0f }, { x0, y1, z, 1.0f, 0.0f, 1.0f }, { x1, y1, z, 1.0f, 1.0f, 1.0f } };
		d->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]));
	}

	// Right after terrain blending copied the depth drawn so far: the scene's multisampled target and depth are bound.
	inline void Apply(IDirect3DDevice9* d, IDirect3DTexture9* copy) {
		if (Failed || !copy) return;
		IDirect3DSurface9* target = nullptr; IDirect3DSurface9* depth = nullptr; IDirect3DSurface9* copySurface = nullptr;
		IDirect3DSurface9* extra[3] = {};
		D3DSURFACE_DESC t = {}, z = {};
		d->GetRenderTarget(0, &target);
		d->GetDepthStencilSurface(&depth);
		const bool ok = target && depth && SUCCEEDED(target->GetDesc(&t)) && SUCCEEDED(depth->GetDesc(&z)) && t.MultiSampleType != D3DMULTISAMPLE_NONE &&
			z.MultiSampleType == t.MultiSampleType && z.Width >= t.Width && z.Height >= t.Height && SUCCEEDED(copy->GetSurfaceLevel(0, &copySurface)) &&
			copySurface && Ensure(d, t) && (State || SUCCEEDED(d->CreateStateBlock(D3DSBT_ALL, &State)));
		if (ok) {
			State->Capture();
			D3DVIEWPORT9 viewport = {};
			d->GetViewport(&viewport);
			for (DWORD i = 1; i < 4; i++) if (SUCCEEDED(d->GetRenderTarget(i, &extra[i - 1])) && extra[i - 1]) d->SetRenderTarget(i, nullptr);

			// the objects' share: the samples in front of the far plane
			d->SetRenderTarget(0, MaskMS);
			d->Clear(0, NULL, D3DCLEAR_TARGET, 0, 1.0f, 0);
			Quad(d, t, TheRenderManager->IsReversedDepth() ? D3DCMP_LESS : D3DCMP_GREATER, FALSE, 0xF, WhitePS);
			d->StretchRect(MaskMS, NULL, ObjectSurface, NULL, D3DTEXF_NONE);
			// the copy as the depth buffer: every pixel the objects cover in part gets the far plane's depth
			d->SetRenderTarget(0, ScratchSurface);
			d->SetDepthStencilSurface(copySurface);
			d->SetTexture(0, ObjectTexture);
			d->SetSamplerState(0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
			d->SetSamplerState(0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
			d->SetSamplerState(0, D3DSAMP_MIPFILTER, D3DTEXF_NONE);
			d->SetSamplerState(0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP);
			d->SetSamplerState(0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP);
			Quad(d, t, D3DCMP_ALWAYS, TRUE, 0, PartialPS);
			d->SetTexture(0, nullptr);

			d->SetRenderTarget(0, target);
			for (DWORD i = 1; i < 4; i++) if (extra[i - 1]) { d->SetRenderTarget(i, extra[i - 1]); extra[i - 1]->Release(); }
			d->SetDepthStencilSurface(depth);
			d->SetViewport(&viewport);	// (SetRenderTarget resets it)
			State->Apply();
			if (!Told) { Told = true; Logger::Log("UNOFFICIAL BlendDepthFix: on (msaa %u): pixels objects cover in part read as nothing there in the blend depth", (unsigned)t.MultiSampleType); }
		}
		if (copySurface) copySurface->Release();
		if (target) target->Release();
		if (depth) depth->Release();
	}
}
