#pragma once

class ReShadeIntegration {
public:
	static void Initialize();
	static void RenderEffects(IDirect3DSurface9* OutputSurface);
	static void SetMenuGuardEffects(const char* list);

	static bool KeepDepthBound() { return Loaded || TheSettingManager->SettingsMain.Main.ReShadeDepthCompat; }

	static inline bool Loaded = false;
};
