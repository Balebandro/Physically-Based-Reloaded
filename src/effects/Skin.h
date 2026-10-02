#pragma once

// NVR's skin shader: every vanilla SKIN20xx shader comes from SkinTemplate.hlsl, lit by
// Includes/SkinLighting.hlsl (spherical-Gaussian subsurface scattering, transmission,
// dual-lobe specular, sky light). Self-contained: it does not need, and overrides, any other
// skin mod's shaders.
class SkinShaders : public ShaderCollection
{
public:
	SkinShaders() : ShaderCollection("Skin") {};

	struct SkinStruct {
		D3DXVECTOR4		Data;        // x SpecularStrength, y Roughness, z PerPixelWidth ([Shaders.Skin.Scattering]), w Translucency
		D3DXVECTOR4		ExtraData;   // x SkyReflectionScale (0 indoors), y wetness (rain x RainWetness), z ShadowScatter, w VanillaMatchedHighlights
	};
	SkinStruct Constants;

	// [Shaders.Skin.Main] settings applied per frame.
	float SkyReflectionScale = 1.0f;
	float RainWetness = 0.5f;

	// Vanilla's variants, from the vanilla shaders' own constants and inputs
	// (shaderpackage010.sdp); see SkinTemplate.hlsl. Vertex shaders come in pairs: static, then
	// bone-skinned.
	std::map<std::string_view, ShaderTemplate> Templates() {
		return std::map<std::string_view, ShaderTemplate>{
			// ADTS: sun (+ projected shadow), fog and vertex colour.
			{ "SKIN2000.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}} } },
			{ "SKIN2001.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"SKIN", ""}} } },
			{ "SKIN2002.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2003.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"PROJ_SHADOW", ""}, {"SKIN", ""}} } },
			{ "SKIN2004.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"POINTS", "1"}} } },
			{ "SKIN2005.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"POINTS", "1"}, {"SKIN", ""}} } },
			{ "SKIN2006.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2007.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}, {"SKIN", ""}} } },
			// AD: light only, the engine applies the texture afterwards.
			{ "SKIN2008.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}} } },
			{ "SKIN2009.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}, {"SKIN", ""}} } },
			{ "SKIN2010.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2011.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}, {"SKIN", ""}} } },
			{ "SKIN2012.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}} } },
			{ "SKIN2013.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}, {"SKIN", ""}} } },
			{ "SKIN2014.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2015.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}, {"PROJ_SHADOW", ""}, {"SKIN", ""}} } },
			// DiffusePt: point lights only.
			{ "SKIN2016.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"DIFFUSE", ""}, {"POINTS", "2"}} } },
			{ "SKIN2017.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"DIFFUSE", ""}, {"POINTS", "2"}, {"SKIN", ""}} } },
			{ "SKIN2018.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"DIFFUSE", ""}, {"POINTS", "3"}} } },
			{ "SKIN2019.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"DIFFUSE", ""}, {"POINTS", "3"}, {"SKIN", ""}} } },
			// ADTS10: sun + up to 4 point lights, live count in EmittanceColor.a.
			{ "SKIN2020.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "4"}} } },
			{ "SKIN2021.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "4"}, {"SKIN", ""}} } },
			{ "SKIN2022.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "3"}} } },
			{ "SKIN2023.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "3"}, {"SKIN", ""}} } },
			{ "SKIN2024.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "1"}} } },
			{ "SKIN2025.vso", ShaderTemplate{ "SkinTemplate", {{"VS", ""}, {"MANY", ""}, {"POINTS", "1"}, {"SKIN", ""}} } },

			{ "SKIN2000.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}} } },
			{ "SKIN2001.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2002.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"POINTS", "1"}} } },
			{ "SKIN2003.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2004.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}} } },
			{ "SKIN2005.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "1"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2006.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}} } },
			{ "SKIN2007.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"ONLY_LIGHT", ""}, {"POINTS", "2"}, {"PROJ_SHADOW", ""}} } },
			{ "SKIN2008.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"DIFFUSE", ""}, {"POINTS", "2"}} } },
			{ "SKIN2009.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"DIFFUSE", ""}, {"POINTS", "3"}} } },
			{ "SKIN2010.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"MANY", ""}, {"POINTS", "4"}} } },
			{ "SKIN2011.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"MANY", ""}, {"POINTS", "3"}} } },
			{ "SKIN2012.pso", ShaderTemplate{ "SkinTemplate", {{"PS", ""}, {"MANY", ""}, {"POINTS", "1"}} } },
		};
	};

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
};
