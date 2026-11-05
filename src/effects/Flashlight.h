#pragma once

// The player's flashlight (the Pip-Boy light's key). UNOFFICIAL 2026-11-05 (ported from Vegas Shaders' 2026-11-04 restructure; user: "port
// over the new flashlight we did to PB NVR and get rid of the old code regarding flashlight, including flashlight beam"). This effect
// draws nothing itself (its Flashlight.fx is a stub so the effect loads and keeps its menu switch); each frame it places the light (on
// the camera, the head in third person, or the weapon), colours it with the Pip-Boy's own HUD colour and hands it to
// core/FlashlightDeferred.h, the spot light on the G-buffer (with its shadow map, ShadowManager::RenderShadowSpotlight). The game's
// Pip-Boy light is darkened while it is on. The old screen-space light, the FlashlightBeam shaft and the MaterialPass relight are in
// source\NVR-TestBed-backups\before_flashlight_port_20261105.
class FlashlightEffect : public EffectRecord
{
public:
	FlashlightEffect() : EffectRecord("Flashlight"), SpotLight(nullptr), spotLightActive(false), aimingHoldUntil(0.0) {};

	struct FlashlightSettingsStruct {	// [Shaders.Flashlight.Main]
		float		Dimmer;			// how bright the beam is at its centre, in the lamps' units (linear light)
		float		Distance;		// its reach
		bool		attachToWeapon;	// on the weapon instead of the camera (it rides the weapon while aiming either way)
		NiColor		Color;			// the Pip-Boy's HUD colour this frame (SystemColorManager "Pipboy")
		float		ConeAngle;		// the cone's outer half-angle, degrees (fixed)
		NiPoint3	Offset;			// from the weapon or camera, in its frame (fixed)
	};
	FlashlightSettingsStruct	Settings = {};
	// [Shaders.Flashlight.Deferred] (core/FlashlightDeferred.h): how the light pass draws it.
	struct DeferredSettingsStruct {
		bool	Shadows;		// the light's shadow map
		float	ShadowSoftness;	// PCF radius, in texels of a 512 map
		float	ShadowBias;		// share of the reach
		float	Falloff;		// > 0 a windowed inverse square, (1 - d^2/r^2)^2 / (1 + F d^2/r^2); 0 the lamps' 1 - d^2/r^2
		int		DebugView;		// 1 the light alone, 2 the shadow, 3 the normal
		bool	TestForceOn;	// test only: on as if the Pip-Boy light were on
	};
	DeferredSettingsStruct	Deferred = {};

	// The Pip-Boy light's own values while the flashlight darkens it, put back when the flashlight is off.
	NiPointLight*	hiddenPipBoyLight = nullptr;
	float			hiddenPipBoyDimmer = 0.0f;
	NiColor			hiddenPipBoySpec = NiColor(0, 0, 0);
	void			RestorePipBoyLight();

	NiSpotLight* SpotLight;
	bool	spotLightActive;	// true while the cone is lit
	double	aimingHoldUntil;	// real time the aiming latch holds until, see UpdateConstants

	void	UpdateConstants();
	void	UpdateSettings();
	bool	ShouldRender() { return false; }	// nothing drawn here (see above)
	void	PublishLightConstants(bool abActive);
};
