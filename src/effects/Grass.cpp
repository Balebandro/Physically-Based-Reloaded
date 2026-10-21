#include <algorithm>

#include "Grass.h"

void GrassShaders::RegisterConstants() {
	Constants.Brightness = D3DXVECTOR4(1.0f, 1.0f, 0.0f, 0.0f);
	TheShaderManager->RegisterConstant("TESR_GrassBrightness", &Constants.Brightness);
	TheShaderManager->RegisterConstant("TESR_GrassBend", &Constants.Bend);
	TheShaderManager->RegisterConstant("TESR_GrassBendParams", &Constants.BendParams);
	TheShaderManager->RegisterConstant("TESR_GrassLOD", &Constants.LOD);
	TheShaderManager->RegisterConstant("TESR_GrassLightData", &Constants.LightData);
	TheShaderManager->RegisterConstant("TESR_GrassLightPosition", LightPosition);
	TheShaderManager->RegisterConstant("TESR_GrassLightColor", LightColor);
	InstallHooks();
}

// iMinGrassSize, fTexturePctThreshold, fGrass*Distance and fGrassWindMagnitude* are consumed
// at cell load: writing them affects only cells loaded afterwards.
void GrassShaders::UpdateSettings() {
	if (!Enabled) return;

	Constants.Brightness.x = std::clamp(TheSettingManager->GetSettingF("Shaders.Grass.Main", "Brightness"), 0.0f, 4.0f);
	NightBrightness = std::clamp(TheSettingManager->GetSettingF("Shaders.Grass.Main", "NightBrightness"), 0.0f, 4.0f);

	const char* bend = "Shaders.Grass.Interaction";
	Interaction.Enabled = TheSettingManager->GetSettingI(bend, "Enabled") != 0;
	Interaction.Radius = std::clamp(TheSettingManager->GetSettingF(bend, "Radius"), 10.0f, 1000.0f);
	Interaction.StrengthStanding = std::clamp(TheSettingManager->GetSettingF(bend, "StrengthStanding"), 0.0f, 1000.0f);
	Interaction.StrengthMax = std::clamp(TheSettingManager->GetSettingF(bend, "StrengthMax"), 0.0f, 1000.0f);
	Interaction.SpeedForMax = std::clamp(TheSettingManager->GetSettingF(bend, "SpeedForMax"), 1.0f, 5000.0f);
	Interaction.SpringBackSeconds = std::clamp(TheSettingManager->GetSettingF(bend, "SpringBackSeconds"), 0.01f, 10.0f);
	Interaction.PositionLagSeconds = std::clamp(TheSettingManager->GetSettingF(bend, "PositionLagSeconds"), 0.0f, 2.0f);
	Interaction.Debug = TheSettingManager->GetSettingI(bend, "Debug") != 0;

	const char* lod = "Shaders.Grass.LOD";
	LOD.Enabled = TheSettingManager->GetSettingI(lod, "Enabled") != 0;
	LOD.MinPixels = std::clamp(TheSettingManager->GetSettingF(lod, "MinPixels"), 0.0f, 200.0f);
	LOD.FadePixels = std::clamp(TheSettingManager->GetSettingF(lod, "FadePixels"), 0.5f, 200.0f);
	LOD.DetailVertices = std::clamp(TheSettingManager->GetSettingF(lod, "DetailVertices"), 1.0f, 65535.0f);
	LOD.DetailStrength = std::clamp(TheSettingManager->GetSettingF(lod, "DetailStrength"), 0.0f, 10.0f);

	const char* lights = "Shaders.Grass.Lights";
	Lights.Enabled = TheSettingManager->GetSettingI(lights, "Enabled") != 0;
	Lights.MaxLights = std::clamp(TheSettingManager->GetSettingI(lights, "MaxLights"), 0, MaxGrassLights);
	Lights.Strength = std::clamp(TheSettingManager->GetSettingF(lights, "Strength"), 0.0f, 1.0f);

	const char* normals = "Shaders.Grass.NormalMaps";
	NormalMaps.Enabled = TheSettingManager->GetSettingI(normals, "Enabled") != 0;
	NormalMaps.Strength = std::clamp(TheSettingManager->GetSettingF(normals, "Strength"), 0.0f, 4.0f);

	Specular.Enabled = TheSettingManager->GetSettingI(normals, "EnableSpecular") != 0;
	Specular.Strength = std::clamp(TheSettingManager->GetSettingF(normals, "SpecularStrength"), 0.0f, 4.0f);
	Specular.Glossiness = std::clamp(TheSettingManager->GetSettingF(normals, "Glossiness"), 1.0f, 512.0f);
}

