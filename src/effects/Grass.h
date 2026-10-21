#pragma once

class GrassShaders : public ShaderCollection
{
public:
	GrassShaders() : ShaderCollection("Grass") {};

	struct GrassStruct {
		D3DXVECTOR4		Brightness;		// x: multiplies the lit grass colour (before fog), y: the night brightness on the sun and ambient (not lamps)
		D3DXVECTOR4		Bend;			// xyz: the bend origin (camera-relative world, as GetShadowWorldPos rebuilds positions), w: 1 / reach
		D3DXVECTOR4		BendParams;		// x: push per unit of blade height (strength / 90 * 0.5), w: 1 for the debug tint
		D3DXVECTOR4		LOD;			// x: pixels per unit at a depth of 1, y: MinPixels, z: FadePixels, w: 1 when on
		D3DXVECTOR4		LightData;		// x: lamps in LightPosition (0: none, the shader skips them), y: Strength
	};
	GrassStruct	Constants;
	float		NightBrightness = 1.0f;	// [Shaders.Grass.Main] NightBrightness, eased in by the day/night transition (exteriors)

	// Lamps on the grass ([Shaders.Grass.Lights]): placed lights and the Pip-Boy light, never the sun. The nearest of the
	// lights NVR tracks each frame (ShaderManager::GetNearbyLights), into pixel c160-c176 of GRASS23x000TMS.pso.
	static const int MaxGrassLights = 8;
	D3DXVECTOR4	LightPosition[MaxGrassLights];	// xyz: camera-relative world, as the grass rebuilds positions; w: radius
	D3DXVECTOR4	LightColor[MaxGrassLights];		// rgb: colour times dimmer
	struct LightSettings {
		bool	Enabled;
		int		MaxLights;
		float	Strength;
	};
	LightSettings	Lights = {};
	void	UpdateLights();

	// Grass bending away from the player, as There Stands The Grass NVSE does it (that plugin stands down when NVR owns the
	// grass shaders): within Radius of the player's feet the blades lean away, more the faster they move, and spring back
	// once they leave. Same settings, same defaults.
	struct InteractionSettings {
		bool	Enabled;
		float	Radius;				// reach around the player (units)
		float	StrengthStanding;	// push while standing; the blade tip gets half of it
		float	StrengthMax;		// push at full running speed
		float	SpeedForMax;		// the speed (units/s) reaching StrengthMax
		float	SpringBackSeconds;	// how quickly grass recovers when the player slows or leaves
		float	PositionLagSeconds;	// how tightly the bend centre follows the player
		bool	Debug;				// tint the grass the bend reaches red, log the push every two seconds
	};
	InteractionSettings	Interaction = {};

	// Grass fading by how big it looks rather than only how far it is, after Community Shaders' Grass Optimizations:
	// an instance shorter on screen than MinPixels is gone, fading in over FadePixels above that. Detailed meshes (many
	// vertices, as rocks) count as up to 1 + DetailStrength times smaller, so they go sooner. Instances gone are dropped
	// before they reach the pixel shader.
	struct LODSettings {
		bool	Enabled;
		float	MinPixels;
		float	FadePixels;
		float	DetailVertices;		// a mesh with this many vertices or more counts as fully detailed
		float	DetailStrength;
	};
	LODSettings	LOD = {};

	// Normal maps on the grass ([Shaders.Grass.NormalMaps]): a grass texture "foo.dds" with a "foo_n.dds" beside it (loose
	// or in a BSA) bends the sun's light per pixel around the grass's own lighting normal. Bound per shape on s1, with
	// GrassMaterial (pixel c147: x 1 when bound, y strength); grass without one is lit exactly as before.
	struct NormalMapSettings {
		bool	Enabled;
		float	Strength;
	};
	NormalMapSettings	NormalMaps = {};

	// The sun's highlight on the grass ([Shaders.Grass.NormalMaps] EnableSpecular, SpecularStrength, Glossiness), masked by the normal map's alpha where there is one:
	// GrassMaterial z strength (0 off), w glossiness.
	struct SpecularSettings {
		bool	Enabled;
		float	Strength;
		float	Glossiness;
	};
	SpecularSettings	Specular = {};

	NiPoint3	BendCentre = { 0.0f, 0.0f, 0.0f };	// world, lagging the player
	NiPoint3	LastPlayerPos = { 0.0f, 0.0f, 0.0f };
	float		Speed = 0.0f;						// this frame's, units/s
	float		Push = 0.0f;						// the strength, eased
	bool		Have = false;						// a live bend origin
	bool		HavePrev = false;					// a previous position to measure the speed from
	float		DebugClock = 0.0f;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	// Per grass shape: the mesh's radius and detail factor, and whether it stands still (rocks), into c250 of the grass
	// vertex shaders.
	void	SetBatchConstants(NiGeometry* Geometry, bool Static);
	// Every grass shape the game draws (the hooked per-geometry setup).
	static void	InstallHooks();
	void	OnGrassShape(NiGeometry* Geometry);
};
