#include <cfloat>
#include <algorithm>

#include "Terrain.h"

void TerrainShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_TerrainData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_TerrainExtraData", &Constants.ExtraData);
	TheShaderManager->RegisterConstant("TESR_TerrainSkyData", &Constants.SkyData);
	TheShaderManager->RegisterConstant("TESR_TerrainPBRData", &Constants.PBRData);
	TheShaderManager->RegisterConstant("TESR_TerrainParallaxData", &ParallaxConstants.Data);
	TheShaderManager->RegisterConstant("TESR_TerrainParallaxExtraData", &ParallaxConstants.ExtraData);
}


void TerrainShaders::UpdateSettings() {
	usePBR = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "UsePBR");

	Settings.Default.Saturation = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "TerrainSaturation");
	Settings.Default.RoughnessScale = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "RoughnessScale");
	Settings.Default.LightScale = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "LightingScale");
	Settings.Default.AmbientScale = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "AmbientScale");
	Settings.Default.SkylightingScale = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "SkylightingScale");
	Settings.Default.SpecularStrength = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "SpecularStrength");
	Settings.Default.VanillaMatchedHighlights = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "VanillaMatchedHighlights");
	Settings.Default.SkyReflectionScale = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "SkyReflectionScale");
	Settings.Default.AmbientNormalDetail = TheSettingManager->GetSettingF("Shaders.Terrain.Main", "AmbientNormalDetail");

	Settings.Rain.Saturation = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "TerrainSaturation");
	Settings.Rain.RoughnessScale = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "RoughnessScale");
	Settings.Rain.LightScale = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "LightingScale");
	Settings.Rain.AmbientScale = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "AmbientScale");
	Settings.Rain.SkylightingScale = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "SkylightingScale");
	Settings.Rain.SpecularStrength = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "SpecularStrength");
	Settings.Rain.VanillaMatchedHighlights = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "VanillaMatchedHighlights");
	Settings.Rain.SkyReflectionScale = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "SkyReflectionScale");
	Settings.Rain.AmbientNormalDetail = TheSettingManager->GetSettingF("Shaders.Terrain.Rain", "AmbientNormalDetail");

	Settings.Night.Saturation = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "TerrainSaturation");
	Settings.Night.RoughnessScale = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "RoughnessScale");
	Settings.Night.LightScale = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "LightingScale");
	Settings.Night.AmbientScale = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "AmbientScale");
	Settings.Night.SkylightingScale = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "SkylightingScale");
	Settings.Night.SpecularStrength = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "SpecularStrength");
	Settings.Night.VanillaMatchedHighlights = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "VanillaMatchedHighlights");
	Settings.Night.SkyReflectionScale = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "SkyReflectionScale");
	Settings.Night.AmbientNormalDetail = TheSettingManager->GetSettingF("Shaders.Terrain.Night", "AmbientNormalDetail");

	Settings.NightRain.Saturation = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "TerrainSaturation");
	Settings.NightRain.RoughnessScale = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "RoughnessScale");
	Settings.NightRain.LightScale = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "LightingScale");
	Settings.NightRain.AmbientScale = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "AmbientScale");
	Settings.NightRain.SkylightingScale = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "SkylightingScale");
	Settings.NightRain.SpecularStrength = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "SpecularStrength");
	Settings.NightRain.VanillaMatchedHighlights = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "VanillaMatchedHighlights");
	Settings.NightRain.SkyReflectionScale = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "SkyReflectionScale");
	Settings.NightRain.AmbientNormalDetail = TheSettingManager->GetSettingF("Shaders.Terrain.NightRain", "AmbientNormalDetail");

	ParallaxSettings.Enabled = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "Enabled");
	ParallaxSettings.HighQuality = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "HighQuality");
	ParallaxSettings.Shadows = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "Shadows");
	ParallaxSettings.HeightBlend = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "HeightBlend");
	ParallaxSettings.MaxDistance = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "MaxDistance");
	ParallaxSettings.Height = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "Height");
	ParallaxSettings.ShadowsIntensity = TheSettingManager->GetSettingF("Shaders.Terrain.Parallax", "ShadowsIntensity");
	ParallaxSettings.Lite = TheSettingManager->GetSettingI("Main.Main.ReducedQuality", "ParallaxLite");
	ParallaxSettings.CheapUnderwater = TheSettingManager->GetSettingI("Main.Main.ReducedQuality", "CheapUnderwaterTerrain");

	// [Shaders.PBR.Main] LinearLighting, shared with the object shaders so both light the same way
	// (two lighting spaces would show where terrain meets objects).
	Constants.SkyData.z = TheSettingManager->GetSettingI("Shaders.PBR.Main", "LinearLighting") ? 1.0f : 0.0f;

	// Land's own material settings: FNV's landscape specular data is crude and vanilla-matched land
	// highlights blow out paths seen against a low sun, so terrain gets its own strength, vanilla
	// match, reflections and ambient detail, per weather (blended in UpdateConstants). The
	// specular occlusion switch is [Shaders.Terrain.Main] only.
	Constants.PBRData.z = TheSettingManager->GetSettingI("Shaders.Terrain.Main", "SpecularOcclusion") ? 1.0f : 0.0f;
	// DebugView stays the object one: one switch for the whole material debug view.
	Constants.PBRData.w = (float)std::clamp(TheSettingManager->GetSettingI("Shaders.PBR.Main", "DebugView"), 0, 4);

	LODSettings.NoiseScale = TheSettingManager->GetSettingF("Shaders.Terrain.LOD", "LODNoiseScale");
	LODSettings.NoiseTile = TheSettingManager->GetSettingF("Shaders.Terrain.LOD", "LODNoiseTile");
}