// The lamps nearest the camera that reach anything near it, from both of NVR's light lists (the shadow-casting ones,
// ShadowsExteriors' ShadowLightPosition with colours in LightColor[0..], and the rest, LightPosition with colours after
// them). A light's sphere edge counts, not its centre: a big lamp farther off can light more of the grass in view.
void GrassShaders::UpdateLights() {
	Constants.LightData = D3DXVECTOR4(0.0f, Lights.Strength, 0.0f, 0.0f);
	if (!Lights.Enabled || Lights.MaxLights <= 0 || Lights.Strength <= 0.0f) return;

	struct Candidate { float key; D3DXVECTOR4 pos; D3DXVECTOR4 color; };
	Candidate found[ShadowCubeMapsMax + TrackedLightsMax];
	int count = 0;
	const D3DXVECTOR4 cam = TheRenderManager->CameraPosition;
	auto add = [&](const D3DXVECTOR4& pos, const D3DXVECTOR4& color) {
		const float radius = pos.w;
		const float brightness = (color.x + color.y + color.z) * color.w;
		if (radius <= 1.0f || brightness <= 0.01f) return;
		const float dx = pos.x - cam.x, dy = pos.y - cam.y, dz = pos.z - cam.z;
		found[count++] = { sqrtf(dx * dx + dy * dy + dz * dz) - radius, D3DXVECTOR4(dx, dy, dz, radius),
			D3DXVECTOR4(color.x * color.w, color.y * color.w, color.z * color.w, 0.0f) };
	};
	const D3DXVECTOR4* shadowLights = TheShaderManager->Effects.ShadowsExteriors->Constants.ShadowLightPosition;
	for (int i = 0; i < ShadowCubeMapsMax; i++) add(shadowLights[i], TheShaderManager->LightColor[i]);
	for (int i = 0; i < TrackedLightsMax; i++) add(TheShaderManager->LightPosition[i], TheShaderManager->LightColor[ShadowCubeMapsMax + i]);

	std::sort(found, found + count, [](const Candidate& a, const Candidate& b) { return a.key < b.key; });
	const int used = min(count, Lights.MaxLights);
	for (int i = 0; i < used; i++) {
		LightPosition[i] = found[i].pos;
		LightColor[i] = found[i].color;
	}
	Constants.LightData.x = (float)used;
}

