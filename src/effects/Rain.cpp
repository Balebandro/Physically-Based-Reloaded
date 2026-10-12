#include <algorithm>

#include "Rain.h"

namespace RainParticles { void SetRainSource(NiNode* Root, bool Cull, float Density); }   // Hooks/Shaders.cpp

// The selective update flags off, down the whole copy, so the game's per-frame selective update of the
// scene skips it: UpdateRainMesh's full update below is then the only one that runs its particles, on
// one clock. (Run by both, the emitters would see time jump between the two clocks every frame.)
static void ClearSelectiveUpdate(NiAVObject* Object, int Depth) {
	if (!Object || Depth > 12) return;
	Object->m_flags &= ~(NiAVObject::SELECTIVE_UPDATE | NiAVObject::SELECTIVE_UPDATE_TRANSFORMS |
		NiAVObject::SELECTIVE_UPDATE_CONTROLLER | NiAVObject::SELECTIVE_UPDATE_RIGID);
	UInt32 Vtbl = *(UInt32*)Object;
	if (Vtbl == 0x109B5AC || Vtbl == 0x10A8F90) {   // NiNode, BSFadeNode
		NiAVObject** Children = *(NiAVObject***)((char*)Object + 0xA0);
		UInt16 Count = *(UInt16*)((char*)Object + 0xA6);
		for (UInt16 i = 0; Children && i < Count; i++) ClearSelectiveUpdate(Children[i], Depth + 1);
	}
}

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

	RemoveVanilla = TheSettingManager->GetSettingI("Main.Main.Precipitations", "RemovePrecipitations") != 0;
	const char* rain = "Shaders.Precipitations.Particles";
	CullParticles = TheSettingManager->GetSettingI(rain, "CullUnderCover") != 0;
	UseRainMesh = TheSettingManager->GetSettingI(rain, "UseRainMesh") != 0;
	ForceRain = TheSettingManager->GetSettingI(rain, "ForceRain") != 0;
	// 0 (a missing key) reads as the default 1.
	float density = TheSettingManager->GetSettingF(rain, "RainMeshDensity");
	MeshDensity = density > 0.0f ? std::clamp(density, 0.1f, 1.0f) : 1.0f;
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

	// The rain meshes rain scripts place (3D Rain's in Zion, Honest Hearts', Climate Control's): looked
	// for four times a second, as a script may enable or move one at any time.
	DWORD Now = GetTickCount();
	if (RemoveVanilla && Now - lastRainScan >= 250) {
		lastRainScan = Now;
		HideGameRainMeshes(true);
	}
	else if (!RemoveVanilla && !hiddenGameRain.empty())
		HideGameRainMeshes(false);
}

// A reference's 3D that is a rain mesh: its root, or a node right below it, named in RainMeshRoots.
static bool IsRainMesh(NiNode* Node, const std::vector<std::string>& Roots) {
	auto Named = [&Roots](NiAVObject* Object) {
		const char* Name = Object ? Object->m_pcName : nullptr;
		if (!Name || !*Name) return false;
		for (const std::string& Root : Roots)
			if (!_stricmp(Name, Root.c_str())) return true;
		return false;
	};
	if (Named(Node)) return true;
	UInt32 Vtbl = *(UInt32*)Node;
	if (Vtbl != 0x109B5AC && Vtbl != 0x10A8F90) return false;   // NiNode, BSFadeNode
	NiAVObject** Children = *(NiAVObject***)((char*)Node + 0xA0);
	UInt16 Count = *(UInt16*)((char*)Node + 0xA6);
	for (UInt16 i = 0; Children && i < Count; i++)
		if (Named(Children[i])) return true;
	return false;
}

// Hides (APP_CULLED) the game's rain meshes in the loaded cells and the worldspace's persistent cell,
// or shows again the ones this hid. NVR's own copy is never one of them. Only nodes found in the cells
// now are touched: a hidden node whose reference has gone is just forgotten.
void RainEffect::HideGameRainMeshes(bool Hide) {
	std::unordered_set<NiNode*> Found;
	auto ScanCell = [&](TESObjectCELL* Cell) {
		if (!Cell) return;
		for (TList<TESObjectREFR>::Entry* Entry = &Cell->objectList.First; Entry; Entry = Entry->next) {
			TESObjectREFR* Ref = Entry->item;
			NiNode* Node = Ref ? Ref->GetNode() : nullptr;
			if (!Node || Node == OwnRainRoot || !IsRainMesh(Node, ParticleRoots)) continue;
			bool Ours = hiddenGameRain.count(Node) != 0;
			if (Hide) {
				if (!(Node->m_flags & NiAVObject::APP_CULLED)) {
					Node->m_flags |= NiAVObject::APP_CULLED;
					Ours = true;
					static UInt32 sLogged = 0;
					if (sLogged++ < 8) Logger::Log("RainParticles: RemovePrecipitations hid the game's rain mesh %s (reference %08X)",
						Node->m_pcName ? Node->m_pcName : "?", Ref->refID);
				}
				if (Ours) Found.insert(Node);
			}
			else if (Ours)
				Node->m_flags &= ~NiAVObject::APP_CULLED;
		}
	};

	if (Player && Tes) {
		TESWorldSpace* World = Player->GetWorldSpace();
		if (World) {
			GridCellArray* CellArray = Tes->gridCellArray;
			UInt32 CellCount = CellArray ? CellArray->size * CellArray->size : 0;
			for (UInt32 i = 0; i < CellCount; i++) ScanCell(CellArray->GetCell(i));
			ScanCell(World->cell);   // persistent references
		}
		else
			ScanCell(Player->parentCell);
	}
	hiddenGameRain = Hide ? std::move(Found) : std::unordered_set<NiNode*>();
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
				ClearSelectiveUpdate(Copy, 0);
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
		RainParticles::SetRainSource(nullptr, false, 1.0f);
		return;
	}

	// Culled under cover and thinned to RainMeshDensity at the draw (Hooks/Shaders.cpp, RainParticles):
	// the mesh's textures mark its draws, and the ortho map is needed while it falls.
	RainParticles::SetRainSource(OwnRainRoot, CullParticles, MeshDensity);
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