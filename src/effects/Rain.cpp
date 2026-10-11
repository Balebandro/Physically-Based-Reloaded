#include <algorithm>

#include "Rain.h"

namespace RainParticles { void SetRainSource(NiNode* Root); }   // Hooks/Shaders.cpp

void RainEffect::UpdateConstants() {
	if (TheShaderManager->GameState.isRainy && Constants.RainAnimator.switched == false) {
		// it just started raining
		Constants.RainAnimator.switched = true;
		Constants.RainAnimator.Start(0.05f, 1);
	}
	else if (!TheShaderManager->GameState.isRainy && Constants.RainAnimator.switched) {
		// it just stopped raining
		Constants.RainAnimator.switched = false;
		Constants.RainAnimator.Start(0.07f, 0);
	}

	Constants.Data.x = Constants.RainAnimator.GetValue();
}

void RainEffect::UpdateSettings() {
	Constants.Data.y = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "VerticalScale");
	Constants.Data.z = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "Speed");
	Constants.Data.w = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "Opacity");

	Constants.Aspect.x = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "Refraction");
	Constants.Aspect.y = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "Coloring");
	Constants.Aspect.z = TheSettingManager->GetSettingF("Shaders.Precipitations.Main", "Bloom");

	// Rain lives in Wetness Effects' section: [Shaders.WetnessEffects.Rain].
	const char* rain = "Shaders.WetnessEffects.Rain";
	settingRemove = TheSettingManager->GetSettingI(rain, "RemovePrecipitations") != 0;
	settingCull = TheSettingManager->GetSettingI(rain, "CullUnderCover") != 0;
	settingMesh = TheSettingManager->GetSettingI(rain, "UseRainMesh") != 0;
	settingForce = TheSettingManager->GetSettingI(rain, "ForceRain") != 0;
	ApplySwitch(TheShaderManager->Shaders.Wetness && TheShaderManager->Shaders.Wetness->Enabled);
	char path[MAX_PATH] = "";
	TheSettingManager->GetSettingS(rain, "RainMesh", path);
	std::string meshPath = path;
	meshPath.erase(std::remove(meshPath.begin(), meshPath.end(), '"'), meshPath.end());
	std::replace(meshPath.begin(), meshPath.end(), '/', '\\');   // the game's paths use backslashes
	if (_stricmp(meshPath.c_str(), RainMeshPath)) {
		// A different mesh: load it afresh. The old copy is only hidden (never freed while it may be drawn).
		if (OwnRainRoot) OwnRainRoot->m_flags |= NiAVObject::APP_CULLED;
		OwnRainRoot = nullptr;
		rainMeshAttached = false;
		rainMeshFailed = false;
		strncpy_s(RainMeshPath, meshPath.c_str(), _TRUNCATE);
	}
	char roots[512] = "";
	TheSettingManager->GetSettingS(rain, "RainMeshRoots", roots);
	ParticleRoots.clear();
	std::string list = roots;
	list.erase(std::remove(list.begin(), list.end(), '"'), list.end());   // the setting's quotes, or the missing key's default
	size_t start = 0;
	while (start <= list.size()) {
		size_t end = list.find(';', start);
		if (end == std::string::npos) end = list.size();
		std::string name = list.substr(start, end - start);
		name.erase(0, name.find_first_not_of(" \t"));
		name.erase(name.find_last_not_of(" \t") + 1);
		for (char& c : name) c = (char)tolower((unsigned char)c);
		if (!name.empty()) ParticleRoots.push_back(name);
		start = end + 1;
	}
}

void RainEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_RainData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_RainAspect", &Constants.Aspect);
}