// There Stands The Grass NVSE's PlayerBend::Update, line for line (core/PlayerBend.cpp, Into-The-Rough): the bend origin
// eases toward the player over PositionLagSeconds, the strength toward its target over SpringBackSeconds, both ways;
// the speed is the raw distance moved this frame, and anything past 2000 units a second is a teleport or a load.
void GrassShaders::UpdateConstants() {
	const InteractionSettings& s = Interaction;
	float dt = (float)TheFrameRateManager->ElapsedTime;
	if (dt > 0.0f) {
		bool active = s.Enabled && Player && TheShaderManager->GameState.isExterior;

		float target = 0.0f, px = 0.0f, py = 0.0f, pz = 0.0f;
		if (active) {
			px = Player->pos.x; py = Player->pos.y; pz = Player->pos.z;
			float speed = 0.0f;
			if (HavePrev) {
				float dx = px - LastPlayerPos.x, dy = py - LastPlayerPos.y;
				speed = sqrtf(dx * dx + dy * dy) / dt;
				if (speed > 2000.0f) speed = 0.0f;   // teleport or load
			}
			LastPlayerPos = Player->pos;
			HavePrev = true;
			Speed = speed;
			float frac = min(speed / s.SpeedForMax, 1.0f);
			target = s.StrengthStanding + (s.StrengthMax - s.StrengthStanding) * frac;
		}
		else HavePrev = false;

		if (!Have && active) {
			BendCentre = Player->pos;
			Have = true;
		}
		if (Have) {
			float posAlpha = min(dt / s.PositionLagSeconds, 1.0f);
			if (active) {
				BendCentre.x += (px - BendCentre.x) * posAlpha;
				BendCentre.y += (py - BendCentre.y) * posAlpha;
				BendCentre.z += (pz - BendCentre.z) * posAlpha;
			}
			float strAlpha = min(dt / s.SpringBackSeconds, 1.0f);
			Push += (target - Push) * strAlpha;
			if (!active && Push < 0.05f) {
				Have = false;
				Push = 0.0f;
			}
		}
	}

	// The shader constants, as TSTG's GrassBend::Upload builds them: the origin, 1 / radius, and the strength per unit of
	// blade height (strength / 90 * 0.5). The origin goes into the frame the grass shaders rebuild positions in
	// (GetShadowWorldPos): camera-relative world, as the shadow code builds it (ShadowManager: position - CameraPosition).
	D3DXVECTOR4 cam = TheRenderManager->CameraPosition;
	float strength = Have ? Push : 0.0f;
	Constants.Bend = D3DXVECTOR4(BendCentre.x - cam.x, BendCentre.y - cam.y, BendCentre.z - cam.z, 1.0f / max(s.Radius, 1.0f));
	Constants.BendParams = D3DXVECTOR4(strength / 90.0f * 0.5f, 0.0f, 0.0f, s.Debug ? 1.0f : 0.0f);

	// Pixels a unit covers at a depth of 1: half the screen height times the projection's vertical scale.
	Constants.LOD = D3DXVECTOR4(0.5f * (float)TheRenderManager->height * TheRenderManager->projMatrix._22, LOD.MinPixels, LOD.FadePixels, LOD.Enabled ? 1.0f : 0.0f);

	// The night brightness, outdoors: full at night, 1 by day, following the same curve as the other day/night transitions.
	const float day = TheShaderManager->GameState.isExterior ? TheShaderManager->GameState.transitionCurve : 1.0f;
	Constants.Brightness.y = NightBrightness + (1.0f - NightBrightness) * day;

	UpdateLights();

	if (s.Debug && (DebugClock += max(dt, 0.0f)) >= 2.0f) {
		DebugClock = 0.0f;
		Logger::Log("Grass interaction: speed %.0f, strength %.1f, centre %.0f %.0f %.0f camera-relative", Speed, strength,
			Constants.Bend.x, Constants.Bend.y, Constants.Bend.z);
	}
}

// Written for every shape, LOD or not: z (static) must never carry over from one shape to the next. x 0 turns the size
// fade off for the shape (GrassLODFade).
void GrassShaders::SetBatchConstants(NiGeometry* Geometry, bool Static) {
	if (!Enabled || !Geometry || !Geometry->geomData) return;
	D3DXVECTOR4 batch(0.0f, 1.0f, Static ? 1.0f : 0.0f, 0.0f);
	if (LOD.Enabled) {
		NiGeometryData* data = Geometry->geomData;
		batch.x = max(data->m_kBound.Radius, 0.0f);
		batch.y = 1.0f + LOD.DetailStrength * min((float)data->m_usVertices / LOD.DetailVertices, 1.0f);
	}
	TheRenderManager->device->SetVertexShaderConstantF(250, (const float*)&batch, 1);
}