void TerrainShaders::UpdateConstants() {
	// get max value between rain animator and puddle animator
	float rainFactor = max(TheShaderManager->Effects.WetWorld->Constants.Data.x, TheShaderManager->Effects.WetWorld->Constants.Data.z);

	if (!TheShaderManager->GameState.isExterior) return;

	Constants.ExtraData.x = usePBR;
	Constants.ExtraData.y = std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.Saturation, Settings.Night.Saturation, 0.0),
		TheShaderManager->GetTransitionValue(Settings.Rain.Saturation, Settings.NightRain.Saturation, 0.0), rainFactor);
	// Hemisphere skylight strength. No separate toggle: 0 disables it. Terrain has no
	// Interiors section -- UpdateConstants returns early indoors -- so the interior operand
	// of GetTransitionValue is 0, matching how the other terrain settings blend.
	Constants.SkyData.x = std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.SkylightingScale, Settings.Night.SkylightingScale, 0.0),
		TheShaderManager->GetTransitionValue(Settings.Rain.SkylightingScale, Settings.NightRain.SkylightingScale, 0.0), rainFactor);


	Constants.ExtraData.z = LODSettings.NoiseScale;
	Constants.ExtraData.w = LODSettings.NoiseTile;

	if (usePBR) {
		Constants.Data.y = std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.RoughnessScale, Settings.Night.RoughnessScale, 0.0),
			TheShaderManager->GetTransitionValue(Settings.Rain.RoughnessScale, Settings.NightRain.RoughnessScale, 0.0), rainFactor);
	}

	Constants.Data.z = std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.LightScale, Settings.Night.LightScale, 0.0),
		TheShaderManager->GetTransitionValue(Settings.Rain.LightScale, Settings.NightRain.LightScale, 0.0), rainFactor);
	Constants.Data.w = std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.AmbientScale, Settings.Night.AmbientScale, 0.0),
		TheShaderManager->GetTransitionValue(Settings.Rain.AmbientScale, Settings.NightRain.AmbientScale, 0.0), rainFactor);

	// Land material settings, per weather like the rest.
	auto blend = [&](float TerrainSettings::* member) {
		return std::lerp(TheShaderManager->GetTransitionValue(Settings.Default.*member, Settings.Night.*member, 0.0),
			TheShaderManager->GetTransitionValue(Settings.Rain.*member, Settings.NightRain.*member, 0.0), rainFactor);
	};
	Constants.Data.x = max(0.0f, blend(&TerrainSettings::SpecularStrength));
	Constants.SkyData.w = std::clamp(blend(&TerrainSettings::VanillaMatchedHighlights), 0.0f, 1.0f);
	Constants.PBRData.x = max(0.0f, blend(&TerrainSettings::SkyReflectionScale));
	Constants.PBRData.y = std::clamp(blend(&TerrainSettings::AmbientNormalDetail), 0.0f, 1.0f);

	ParallaxConstants.Data.x = ParallaxSettings.Enabled;
	ParallaxConstants.Data.y = ParallaxSettings.Shadows;
	ParallaxConstants.Data.z = ParallaxSettings.HeightBlend;
	// .w: 0 = 8 steps, 1 = 16 (HighQuality), 2 = [Main.Main.ReducedQuality] ParallaxLite (TerrainParallax.hlsl),
	// which replaces both. Ported from NVR UNOFFICIAL Optimized (P60-P61).
	ParallaxConstants.Data.w = ParallaxSettings.Lite ? 2.0f : (float)ParallaxSettings.HighQuality;

	// ParallaxLite also caps how far the terrain parallax and its shadows reach: 1024 units at 1440p, scaled with the
	// screen height (a bump's size on screen goes with screen height / distance): 768 at 1080p, 1536 at 4K. A lower
	// MaxDistance still applies.
	float maxDistance = ParallaxSettings.MaxDistance;
	if (ParallaxSettings.Lite) maxDistance = min(maxDistance, 1024.0f * TheRenderManager->height / 1440.0f);
	ParallaxConstants.ExtraData.x = maxDistance;

	// [Main.Main.ReducedQuality] CheapUnderwaterTerrain: ground below the water surface skips parallax and its shadows
	// (TerrainTemplate.hlsl). .w is the camera-relative height below which terrain counts as under water: the level of
	// the water the player is in or looking at, a little lower so the shoreline keeps its parallax. Only while a water
	// plane is loaded nearby (the cell's default water level could lie above dry ground). -FLT_MAX = off. The
	// reflection pass switches it off too (ReflectionPassScope). Ported from NVR UNOFFICIAL Optimized (P48).
	static const float WaterlineMargin = 10.0f;   // game units, about 14 cm
	ParallaxConstants.ExtraData.w = -FLT_MAX;
	if (ParallaxSettings.CheapUnderwater && Tes && Tes->waterManager && Tes->waterManager->waterGroups.count && Player && Player->parentCell && WorldSceneGraph) {
		TESWaterForm* water = nullptr;
		const float height = Tes->GetWaterHeight(Player, WorldSceneGraph, &water);
		if (water) ParallaxConstants.ExtraData.w = height - WaterlineMargin - TheRenderManager->CameraPosition.z;
	}
	ParallaxConstants.ExtraData.y = ParallaxSettings.Height;
	ParallaxConstants.ExtraData.z = ParallaxSettings.ShadowsIntensity;
};

