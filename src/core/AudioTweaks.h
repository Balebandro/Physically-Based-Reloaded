#pragma once

// The game's audio update is a large share of the main thread in busy fights ([Main.Main.Performance] ListenerRate, SkipRedundantVolume): CpuSampler found it
// waiting inside DirectSound, which takes one lock (shared with its mixing thread) on every call.
//  - The listener (BSWin32AudioListener::UpdatePositionAndOrientation, 0xAEA8B0) sets its position and orientation and
//    calls CommitDeferredSettings every frame, recomputing every playing 3D sound: at most ListenerRate times a second.
//  - Every playing sound sets its volume every frame from several places (BSWin32GameSound::SetVolume, 0xAED660 ->
//    IDirectSoundBuffer::SetVolume): a volume equal to the buffer's last is not sent again (SkipRedundantVolume). The
//    last volume is kept per buffer and forgotten whenever DirectSound hands out a buffer (CreateSoundBuffer,
//    DuplicateSoundBuffer, patched in DirectSound's vtable), so a reused address always gets its first volume for real.
namespace AudioTweaks {
	extern void(__thiscall* ListenerUpdate)(void*);
	void __fastcall ListenerUpdateHook(void* This, void* Edx);
}
