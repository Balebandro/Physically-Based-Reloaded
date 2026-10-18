#pragma once

// A sampling profiler for the game's main thread ([Main.Main.CpuSampler]), to find what a crowded scene really costs
// (AI, animation, detection, physics, scripts, rendering) before changing any of it. While a capture runs, a thread of
// its own pauses the main thread about once a millisecond and copies its instruction pointer and the top of its stack;
// the return addresses found there say which functions it was inside. After Seconds, the counts go to
// NewVegasReloaded_cpu.txt beside the plugin, by address (the game's) or module and offset (anything else), to be
// matched to functions offline. Nothing is hooked; the game is untouched while no capture runs.
namespace CpuSampler {
	void Frame();			// RenderHook, on the main thread every frame: settings, starting and finishing captures
}
