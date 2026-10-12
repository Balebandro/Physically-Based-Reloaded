#pragma once

// Wetness reflections: screen-space reflections on the water film and puddles Wetness Effects puts on
// the world. Run once the world is drawn (Effects/WetnessReflections.fx), on whatever is wet now; the
// wetness comes from WetnessEffectsShaders, which this needs on.
class WetnessReflectionsEffect : public EffectRecord
{
public:
	WetnessReflectionsEffect() : EffectRecord("WetnessReflections") {};

	struct WetnessReflectionsSettingsStruct {
		float	Strength;			// how much of the reflection replaces the sky's
		float	MaxDistance;		// how far a ray goes, in game units
		float	Thickness;			// how far behind a surface a ray may be and still hit it
		float	Steps;				// ray steps
		float	RoughnessCutoff;	// films rougher than this reflect only the sky
		float	EdgeFade;			// fade near the screen's edges, as a share of the screen
		float	MaxCameraDistance;	// no reflections on surfaces farther than this
		bool	DebugView;			// the reflections alone
	};
	WetnessReflectionsSettingsStruct	Settings;

	struct WetnessReflectionsStruct {
		D3DXVECTOR4	Data;		// x: strength, y: max distance, z: thickness, w: steps
		D3DXVECTOR4	Fade;		// x: roughness cutoff, y: edge fade, z: debug view, w: max camera distance
	};
	WetnessReflectionsStruct	Constants;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();
};
