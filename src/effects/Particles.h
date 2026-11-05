#pragma once

// UNOFFICIAL, optional (off by default; Shaders.Particles): lit particles and blood decals (GDECAL/GDECALS: blood on
// characters, unlit in the game too). The game draws blood, smoke, dust and
// debris particle systems unlit (BSSM_NOLIGHTING_PSYS and _SUBTEX_OFFSET: NOLIGHT016/017.vso + NOLIGHTTEXVC.pso),
// so they keep full brightness in shade, at night and indoors. The replacements light them with the ambient, the sun
// through the forward sun shadow, and nearby point lights. Glows, muzzle flashes, flames and sparks share the pixel
// shader but not the vertex shaders, and stay exactly as the game draws them (see SetShadersHook's pairing guard).
class ParticleShaders : public ShaderCollection
{
public:
	ParticleShaders() : ShaderCollection("Particles") {};

	struct ParticleStruct {
		D3DXVECTOR4		Data;		// x: strength (0 = as the game draws them), y: 1 (the game's own brightness), z: sun share, w: 1 outdoors (sun)
		D3DXVECTOR4		Ambient;	// rgb: ambient light (the sky's outdoors, the cell's indoors)
		D3DXVECTOR4		Soft;		// UNOFFICIAL 2026-11-04 soft particles: x: soft scale (0: off for this draw), yz: 1 / resolution
	};
	ParticleStruct	Constants;

	struct ParticleSettings {
		float	Strength;
		float	SunShare;
		float	SoftScale;		// particle systems (their own size)
		float	MeshSoftScale;	// NoLighting meshes (their bound radius): glows, lamp cards, the dust storm walls
	};
	ParticleSettings	Settings;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();

	// UNOFFICIAL 2026-11-04 soft particles (after Vanilla Plus Particles): particles fade where they meet the scene behind them, over
	// their own size x SoftScale (a mesh: its bound radius x MeshSoftScale), every alpha-blended NoLighting draw (BSSM_NOLIGHTING* passes). The world's depth is
	// copied once a world scene, at its first such draw; anywhere else (another depth buffer, outside the world scene) they draw as before.
	static void	BeginWorldScene();
	static void	EndWorldScene();
	static void	ForDraw(NiGeometry* geometry, UInt16 passEnum, bool world);	// every NoLighting geometry, before it draws (Render.cpp NoLightingConstantsHook)
	static inline int					SoftDepthState = 0;			// 0 outside the world scene, 1 copy still to take, 2 taken
	static inline IDirect3DSurface9*	SoftWorldDepth = nullptr;	// depth surface bound as the world scene starts (compared only)
};
