#pragma once

// 0xB89D80
VirtFuncDetour kSkyShaderConstantsDetour;
void __fastcall SkyShader__UpdateConstants(SkyShader* apThis, void*, const NiPropertyState* apProperties) {
    const SkyShaderProperty* pShaderProp = apProperties->GetShadeProperty<SkyShaderProperty const>();
    uint32_t eSkyObjectType = pShaderProp->eSkyObjectType;
    TheShaderManager->ShaderConst.skyObjectID = eSkyObjectType;

    ThisCall(kSkyShaderConstantsDetour.GetOverwrittenAddr(), apThis, apProperties);

    TheRenderManager->device->SetPixelShaderConstantF(20, (const float*)&TheShaderManager->ShaderConst.skyObjectID, 1);
}

// SkinShader's per-geometry virtuals (vtable 0x10BB980), bracketing every skin draw on both of
// the batch renderer's paths (BSBatchRenderer::RenderPassImmediately_Standard and _Skinned):
// slot 27 PrepareGeometryForRendering (NiD3DShader, 0xE812F0) runs just before the draw, slot 35
// PostGeometry (ShadowLightShader, 0xB7C320) just after. The skin scattering effect binds its
// second render target between the two and nowhere else (src/effects/SkinScattering.h). The
// batch-level SetupPassShaders hook (SetShadersHook) runs once per batch, not per draw.
VirtFuncDetour kSkinPrepareGeometryDetour;
VirtFuncDetour kSkinPostGeometryDetour;

// The engine also draws its own highlight passes on skin geometry (traced on FaceGenFace:
// BSSM_2x_SPECULARDIR_S / _SPECULARPT_S with the object shaders), BSSM_SPECULARDIR (0x154) to
// BSSM_2x_SPECULARPT3_Sb (0x177). NVR's skin shader draws physically based highlights itself, so
// while it is on these are muted (colour writes off for the draw): with them, faces had two sets
// of highlights, and the screen-space scattering blurred the second as if it were diffuse light.
static bool  sSkinHighlightMuted = false;
static DWORD sSkinSavedWriteMask = 0xF;

void* __fastcall SkinShader__PrepareGeometryForRendering(void* apThis, void*, void* apGeometry, void* apPartition, void* apRendererData, void* apState) {
    void* Result = (void*)ThisCall(kSkinPrepareGeometryDetour.GetOverwrittenAddr(), apThis, apGeometry, apPartition, apRendererData, apState);

    NiD3DPass* Pass = *(NiD3DPass**)0x0126F74C;   // NiD3DShader::m_pCurrentPass
    NiD3DPixelShaderEx* PixelShader = Pass ? (NiD3DPixelShaderEx*)Pass->PixelShader : nullptr;
    const UInt16 PassType = *(UInt16*)0x011F91E4;  // BSShaderManager::eCurrentPass

    const bool NVRSkin = TheShaderManager->Shaders.Skin->Enabled && TheSettingManager->SettingsMain.Main.RenderEffects;
    const bool SkinPixelShader = PixelShader && PixelShader->Name && !memcmp(PixelShader->Name, "SKIN", 4);
    // The pass type alone is not trusted to be current: a skin pixel shader is never muted.
    if (NVRSkin && !SkinPixelShader && PassType >= 0x154 && PassType <= 0x177 && !sSkinHighlightMuted) {
        TheRenderManager->device->GetRenderState(D3DRS_COLORWRITEENABLE, &sSkinSavedWriteMask);
        TheRenderManager->device->SetRenderState(D3DRS_COLORWRITEENABLE, 0);
        sSkinHighlightMuted = true;
    }

    // The scattering targets only for NVR's own skin pixel shaders, not the highlight or fog
    // passes the engine also draws with this shader.
    SkinScatteringEffect* Scattering = TheShaderManager->Effects.SkinScattering;
    if (Scattering && SkinPixelShader)
        Scattering->BindForSkinDraw(PixelShader);

    // Develop.DebugMode + the TraceShaders key: what this hook did for every skin draw that frame.
    if (TheSettingManager->SettingsMain.Develop.DebugMode && Global->OnKeyDown(TheSettingManager->SettingsMain.Develop.TraceShaders)) {
        Logger::Log("SkinHook: pass %s (0x%X), pixel shader %s: highlights muted %d, scattering bound %d",
            Pointers::Functions::GetPassDescription(PassType), (UInt32)PassType,
            (PixelShader && PixelShader->Name) ? PixelShader->Name : "(none)",
            sSkinHighlightMuted ? 1 : 0, (Scattering && Scattering->Bound) ? 1 : 0);
    }

    // SkinScreenSpaceScatter (Includes/SkinLighting.hlsl), every skin draw: 1 while the target is
    // bound, so the shader leaves diffusion to the screen-space blur.
    const float ScreenSpace[4] = { (Scattering && Scattering->Bound) ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f };
    TheRenderManager->device->SetPixelShaderConstantF(147, ScreenSpace, 1);
    return Result;
}

void __fastcall SkinShader__PostGeometry(void* apThis, void*, void* apProperties) {
    ThisCall(kSkinPostGeometryDetour.GetOverwrittenAddr(), apThis, apProperties);
    if (TheShaderManager->Effects.SkinScattering) TheShaderManager->Effects.SkinScattering->Unbind();
    if (sSkinHighlightMuted) {
        TheRenderManager->device->SetRenderState(D3DRS_COLORWRITEENABLE, sSkinSavedWriteMask);
        sSkinHighlightMuted = false;
    }
}