// RemovePrecipitations, kept in step with the setting every frame (ShaderManager::UpdateConstants).
//
// Sky::Update (0x63AFC4) and Sky's weather change (0x63A5CB) each call Precipitation::Update (0x636ED0)
// behind a "je" testing for the sky's precipitation; turning that "je" into "jmp short" (0x74 -> 0xEB,
// same displacement) skips the update, and putting it back restores it. Skipping the update alone would
// freeze precipitation already falling in place, so its nodes are culled too while the setting is on.
// The rain meshes of the rain scripts are hidden per draw (Hooks/Shaders.cpp, RainParticles).
void RainEffect::ApplyVanillaPrecipitations() {
	if (RemoveVanilla != vanillaPatched) {
		SafeWrite8(0x0063AFC4, RemoveVanilla ? 0xEB : 0x74);
		SafeWrite8(0x0063A5CB, RemoveVanilla ? 0xEB : 0x74);
		vanillaPatched = RemoveVanilla;
	}

	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	Precipitation* Precip = WorldSky ? WorldSky->precipitation : nullptr;
	NiNode* Nodes[2] = { Precip ? Precip->node04 : nullptr, Precip ? Precip->node08 : nullptr };

	// Diagnostic: the weather and the sky's precipitation, whenever they change.
	static TESWeather* sLastWeather = nullptr;
	static Precipitation* sLastPrecip = nullptr;
	TESWeather* Weather = WorldSky ? WorldSky->firstWeather : nullptr;
	if (Weather != sLastWeather || Precip != sLastPrecip) {
		sLastWeather = Weather;
		sLastPrecip = Precip;
		Logger::Log("RainParticles: weather %08X type %d, sky precipitation %p (nodes %s / %s)",
			Weather ? Weather->refID : 0, Weather ? (int)Weather->GetWeatherType() : -1, Precip,
			Nodes[0] && Nodes[0]->m_pcName ? Nodes[0]->m_pcName : "-", Nodes[1] && Nodes[1]->m_pcName ? Nodes[1]->m_pcName : "-");
	}
	for (int i = 0; i < 2; i++) {
		// A node the precipitation no longer holds may have been freed: forget it, never touch it.
		if (culledNodes[i] && culledNodes[i] != Nodes[i]) culledNodes[i] = nullptr;
		if (!Nodes[i]) continue;
		if (RemoveVanilla) {
			if (!(Nodes[i]->m_flags & NiAVObject::APP_CULLED)) {
				Nodes[i]->m_flags |= NiAVObject::APP_CULLED;
				culledNodes[i] = Nodes[i];
			}
		}
		else if (culledNodes[i]) {
			culledNodes[i]->m_flags &= ~NiAVObject::APP_CULLED;
			culledNodes[i] = nullptr;
		}
	}
}

void RainEffect::ApplySwitch(bool On) {
	CullParticles = settingCull && On;
	RemoveVanilla = settingRemove && On;
	UseRainMesh = settingMesh && On;
	ForceRain = settingForce && On;
}

// Raining, as Honest Hearts' rain script decides it: past the middle of the transition, the incoming
// weather; before it, the outgoing one.
bool RainEffect::IsRainingNow() {
	if (ForceRain) return true;
	Sky* WorldSky = Tes ? Tes->sky : nullptr;
	if (!WorldSky) return false;
	TESWeather* Weather = WorldSky->weatherPercent >= 0.5f ? WorldSky->firstWeather : WorldSky->secondWeather;
	if (!Weather) Weather = WorldSky->firstWeather;
	return Weather && Weather->GetWeatherType() == TESWeather::WeatherType::kType_Rainy;
}

