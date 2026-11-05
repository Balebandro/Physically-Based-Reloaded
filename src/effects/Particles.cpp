#include "Particles.h"
#include "../core/ParticleSize.h"	// UNOFFICIAL 2026-11-04 soft particles
#include "../core/BlendDepthFix.h"

void ParticleShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_ParticleData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_ParticleAmbient", &Constants.Ambient);
	TheShaderManager->RegisterConstant("TESR_ParticleSoft", &Constants.Soft);
	Constants.Data = D3DXVECTOR4(0.0f, 1.0f, 0.0f, 0.0f);
	Constants.Ambient = D3DXVECTOR4(1.0f, 1.0f, 1.0f, 1.0f);
	Constants.Soft = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
}

void ParticleShaders::UpdateSettings() {
	Settings.Strength = std::clamp(TheSettingManager->GetSettingF("Shaders.Particles.Main", "Strength"), 0.0f, 1.0f);
	Settings.SunShare = max(TheSettingManager->GetSettingF("Shaders.Particles.Main", "SunShare"), 0.0f);
	Settings.SoftScale = max(TheSettingManager->GetSettingF("Shaders.Particles.Main", "SoftScale"), 0.0f);
	Settings.MeshSoftScale = max(TheSettingManager->GetSettingF("Shaders.Particles.Main", "MeshSoftScale"), 0.0f);
}

// Outdoors: the weather's ambient and, in the shader, its sun colour through the sun shadow. Indoors: the cell's own
// ambient (lighting template or cell lighting); no sun. Point lights are added in the shader either way.
void ParticleShaders::UpdateConstants() {
	const bool exterior = TheShaderManager->GameState.isExterior;
	D3DXVECTOR4 ambient = TheShaderManager->ShaderConst.sunAmbient;
	if (!exterior && Player && Player->parentCell && Player->parentCell->IsInterior() && Player->parentCell->lighting)
		ambient = Player->parentCell->lighting->ambient.toD3DXVECTOR4();
	Constants.Ambient = D3DXVECTOR4(ambient.x, ambient.y, ambient.z, 1.0f);
	// y 1: the game's own light on them, no brightness of NVR's (UNOFFICIAL 2026-11-05, user: "get rid of the brightness setting")
	Constants.Data = D3DXVECTOR4(Settings.Strength, 1.0f, Settings.SunShare, exterior ? 1.0f : 0.0f);
}

void ParticleShaders::BeginWorldScene() {
	SoftDepthState = 0;
	SoftWorldDepth = nullptr;
	ParticleShaders* particles = TheShaderManager->Shaders.Particles;
	if (!particles || !particles->Enabled || (particles->Settings.SoftScale <= 0.0f && particles->Settings.MeshSoftScale <= 0.0f) || !TheTextureManager->ParticleDepthTexture) return;
	IDirect3DSurface9* depth = nullptr;
	TheRenderManager->device->GetDepthStencilSurface(&depth);
	if (!depth) return;
	SoftWorldDepth = depth;
	depth->Release();
	SoftDepthState = 1;
}

void ParticleShaders::EndWorldScene() {
	SoftDepthState = 0;
	SoftWorldDepth = nullptr;
	if (TheShaderManager->Shaders.Particles) TheShaderManager->Shaders.Particles->Constants.Soft.x = 0.0f;	// (draws past the hook keep no fade)
}

// Every NoLighting geometry, after the game set its constants and before it draws (Render.cpp NoLightingConstantsHook). For the NoLighting passes (BSSM_NOLIGHTING ..
// BSSM_NOLIGHTING_STRIP_PSYS_SUBTEX, 0x42-0x57): the vertex shaders' NVR_SoftSize (c41: a mesh's size, and whether it fades; a
// particle's own size is on its vertices) and the pixel shaders' TESR_ParticleSoft (c175, also kept in Constants for SetCT, which uploads
// it again when a NOLIGHT pixel shader binds). The world's depth is copied at the scene's first alpha-blended one: by then the opaque
// scene is drawn (an opaque NoLighting draw can come earlier). Alpha-tested only draws get no fade (it would eat into their cut-out).
void ParticleShaders::ForDraw(NiGeometry* geometry, UInt16 passEnum, bool world) {
	if (passEnum < 0x42 || passEnum > 0x57 || !geometry) return;
	ParticleShaders* particles = TheShaderManager->Shaders.Particles;
	if (!particles || !particles->Enabled) return;
	IDirect3DDevice9* device = TheRenderManager->device;
	const NiAlphaProperty* alpha = (const NiAlphaProperty*)geometry->GetProperty(NiProperty::PropertyType::kType_Alpha);
	const bool blended = alpha && (alpha->flags & NiAlphaProperty::ALPHA_BLEND_MASK);

	float scale = 0.0f;
	if (world && blended && SoftDepthState != 0 && SoftWorldDepth) {
		IDirect3DSurface9* current = nullptr;
		device->GetDepthStencilSurface(&current);
		const bool mainScene = current && current == SoftWorldDepth;
		if (current) current->Release();
		if (mainScene) {
			if (SoftDepthState == 1) {
				TheRenderManager->ResolveDepthBuffer(TheTextureManager->ParticleDepthTexture);
				BlendDepthFix::Apply(device, TheTextureManager->ParticleDepthTexture);	// the game's MSAA (core/BlendDepthFix.h)
				SoftDepthState = 2;
			}
			// Particle systems (0x52-0x57): their own size, only when it is on their vertices; meshes: their bound radius.
			const bool psys = passEnum >= 0x52;
			scale = psys ? (ParticleSize::Installed ? particles->Settings.SoftScale : 0.0f) : particles->Settings.MeshSoftScale;
		}
	}
	const float size[4] = { scale > 0.0f ? geometry->GetWorldBoundRadius() : 0.0f, scale > 0.0f ? 1.0f : 0.0f, 0.0f, 0.0f };
	device->SetVertexShaderConstantF(41, size, 1);
	particles->Constants.Soft = D3DXVECTOR4(scale, 1.0f / (float)TheRenderManager->width, 1.0f / (float)TheRenderManager->height, 0.0f);
	device->SetPixelShaderConstantF(175, (const float*)&particles->Constants.Soft, 1);
}
