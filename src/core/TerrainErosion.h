#pragma once

// Erosion relief on distant terrain ([Shaders.Terrain.Erosion], Includes/TerrainErosion.hlsl): branching gullies carved
// into the LOD terrain's shading, following its slopes downhill.
namespace TerrainErosion {
	void	Initialize();	// ShaderManager::Initialize: the constants, by name, before shaders load
	void	Update();		// RenderHook, every frame: the settings into them
}
