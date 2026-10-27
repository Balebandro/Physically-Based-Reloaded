#pragma once

// A sampling profiler for the game's main thread ([Main.Main.CpuSampler]), to find what a crowded scene really costs
// (AI, animation, detection, physics, scripts, rendering) before changing any of it. While a capture runs, a thread of
// its own pauses the main thread about once a millisecond and copies its instruction pointer and the top of its stack;
// the return addresses found there say which functions it was inside. After Seconds, the counts go to
// NewVegasReloaded_cpu.txt beside the plugin, by address (the game's) or module and offset (anything else), to be
// matched to functions offline. The slowest frames' samples also go, on their own, to NewVegasReloaded_cpu_spikes.txt
// (SpikeMs). The game's AI threads and background loader (IO) threads are sampled alongside (NewVegasReloaded_cpu_ai.txt
// and _io.txt, and their slowest frames in _ai_spikes.txt and _io_spikes.txt). Nothing is hooked; the game is untouched
// while no capture runs.
namespace CpuSampler {
	void Frame();			// RenderHook, on the main thread every frame: settings, starting and finishing captures
}