// Rocks placed as grass (Rock Grass and the like) stand still: no sway, no bending. Known by their diffuse texture's path.
static bool IsStaticGrass(const NiSourceTexture* Diffuse) {
	const char* path = Diffuse ? Diffuse->ddsPath1 : nullptr;
	if (!path) return false;
	for (const char* p = path; *p; p++)
		if (!_strnicmp(p, "rock", 4)) return true;
	return false;
}

// Every grass shape as the game sets it up to draw: the grass shader's per-geometry setup (TallGrassShader, vtable
// 0x10B8980 slot 24; the geometry first, its transform seventh). The game draws grass in groups -- one shader setup,
// then this for each shape -- so the SetShaders hook alone sees only a group's first shape. Chained: There Stands The
// Grass NVSE hooks the same slot, and whichever of us comes second calls the other.
typedef int(__thiscall* GrassSetupFn)(void*, NiGeometry*, int, int, int, int, int, float*, int);
static GrassSetupFn sGrassSetup = nullptr;

static int __fastcall GrassSetupHook(void* Shader, void*, NiGeometry* Geometry, int a3, int a4, int a5, int a6, int a7, float* Transform, int a9) {
	if (GrassShaders* grass = TheShaderManager ? TheShaderManager->Shaders.Grass : nullptr) grass->OnGrassShape(Geometry);
	return sGrassSetup(Shader, Geometry, a3, a4, a5, a6, a7, Transform, a9);
}

void GrassShaders::InstallHooks() {
	if (sGrassSetup) return;
	void** slot = (void**)(0x10B8980 + 24 * 4);
	DWORD old;
	VirtualProtect(slot, 4, PAGE_EXECUTE_READWRITE, &old);
	sGrassSetup = (GrassSetupFn)*slot;
	*slot = (void*)&GrassSetupHook;
	VirtualProtect(slot, 4, old, &old);
	Logger::Log("Grass: per-shape setup hooked (was %p)", sGrassSetup);
}

void GrassShaders::OnGrassShape(NiGeometry* Geometry) {
	if (!Geometry) return;

	// The shape's diffuse texture: TallGrassShaderProperty (shade type 4) keeps it (an NiSourceTexture) at +0x84 (its
	// getter 0xBB36C0, which TallGrassShader's texture setup 0xBAC950 binds to s0).
	const NiSourceTexture* diffuse = nullptr;
	if (NiShadeProperty* shade = (NiShadeProperty*)Geometry->GetProperty(NiProperty::kType_Shade))
		if (shade->m_eShaderType == NiShadeProperty::kProp_TallGrass)
			diffuse = *(NiSourceTexture**)((UInt8*)shade + 0x84);
	SetBatchConstants(Geometry, IsStaticGrass(diffuse));

	// Its normal map, from the diffuse texture's name. s1 goes through the render state cache, as MaterialMaps binds its
	// maps, so the next shader using s1 gets its own back.
	IDirect3DTexture9* map = nullptr;
	if (Enabled && NormalMaps.Enabled && NormalMaps.Strength > 0.0f && diffuse)
		map = MaterialMaps::FindNormalMap(diffuse);
	if (map) {
		NiDX9RenderState* state = TheRenderManager->renderState;
		state->SetTexture(1, map);
		state->SetSamplerState(1, D3DSAMP_ADDRESSU, D3DTADDRESS_WRAP, false);
		state->SetSamplerState(1, D3DSAMP_ADDRESSV, D3DTADDRESS_WRAP, false);
		state->SetSamplerState(1, D3DSAMP_MINFILTER, D3DTEXF_LINEAR, false);
		state->SetSamplerState(1, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR, false);
		state->SetSamplerState(1, D3DSAMP_MIPFILTER, D3DTEXF_LINEAR, false);
		state->SetSamplerState(1, D3DSAMP_SRGBTEXTURE, FALSE, false);
	}
	D3DXVECTOR4 material(map ? 1.0f : 0.0f, NormalMaps.Strength, Specular.Enabled ? Specular.Strength : 0.0f, Specular.Glossiness);
	TheRenderManager->device->SetPixelShaderConstantF(147, (const float*)&material, 1);
}