// NVR's own rain mesh. Loaded through the game's model loader (ModelLoader::LoadModel, 0x447080, as JIP
// LN NVSE does) and cloned (NiObject::CreateClone / ProcessClone, vtable 0x48 / 0x68, with a cloning
// process made by 0x4AD0C0), so the loader's cached original is never put in the scene. The copy goes
// under the main world's shadow scene node, which outlives cells; each frame it rains it is moved to the
// player and its particle controllers are run (NiAVObject::UpdateDownwardPass, vtable 0xA4); otherwise
// it is culled. The mesh's particles are world-space: moving the root moves the emitters, not the drops.
void RainEffect::UpdateRainMesh() {
	bool want = UseRainMesh && RainMeshPath[0] && Player && TheShaderManager->GameState.isExterior &&
		!TheShaderManager->GameState.isUnderwater && IsRainingNow();

	if (want && !OwnRainRoot && !rainMeshFailed) {
		void* Loader = *(void**)0x11C3B3C;
		NiNode* Cached = Loader ? (NiNode*)ThisCall(0x447080, Loader, (const char*)RainMeshPath, (UInt32)0, (UInt32)1, (UInt32)0, (UInt32)0, (UInt32)1) : nullptr;
		if (Cached) {
			struct CopyInfo { void* map00; void* map04; UInt32 unk08; UInt8 byte0C; UInt8 pad[3]; float scale[3]; } Info;
			ThisCall(0x4AD0C0, &Info, (UInt32)0x97);
			Info.scale[0] = Info.scale[1] = Info.scale[2] = 1.0f;
			void** Vtbl = *(void***)Cached;
			NiNode* Copy = (NiNode*)ThisCall((UInt32)Vtbl[0x48 / 4], Cached, &Info);
			if (Copy) ThisCall((UInt32)Vtbl[0x68 / 4], Cached, &Info);
			ThisCall(0x4AD1D0, &Info);
			if (Copy) {
				InterlockedIncrement((LONG*)&Copy->m_uiRefCount);   // NVR's own reference: never freed
				Copy->m_flags &= ~NiAVObject::APP_CULLED;
				OwnRainRoot = Copy;
				Logger::Log("RainParticles: NVR rain mesh %s loaded (root %s)", RainMeshPath, Copy->m_pcName ? Copy->m_pcName : "?");
			}
		}
		if (!OwnRainRoot) {
			rainMeshFailed = true;
			Logger::Log("RainParticles: could not load the rain mesh %s", RainMeshPath);
		}
	}
	if (!OwnRainRoot || !want) {
		if (OwnRainRoot) OwnRainRoot->m_flags |= NiAVObject::APP_CULLED;
		RainParticles::SetRainSource(nullptr);
		return;
	}

	// Culled under cover at the draw (Hooks/Shaders.cpp, RainParticles): the mesh's textures mark its
	// draws, and the ortho map is needed while it falls.
	RainParticles::SetRainSource(CullParticles ? OwnRainRoot : nullptr);
	if (CullParticles) TheShaderManager->orthoRequired = true;

	if (!rainMeshAttached) {
		ShadowSceneNode* Scene = BSShaderManager::GetShadowSceneNode(0);
		if (!Scene) return;
		void** Vtbl = *(void***)Scene;
		ThisCall((UInt32)Vtbl[0xDC / 4], Scene, (NiAVObject*)OwnRainRoot, (UInt32)1);   // NiNode::AddObject
		rainMeshAttached = true;
	}

	OwnRainRoot->m_flags &= ~NiAVObject::APP_CULLED;
	OwnRainRoot->m_localTransform.pos = Player->pos;

	rainMeshTime += std::clamp((float)TheFrameRateManager->ElapsedTime, 0.0f, 0.25f);
	struct UpdateData { float time; bool updateControllers; bool multiThreaded; UInt8 byte06; bool updateGeomorphs; bool updateShadowScene; UInt8 pad[3]; } Update = {};
	Update.time = rainMeshTime;
	Update.updateControllers = true;
	void** Vtbl = *(void***)OwnRainRoot;
	ThisCall((UInt32)Vtbl[0xA4 / 4], OwnRainRoot, &Update, (UInt32)0);   // NiAVObject::UpdateDownwardPass
}

bool RainEffect::ShouldRender() {
	return Constants.Data.x > 0.0f &&
		TheShaderManager->GameState.isExterior &&
		!TheShaderManager->GameState.isUnderwater;
};