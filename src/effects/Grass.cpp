#include <algorithm>

#include "Grass.h"

void GrassShaders::RegisterConstants() {
	Constants.Brightness = D3DXVECTOR4(1.0f, 0.0f, 0.0f, 0.0f);
	TheShaderManager->RegisterConstant("TESR_GrassScale", &Constants.Scale);
	TheShaderManager->RegisterConstant("TESR_GrassBrightness", &Constants.Brightness);
	TheShaderManager->RegisterConstant("TESR_GrassBend", &Constants.Bend);
	TheShaderManager->RegisterConstant("TESR_GrassBendParams", &Constants.BendParams);
	TheShaderManager->RegisterConstant("TESR_GrassLOD", &Constants.LOD);
	InstallHooks();
}

// iMinGrassSize, fTexturePctThreshold, fGrass*Distance and fGrassWindMagnitude* are consumed
// at cell load: writing them affects only cells loaded afterwards.
void GrassShaders::UpdateSettings() {
	if (!Enabled) return;

	Constants.Scale.x = TheSettingManager->GetSettingF("Shaders.Grass.Main", "ScaleX");
	Constants.Scale.y = TheSettingManager->GetSettingF("Shaders.Grass.Main", "ScaleY");
	Constants.Scale.z = TheSettingManager->GetSettingF("Shaders.Grass.Main", "ScaleZ");
	Constants.Brightness.x = std::clamp(TheSettingManager->GetSettingF("Shaders.Grass.Main", "Brightness"), 0.0f, 4.0f);

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

	if (s.Debug && (DebugClock += max(dt, 0.0f)) >= 2.0f) {
		DebugClock = 0.0f;
		Logger::Log("Grass interaction: speed %.0f, strength %.1f, centre %.0f %.0f %.0f camera-relative", Speed, strength,
			Constants.Bend.x, Constants.Bend.y, Constants.Bend.z);
	}
}

void GrassShaders::SetBatchConstants(NiGeometry* Geometry) {
	if (!Enabled || !LOD.Enabled || !Geometry || !Geometry->geomData) return;
	NiGeometryData* data = Geometry->geomData;
	float detail = 1.0f + LOD.DetailStrength * min((float)data->m_usVertices / LOD.DetailVertices, 1.0f);
	D3DXVECTOR4 batch(max(data->m_kBound.Radius, 0.0f), detail, 0.0f, 0.0f);
	TheRenderManager->device->SetVertexShaderConstantF(250, (const float*)&batch, 1);
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
	SetBatchConstants(Geometry);
}
