#include "AudioTweaks.h"

#include <mutex>
#include <unordered_map>

namespace AudioTweaks {

	void(__thiscall* ListenerUpdate)(void*) = (void(__thiscall*)(void*))0x00AEA8B0;

	static const char* kSection = "Main.Main.Audio";
	static float sListenerRate = 30.0f;		// listener commits a second, 0: every frame
	static bool sSkipVolume = true;
	static UInt32 sCalls = 0;
	static LARGE_INTEGER sLastListener = {};

	// --- Volumes ------------------------------------------------------------------------------------------------------
	// A volume equal to the one the buffer last took is not sent again. Nothing is held or delayed: a version that held
	// each frame's last volume (AddRef'd until sent) froze and crashed the game, and gained little.

	typedef HRESULT(STDMETHODCALLTYPE* SetVolumeFn)(IDirectSoundBuffer*, LONG);
	typedef HRESULT(STDMETHODCALLTYPE* CreateFn)(IDirectSound8*, LPCDSBUFFERDESC, LPDIRECTSOUNDBUFFER*, LPUNKNOWN);
	typedef HRESULT(STDMETHODCALLTYPE* DuplicateFn)(IDirectSound8*, LPDIRECTSOUNDBUFFER, LPDIRECTSOUNDBUFFER*);

	static std::mutex sLock;										// sounds may also be set from the audio thread; never held across a DirectSound call
	static std::unordered_map<void*, LONG> sVolumes;				// buffer interface -> the volume it has
	static std::unordered_map<void**, SetVolumeFn> sSetVolume;		// patched vtable -> its own SetVolume
	static CreateFn sCreate = nullptr;
	static DuplicateFn sDuplicate = nullptr;
	static bool sInstalled = false;

	static void* PatchSlot(void** Vtbl, int Index, void* Hook) {
		DWORD old;
		if (!VirtualProtect(&Vtbl[Index], sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) return nullptr;
		void* original = Vtbl[Index];
		Vtbl[Index] = Hook;
		VirtualProtect(&Vtbl[Index], sizeof(void*), old, &old);
		return original;
	}

	static HRESULT STDMETHODCALLTYPE SetVolumeHook(IDirectSoundBuffer* Buffer, LONG Volume) {
		SetVolumeFn original = nullptr;
		{
			std::lock_guard<std::mutex> lock(sLock);
			auto vtbl = sSetVolume.find(*(void***)Buffer);
			if (vtbl != sSetVolume.end()) original = vtbl->second;
			if (sSkipVolume) {
				auto known = sVolumes.find(Buffer);
				if (known != sVolumes.end() && known->second == Volume) return DS_OK;
			}
		}
		if (!original) return DSERR_GENERIC;   // cannot happen: only patched vtables lead here
		const HRESULT result = original(Buffer, Volume);
		std::lock_guard<std::mutex> lock(sLock);
		if (SUCCEEDED(result)) sVolumes[Buffer] = Volume;
		else sVolumes.erase(Buffer);
		return result;
	}

	// A buffer DirectSound just handed out: whatever its address held before is forgotten (also for its
	// IDirectSoundBuffer8 interface, which the game keeps), and its vtable leads to SetVolumeHook.
	static void NewBuffer(IDirectSoundBuffer* Buffer) {
		if (!Buffer) return;
		IDirectSoundBuffer8* buffer8 = nullptr;
		Buffer->QueryInterface(IID_IDirectSoundBuffer8, (void**)&buffer8);
		{
			std::lock_guard<std::mutex> lock(sLock);
			for (void* item : { (void*)Buffer, (void*)buffer8 }) {
				if (!item) continue;
				sVolumes.erase(item);
				void** vtbl = *(void***)item;
				if (sSetVolume.find(vtbl) != sSetVolume.end() || vtbl[15] == (void*)&SetVolumeHook) continue;
				sSetVolume[vtbl] = (SetVolumeFn)vtbl[15];   // before patching: another thread may call in at once
				PatchSlot(vtbl, 15, (void*)&SetVolumeHook);
			}
		}
		if (buffer8) buffer8->Release();
	}

	static HRESULT STDMETHODCALLTYPE CreateHook(IDirectSound8* Sound, LPCDSBUFFERDESC Desc, LPDIRECTSOUNDBUFFER* Out, LPUNKNOWN Outer) {
		const HRESULT result = sCreate(Sound, Desc, Out, Outer);
		if (SUCCEEDED(result) && Out) NewBuffer(*Out);
		return result;
	}

	static HRESULT STDMETHODCALLTYPE DuplicateHook(IDirectSound8* Sound, LPDIRECTSOUNDBUFFER Source, LPDIRECTSOUNDBUFFER* Out) {
		const HRESULT result = sDuplicate(Sound, Source, Out);
		if (SUCCEEDED(result) && Out) NewBuffer(*Out);
		return result;
	}

	static void Install() {
		UInt8* audio = *(UInt8**)0x11F6D98;   // BSWin32Audio
		if (!audio) return;
		IDirectSound8* sound = *(IDirectSound8**)(audio + 0x38);
		if (!sound) return;
		sInstalled = true;
		void** vtbl = *(void***)sound;
		if (vtbl[3] == (void*)&CreateHook) return;
		sCreate = (CreateFn)PatchSlot(vtbl, 3, (void*)&CreateHook);
		sDuplicate = (DuplicateFn)PatchSlot(vtbl, 5, (void*)&DuplicateHook);
		Logger::Log("AudioTweaks: DirectSound buffer creation hooked (%s)", sCreate && sDuplicate ? "ok" : "FAILED");
	}

	// --- The listener ---------------------------------------------------------------------------------------------

	static void ReadSettings() {
		if (!TheSettingManager) return;
		sListenerRate = std::clamp(TheSettingManager->GetSettingF(kSection, "ListenerRate"), 0.0f, 1000.0f);
		sSkipVolume = TheSettingManager->GetSettingI(kSection, "SkipRedundantVolume") != 0;
	}

	void __fastcall ListenerUpdateHook(void* This, void* Edx) {
		if ((sCalls++ % 120) == 0) ReadSettings();
		if (!sInstalled) Install();
		if (sListenerRate > 0.0f) {
			static LARGE_INTEGER frequency = {};
			if (!frequency.QuadPart) QueryPerformanceFrequency(&frequency);
			LARGE_INTEGER now;
			QueryPerformanceCounter(&now);
			if (sLastListener.QuadPart && (double)(now.QuadPart - sLastListener.QuadPart) < (double)frequency.QuadPart / sListenerRate) return;
			sLastListener = now;
		}
		ListenerUpdate(This);
	}
}
