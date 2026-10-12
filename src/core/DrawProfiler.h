#pragma once

// Draw call profiler ([Main.Main.DrawProfiler]): every draw call the game and NVR send to the device,
// counted per frame with its primitives, split by what is being rendered at the time (the phase the
// render hooks mark) and by pixel shader. Shown in a corner of the screen, averaged over half a second,
// and written to the log every LogInterval seconds.
//
// The device's four draw calls (IDirect3DDevice9 vtable slots 81-84) are patched once the profiler is
// first switched on, chained to whatever was there before (the rain culling patches the same slots,
// Hooks/Shaders.cpp RainParticles, before or after, and is called through). Off, a draw costs one test.
namespace DrawProfiler {

	enum Phase {
		PhaseOther,         // anything no hook marks: the game's own passes, LOD, sky and water outside the world scene...
		PhaseWorld,         // the world scene (Main::RenderWorldSceneGraph)
		PhaseFirstPerson,   // the first-person arms and weapon
		PhaseReflections,   // the water's reflection
		PhaseShadows,       // NVR's shadow maps (sun cascades, ortho, lamps)
		PhaseEffects,       // NVR's post effects
		PhaseImageSpace,    // the game's own image-space passes (HDR, menus' blur...)
		PhaseInterface,     // the HUD, menus and the Pip-Boy
		PhaseOverlay,       // NVR's settings overlay and these numbers themselves
		PhaseCount
	};

	extern bool Active;   // [Main.Main.DrawProfiler] Enabled

	// Marks a phase for the draws inside a scope; the previous one comes back at its end.
	struct Scope {
		Phase Previous;
		explicit Scope(Phase P);
		~Scope();
	};

	// A pixel shader's name, for the shader list (NiD3DPixelShaderEx::SetupShader).
	void NameShader(void* Handle, const char* Name, bool Vanilla);

	// Once a frame (ImGuiManager::BuildUI): closes the frame's counts, installs the hooks the first
	// time the profiler is on, and draws the numbers.
	void Frame();
}
