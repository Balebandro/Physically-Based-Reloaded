#pragma once

class RainEffect : public EffectRecord
{
public:
	RainEffect() : EffectRecord("Precipitations") {
		Constants.Data = D3DXVECTOR4(0, 0, 0, 0);
		Constants.RainAnimator.Initialize(0);
	};

	struct RainStruct {
		Animator		RainAnimator;
		D3DXVECTOR4		Data;
		D3DXVECTOR4		Aspect;
	};
	RainStruct	Constants;

	// Rain ([Shaders.WetnessEffects.Rain]): part of Wetness Effects, which switches all of it with its own
	// Enabled (ApplySwitch, every frame). The flags below are the effective ones: the setting, and the switch.
	//
	// Rain particle meshes: the game's own rain (3D Rain's strip particles, Honest Hearts' rain), drawn by
	// its NoLighting shaders, culled under cover with NVR's top-down ortho map (Hooks/Shaders.cpp,
	// RainParticles).
	bool						CullParticles = false;
	std::vector<std::string>	ParticleRoots;		// mesh root (or ancestor) node names that mark rain, lower case
	DWORD						LastParticleDraw = 0;	// GetTickCount of the last rain particle draw
	bool	ParticlesDrawnRecently() const { return CullParticles && LastParticleDraw && GetTickCount() - LastParticleDraw < 2000; }

	// RemovePrecipitations: no vanilla rain or snow. The sky's own precipitation
	// is neither updated nor drawn, and the rain meshes the rain scripts place on the player (RainMeshRoots)
	// are not drawn either (Hooks/Shaders.cpp). Applied and undone live, every frame.
	bool	RemoveVanilla = false;
	void	ApplyVanillaPrecipitations();

	// NVR's own rain (UseRainMesh): a rain mesh (3D Rain's, by default) loaded by NVR, kept on the player and
	// animated while the weather rains -- whatever the game's own rain scripts do. It is culled under cover
	// like any rain mesh, and RemovePrecipitations leaves it alone.
	bool		UseRainMesh = false;
	bool		ForceRain = false;			// rain whatever the weather (testing, or a load order with no rainy weather); wets the world too
	char		RainMeshPath[MAX_PATH] = "";
	NiNode*		OwnRainRoot = nullptr;		// the loaded copy; never freed
	void		UpdateRainMesh();

	// The Wetness Effects switch, every frame (ShaderManager::UpdateConstants): the effective flags above
	// from the settings. Off, the game's rain is left exactly as the game draws it.
	void		ApplySwitch(bool On);
private:
	bool	settingCull = false;
	bool	settingRemove = false;
	bool	settingMesh = false;
	bool	settingForce = false;
	bool	vanillaPatched = false;
	NiNode*	culledNodes[2] = {};	// the sky precipitation nodes this hid (only those: never un-hide what the game hid)
	bool	rainMeshFailed = false;
	bool	rainMeshAttached = false;
	float	rainMeshTime = 0.0f;
	bool	IsRainingNow();
public:

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();
};