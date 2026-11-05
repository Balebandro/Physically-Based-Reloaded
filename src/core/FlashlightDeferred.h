#pragma once
// UNOFFICIAL 2026-11-05 deferred flashlight ([Shaders.Flashlight.Deferred]; ported from Vegas Shaders, user: "port over the new flashlight
// we did to PB NVR and get rid of the old code regarding flashlight, including flashlight beam"). The Flashlight effect's spot light
// (FlashlightEffect: its place on the weapon or the camera, cone, reach, colour, shadow map) lights the world's surfaces in ONE full-screen
// pass (Shaders/FlashlightDeferred.hlsl) right after the main list's G-buffer is resolved (core/GBuffer.h; Render.cpp MainListHook): each
// pixel's own colour, material and normal through the object shaders' direct light, the cone, the falloff and the light's shadow map,
// added as the difference it makes. The flashlight's only light: without the G-buffer, or if the pass did not load, it lights nothing.
#include "GBuffer.h"
namespace FlashlightDeferred {
	inline ShaderRecordPixel* Pass = nullptr;
	inline bool PassFailed = false;
	inline IDirect3DTexture9* CopyTex = nullptr;
	inline IDirect3DSurface9* Copy = nullptr;
	inline D3DSURFACE_DESC CopyMade = {};

	// Set up to draw: the effect on, the G-buffer compiled in, the pass not failed.
	inline bool Usable() {
		const FlashlightEffect* f = TheShaderManager->Effects.Flashlight;
		return f && f->Enabled && GBuffer::Compiled() && !PassFailed;
	}
	// The G-buffer's reader (Render.cpp MainListHook): while the light is on.
	inline bool Wanted() { return Usable() && TheShaderManager->Effects.Flashlight->spotLightActive; }

	inline bool EnsurePass() {
		if (Pass || PassFailed) return Pass != nullptr;
		ShaderTemplate tmpl = {};
		tmpl.Name = "FlashlightDeferred";
		Pass = (ShaderRecordPixel*)ShaderRecord::LoadShader("FlashlightDeferred.pso", NULL, tmpl);
		if (Pass) Logger::Log("UNOFFICIAL FlashlightDeferred: the flashlight's light pass loaded");
		else { PassFailed = true; Logger::Log("[ERROR] UNOFFICIAL FlashlightDeferred: the light pass (Shaders\\FlashlightDeferred.hlsl) did not load: the flashlight lights nothing from now on"); }
		return Pass != nullptr;
	}

	// The flashlight's shadow map when it was drawn this frame (ShadowManager::RenderShadowMaps, Deferred.Shadows); nullptr otherwise.
	inline IDirect3DTexture9* ShadowMap() {
		const FlashlightEffect* f = TheShaderManager->Effects.Flashlight;
		ShadowsExteriorEffect* shadows = TheShaderManager->Effects.ShadowsExteriors;
		IDirect3DTexture9* map = shadows ? shadows->Textures.ShadowSpotlightTexture[0] : nullptr;
		return f && f->SpotLight && f->Deferred.Shadows && f->SpotLight->CastShadows && map ? map : nullptr;
	}

	// The light as the grass takes it (2026-11-05, Grass.cpp UpdateLights; the G-buffer holds no grass), as Apply sends it to the pass:
	// [0] xyz the light, camera-relative, w its reach; [1] xyz the beam's axis, w cos of the cone's outer edge; [2] rgb the colour (linear
	// under linear lighting, times Dimmer), w cos of the full-strength edge. False while the light is off.
	inline bool LightParams(D3DXVECTOR4 out[3]) {
		const FlashlightEffect* f = TheShaderManager->Effects.Flashlight;
		if (!Usable() || !f->spotLightActive || !f->SpotLight) return false;
		const NiSpotLight& light = *f->SpotLight;
		const float reach = light.Spec.r;
		if (!(reach > 1.0f)) return false;
		const D3DXVECTOR4& cam = TheRenderManager->CameraPosition;
		const NiPoint3& lp = light.m_worldTransform.pos;
		D3DXVECTOR3 axis(light.m_worldTransform.rot.data[0][0], light.m_worldTransform.rot.data[1][0], light.m_worldTransform.rot.data[2][0]);
		D3DXVec3Normalize(&axis, &axis);
		const float outer = D3DXToRadian((std::min)((std::max)(light.OuterSpotAngle, 1.0f), 89.0f));
		const NiColor& c = f->Settings.Color;
		const float peak = (std::max)((std::max)(c.r, c.g), (std::max)(c.b, 1.0e-4f));
		const auto pbrExtra = TheShaderManager->ConstantsTable.find("TESR_PBRExtraData");
		const bool linear = pbrExtra != TheShaderManager->ConstantsTable.end() && pbrExtra->second && pbrExtra->second->w > 0.0f;
		const float lightGamma = linear ? 2.0f : 1.0f;
		const float intensity = (std::max)(f->Settings.Dimmer, 0.0f);
		out[0] = D3DXVECTOR4(lp.x - cam.x, lp.y - cam.y, lp.z - cam.z, reach);
		out[1] = D3DXVECTOR4(axis.x, axis.y, axis.z, cosf(outer));
		out[2] = D3DXVECTOR4(powf(c.r / peak, lightGamma) * intensity, powf(c.g / peak, lightGamma) * intensity, powf(c.b / peak, lightGamma) * intensity, cosf(outer * 0.5f));
		return true;
	}

