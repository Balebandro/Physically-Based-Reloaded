#include "GodRays.h"

void GodRaysEffect::UpdateConstants() {
	Constants.Data.z = std::lerp(nightMult, dayMult, TheShaderManager->GameState.transitionCurve);
	Constants.Ray.w = rayVisibility * sunGlareEnabled ? TheShaderManager->ShaderConst.sunGlare : 1.0;
}

void GodRaysEffect::UpdateSettings(){
	dayMult = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "DayMultiplier");
	nightMult = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "NightMultiplier");
	sunGlareEnabled = TheSettingManager->GetSettingI("Shaders.GodRays.Main", "SunGlareEnabled");

	Constants.Ray.x = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayIntensity");
	Constants.Ray.y = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayLength");
	Constants.Ray.z = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayDensity");
	rayVisibility = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "RayVisibility");
	Constants.RayColor.x = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayR");
	Constants.RayColor.y = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayG");
	Constants.RayColor.z = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "RayB");
	Constants.RayColor.w = TheSettingManager->GetSettingF("Shaders.GodRays.Coloring", "Saturate");
	Constants.Data.x = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "LightShaftPasses");
	Constants.Data.y = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "Luminance");
	Constants.Data.w = TheSettingManager->GetSettingF("Shaders.GodRays.Main", "TimeEnabled");
}

void GodRaysEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_GodRaysRay", &Constants.Ray);
	TheShaderManager->RegisterConstant("TESR_GodRaysRayColor", &Constants.RayColor);
	TheShaderManager->RegisterConstant("TESR_GodRaysData", &Constants.Data);
}

bool GodRaysEffect::ShouldRender() {
	return TheShaderManager->GameState.isExterior && !TheShaderManager->GameState.isUnderwater && TheShaderManager->GameState.dayLight > 0.5;
}

// The intermediate passes write only the top-left quarter and sample RenderedBuffer at most two texels past it,
// so a margin of 4 texels keeps every tap inside the copied rect. The last pass still copies the whole target.
bool GodRaysEffect::PartialCopyRect(IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, RECT* Rect) {
	D3DSURFACE_DESC targetDesc, renderedDesc;
	if (FAILED(RenderTarget->GetDesc(&targetDesc)) || FAILED(RenderedSurface->GetDesc(&renderedDesc))) return false;
	// the same rect addresses both surfaces, so only limit the copy when their sizes match
	if (targetDesc.Width != renderedDesc.Width || targetDesc.Height != renderedDesc.Height) return false;

	LONG right = (LONG)(targetDesc.Width / 2 + 4);
	LONG bottom = (LONG)(targetDesc.Height / 2 + 4);
	Rect->left = 0;
	Rect->top = 0;
	Rect->right = right < (LONG)targetDesc.Width ? right : (LONG)targetDesc.Width;
	Rect->bottom = bottom < (LONG)targetDesc.Height ? bottom : (LONG)targetDesc.Height;
	return true;
}