	// The pass: after GBuffer::EndSpan (G-buffer unbound and resolved), the scene target and its depth bound.
	inline void Apply(IDirect3DDevice9* d) {
		FlashlightEffect* f = TheShaderManager->Effects.Flashlight;
		if (!Usable() || !f->spotLightActive || !f->SpotLight || !GBuffer::Drawn || !GBuffer::Texture[2] || !EnsurePass()) return;
		const NiSpotLight& light = *f->SpotLight;
		const float reach = light.Spec.r;
		if (!(reach > 1.0f)) return;
		IDirect3DSurface9* target = nullptr;
		d->GetRenderTarget(0, &target);
		if (!target) return;
		D3DSURFACE_DESC t = {};
		target->GetDesc(&t);
		// the frame's copy, for enc(dec(v) + L) - v (and the debug views, written over the frame)
		if (!CopyTex || CopyMade.Width != t.Width || CopyMade.Height != t.Height || CopyMade.Format != t.Format) {
			if (Copy) { Copy->Release(); Copy = nullptr; }
			if (CopyTex) { CopyTex->Release(); CopyTex = nullptr; }
			if (FAILED(d->CreateTexture(t.Width, t.Height, 1, D3DUSAGE_RENDERTARGET, t.Format, D3DPOOL_DEFAULT, &CopyTex, NULL)) || FAILED(CopyTex->GetSurfaceLevel(0, &Copy))) {
				if (Copy) { Copy->Release(); Copy = nullptr; }
				if (CopyTex) { CopyTex->Release(); CopyTex = nullptr; }
				target->Release(); return;
			}
			CopyMade = t;
		}
		if (FAILED(d->StretchRect(target, NULL, Copy, NULL, D3DTEXF_NONE))) { target->Release(); return; }
		const int debugView = f->Deferred.DebugView;

		D3DVIEWPORT9 vp = {}; d->GetViewport(&vp);
		IDirect3DSurface9* rt[4] = {};
		for (DWORD i = 1; i < 4; i++) if (SUCCEEDED(d->GetRenderTarget(i, &rt[i])) && rt[i]) d->SetRenderTarget(i, nullptr);
		IDirect3DVertexShader9* vs = nullptr; IDirect3DPixelShader9* ps = nullptr; IDirect3DVertexDeclaration9* decl = nullptr;
		IDirect3DVertexBuffer9* vb = nullptr; UINT vbOffset = 0, vbStride = 0; DWORD fvf = 0;
		d->GetVertexShader(&vs); d->GetPixelShader(&ps); d->GetVertexDeclaration(&decl); d->GetFVF(&fvf); d->GetStreamSource(0, &vb, &vbOffset, &vbStride);
		static const DWORD kStages[] = { 0, 1, 4, 5, 6 };
		const int kStageCount = sizeof(kStages) / sizeof(kStages[0]);
		IDirect3DBaseTexture9* tex[kStageCount] = {};
		for (int s = 0; s < kStageCount; s++) d->GetTexture(kStages[s], &tex[s]);
		// every constant the pass sets, saved and put back
		struct Range { UINT reg, count; float v[16][4]; } saved[] = { { 0, 15 }, { 148, 5 } };
		for (Range& r : saved) d->GetPixelShaderConstantF(r.reg, &r.v[0][0], r.count);
		// depth-tested (not written) at each pixel's G-buffer surface, the shader's own depth: what was drawn over that surface without
		// writing the G-buffer (hair) is not lit as the surface behind it. The game's depth runs either way (reversed while it clears to 0).
		const DWORD zFunc = (1.0 - NiDX9Renderer::GetSingleton()->m_fZClear) ? D3DCMP_GREATEREQUAL : D3DCMP_LESSEQUAL;
		static const D3DRENDERSTATETYPE kRS[] = { D3DRS_ZENABLE, D3DRS_ZWRITEENABLE, D3DRS_ZFUNC, D3DRS_ALPHATESTENABLE, D3DRS_CULLMODE, D3DRS_STENCILENABLE,
			D3DRS_SCISSORTESTENABLE, D3DRS_SRGBWRITEENABLE, D3DRS_COLORWRITEENABLE, D3DRS_ALPHABLENDENABLE, D3DRS_SRCBLEND, D3DRS_DESTBLEND,
			D3DRS_BLENDOP, D3DRS_SEPARATEALPHABLENDENABLE, D3DRS_FOGENABLE, D3DRS_CLIPPLANEENABLE };
		const bool add = !debugView;	// the difference the light makes, added (each MSAA sample keeps its own value); the debug views write over
		const DWORD want[] = { D3DZB_TRUE, FALSE, zFunc, FALSE, D3DCULL_NONE, FALSE, FALSE, FALSE, 0x7, add ? (DWORD)TRUE : (DWORD)FALSE, D3DBLEND_ONE, D3DBLEND_ONE,
			D3DBLENDOP_ADD, FALSE, FALSE, 0 };
		static_assert(sizeof(kRS) / sizeof(kRS[0]) == sizeof(want) / sizeof(want[0]), "one value per state");
		DWORD savedRS[sizeof(kRS) / sizeof(kRS[0])];
		for (unsigned i = 0; i < sizeof(kRS) / sizeof(kRS[0]); i++) { if (FAILED(d->GetRenderState(kRS[i], &savedRS[i]))) savedRS[i] = want[i]; if (savedRS[i] != want[i]) d->SetRenderState(kRS[i], want[i]); }
		static const D3DSAMPLERSTATETYPE kSS[] = { D3DSAMP_MINFILTER, D3DSAMP_MAGFILTER, D3DSAMP_MIPFILTER, D3DSAMP_ADDRESSU, D3DSAMP_ADDRESSV, D3DSAMP_SRGBTEXTURE };
		DWORD savedSS[kStageCount][sizeof(kSS) / sizeof(kSS[0])];
		const DWORD wantS[] = { D3DTEXF_POINT, D3DTEXF_POINT, D3DTEXF_NONE, D3DTADDRESS_CLAMP, D3DTADDRESS_CLAMP, FALSE };
		for (int s = 0; s < kStageCount; s++)
			for (unsigned i = 0; i < sizeof(kSS) / sizeof(kSS[0]); i++) { d->GetSamplerState(kStages[s], kSS[i], &savedSS[s][i]); if (savedSS[s][i] != wantS[i]) d->SetSamplerState(kStages[s], kSS[i], wantS[i]); }

		// Object.hlsl's frame globals in their own registers; MaterialMap 0 (no split-sum table), ObjectMaterial.y 1 (the highlight on)
		static const struct { const char* name; UINT reg; } kGlobals[] = { { "TESR_PBRData", 148 }, { "TESR_PBRExtraData", 149 }, { "TESR_PBRSpecularData", 151 } };
		for (const auto& g : kGlobals) {
			auto found = TheShaderManager->ConstantsTable.find(g.name);
			if (found != TheShaderManager->ConstantsTable.end() && found->second) d->SetPixelShaderConstantF(g.reg, (const float*)found->second, 1);
		}
		const float objectMaterial[4] = { 0.0f, 1.0f, 0.0f, 0.0f }, materialMap[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
		d->SetPixelShaderConstantF(150, objectMaterial, 1);
		d->SetPixelShaderConstantF(152, materialMap, 1);

		// the light, camera-relative: its axis, the cone (outer edge, full strength from half its angle in), the colour (linear, times Dimmer)
		const D3DXVECTOR4& cam = TheRenderManager->CameraPosition;
		const NiPoint3& lp = light.m_worldTransform.pos;
		D3DXVECTOR3 axis(light.m_worldTransform.rot.data[0][0], light.m_worldTransform.rot.data[1][0], light.m_worldTransform.rot.data[2][0]);
		D3DXVec3Normalize(&axis, &axis);
		const float outer = D3DXToRadian((std::min)((std::max)(light.OuterSpotAngle, 1.0f), 89.0f));
		const NiColor& c = f->Settings.Color;
		const float peak = (std::max)((std::max)(c.r, c.g), (std::max)(c.b, 1.0e-4f));
		const float gamma = 2.0f;	// the game's gamma as PB's lighting decodes it (Includes/PBR.hlsl lightingGamma)
		const auto pbrExtra = TheShaderManager->ConstantsTable.find("TESR_PBRExtraData");
		const bool linear = pbrExtra != TheShaderManager->ConstantsTable.end() && pbrExtra->second && pbrExtra->second->w > 0.0f;
		const float lightGamma = linear ? gamma : 1.0f;
		const float intensity = (std::max)(f->Settings.Dimmer, 0.0f);
		// the shadow map: drawn this frame by ShadowManager
		IDirect3DTexture9* map = ShadowMap();
		const bool shadowed = map != nullptr;
		D3DSURFACE_DESC mapDesc = {};
		if (shadowed) map->GetLevelDesc(0, &mapDesc);
		const D3DXMATRIX& iv = TheRenderManager->InvViewMatrix;
		const float tanX = fabsf(TheRenderManager->InvProjMatrix._11), tanY = fabsf(TheRenderManager->InvProjMatrix._22);
		const D3DXMATRIX& proj = NiDX9Renderer::GetSingleton()->projMatrix;
		const float own[11][4] = {
			{ proj._33, proj._43, 0.01f, 2.0f },	// FL_Depth: the depth of a view z, and the pull toward the camera (1 % and 2 units)
			{ 1.0f / (float)vp.Width, 1.0f / (float)vp.Height, (float)vp.X, (float)vp.Y },
			{ iv._11, iv._12, iv._13, tanX },
			{ iv._21, iv._22, iv._23, tanY },
			{ iv._31, iv._32, iv._33, 0.0f },
			{ lp.x - cam.x, lp.y - cam.y, lp.z - cam.z, reach },
			{ axis.x, axis.y, axis.z, cosf(outer) },
			{ powf(c.r / peak, lightGamma) * intensity, powf(c.g / peak, lightGamma) * intensity, powf(c.b / peak, lightGamma) * intensity, cosf(outer * 0.5f) },
			{ linear ? 1.0f : 0.0f, 0.0f, gamma, 1.0f / gamma },
			{ shadowed ? 1.0f : 0.0f, mapDesc.Width ? 1.0f / (float)mapDesc.Width : 0.0f, f->Deferred.ShadowBias, f->Deferred.ShadowSoftness * (float)mapDesc.Width / 512.0f },
			{ 0.0f, (float)debugView, f->Deferred.Falloff, 0.0f } };
		d->SetPixelShaderConstantF(0, own[0], 11);
		d->SetPixelShaderConstantF(11, (const float*)&TheShaderManager->SpotLightWorldToLightMatrix[0], 4);	// row_major in the pass

		d->SetVertexShader(nullptr);
		d->SetPixelShader(Pass->ShaderHandle);
		d->SetTexture(0, CopyTex);
		d->SetTexture(1, GBuffer::Texture[0]);
		d->SetTexture(4, GBuffer::Texture[1]);
		d->SetTexture(5, GBuffer::Texture[2]);
		d->SetTexture(6, shadowed ? map : nullptr);
		d->SetFVF(D3DFVF_XYZRHW | D3DFVF_TEX1);
		const float x0 = (float)vp.X - 0.5f, y0 = (float)vp.Y - 0.5f, x1 = (float)(vp.X + vp.Width) - 0.5f, y1 = (float)(vp.Y + vp.Height) - 0.5f;
		const float u0 = (float)vp.X / t.Width, v0 = (float)vp.Y / t.Height, u1 = (float)(vp.X + vp.Width) / t.Width, v1 = (float)(vp.Y + vp.Height) / t.Height;
		const float quad[4][6] = { { x0, y0, 0, 1, u0, v0 }, { x1, y0, 0, 1, u1, v0 }, { x0, y1, 0, 1, u0, v1 }, { x1, y1, 0, 1, u1, v1 } };
		d->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]));

		for (int s = 0; s < kStageCount; s++) {
			for (unsigned i = 0; i < sizeof(kSS) / sizeof(kSS[0]); i++) if (savedSS[s][i] != wantS[i]) d->SetSamplerState(kStages[s], kSS[i], savedSS[s][i]);
			d->SetTexture(kStages[s], tex[s]); if (tex[s]) tex[s]->Release();
		}
		for (unsigned i = 0; i < sizeof(kRS) / sizeof(kRS[0]); i++) if (savedRS[i] != want[i]) d->SetRenderState(kRS[i], savedRS[i]);
		for (Range& r : saved) d->SetPixelShaderConstantF(r.reg, &r.v[0][0], r.count);
		for (DWORD i = 1; i < 4; i++) if (rt[i]) { d->SetRenderTarget(i, rt[i]); rt[i]->Release(); }
		d->SetViewport(&vp);
		if (decl) { d->SetVertexDeclaration(decl); decl->Release(); } else d->SetFVF(fvf);
		d->SetStreamSource(0, vb, vbOffset, vbStride); if (vb) vb->Release();
		d->SetVertexShader(vs); if (vs) vs->Release();
		d->SetPixelShader(ps); if (ps) ps->Release();
		target->Release();
		static bool told = false;
		if (!told) { told = true; Logger::Log("UNOFFICIAL FlashlightDeferred: the light pass drew (shadow map %s)", shadowed ? "on" : "off"); }
	}
}
