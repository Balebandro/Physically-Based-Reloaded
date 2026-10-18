#include "CpuSampler.h"

#include <algorithm>
#include <atomic>
#include <thread>
#include <map>
#include <psapi.h>
#include <unordered_map>
#include <vector>
#include <mmsystem.h>

#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "psapi.lib")

namespace CpuSampler {

	static const char* kSection = "Main.Main.CpuSampler";
	static const UInt32 kStackBytes = 16384;	// the top of the main thread's stack copied per sample
	static const UInt32 kMaxReturns = 64;		// return addresses kept per sample (innermost first)

	static HANDLE sMainThread = nullptr;
	static std::thread* sThread = nullptr;		// never a static object: quitting mid-capture must not run its destructor
	static std::atomic<bool> sRunning{ false };
	static bool sArmed = true;					// Capture must go back to false before it starts another
	static UInt32 sTextStart = 0, sTextEnd = 0;	// FalloutNV.exe's code
	static UInt8 sStack[kStackBytes];			// written only by the sampler thread

	static std::unordered_map<UInt32, UInt32> sSelf;		// instruction pointer -> samples
	static std::unordered_map<UInt32, UInt32> sInclusive;	// return address (call site) -> samples it was on the stack
	static std::map<std::vector<UInt32>, UInt32> sStacks;	// whole samples: the instruction pointer, then return addresses inner to outer
	static UInt32 sSamples = 0, sFailed = 0;

	// Frames while capturing, on the main thread.
	static LARGE_INTEGER sStart = {}, sLastFrame = {};
	static double sSeconds = 10.0;
	static UInt32 sFrames = 0, sHighSum = 0, sHighMax = 0;
	static double sFrameSum = 0.0, sFrameMax = 0.0;
	static std::vector<double> sFrameTimes;

	static double Seconds(LARGE_INTEGER From, LARGE_INTEGER To) {
		static LARGE_INTEGER frequency = {};
		if (!frequency.QuadPart) QueryPerformanceFrequency(&frequency);
		return (double)(To.QuadPart - From.QuadPart) / (double)frequency.QuadPart;
	}

	static void FindText() {
		const UInt8* base = (const UInt8*)GetModuleHandleA(NULL);
		const IMAGE_DOS_HEADER* dos = (const IMAGE_DOS_HEADER*)base;
		const IMAGE_NT_HEADERS* nt = (const IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
		const IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
		for (UInt32 i = 0; i < nt->FileHeader.NumberOfSections; i++, section++)
			if (!memcmp(section->Name, ".text", 5)) {
				sTextStart = (UInt32)base + section->VirtualAddress;
				sTextEnd = sTextStart + section->Misc.VirtualSize;
				return;
			}
	}

	// Whether the bytes before Address are a call: E8 rel32, or FF /2 (register, [reg+disp8], [disp32]/[reg+disp32],
	// and those with a SIB byte).
	static bool IsReturnAddress(UInt32 Address) {
		if (Address < sTextStart + 8 || Address >= sTextEnd) return false;
		const UInt8* p = (const UInt8*)Address;
		if (p[-5] == 0xE8) return true;
		auto callModRM = [](UInt8 ModRM) { return ((ModRM >> 3) & 7) == 2; };
		if (p[-2] == 0xFF && callModRM(p[-1]) && (p[-1] & 0xC0) == 0xC0) return true;							// call reg
		if (p[-3] == 0xFF && callModRM(p[-2]) && (p[-2] & 0xC0) == 0x40 && (p[-2] & 7) != 4) return true;		// call [reg+disp8]
		if (p[-4] == 0xFF && callModRM(p[-3]) && (p[-3] & 0xC0) == 0x40 && (p[-3] & 7) == 4) return true;		// call [sib+disp8]
		if (p[-6] == 0xFF && callModRM(p[-5]) && ((p[-5] & 0xC7) == 0x05 || ((p[-5] & 0xC0) == 0x80 && (p[-5] & 7) != 4))) return true;	// call [disp32] / [reg+disp32]
		if (p[-7] == 0xFF && callModRM(p[-6]) && (p[-6] & 0xC0) == 0x80 && (p[-6] & 7) == 4) return true;		// call [sib+disp32]
		return false;
	}

	static void SamplerMain() {
		timeBeginPeriod(1);
		UInt32 returns[kMaxReturns];
		while (sRunning) {
			Sleep(1);
			// Paused, the main thread may hold the heap's lock: nothing here may allocate until it runs again.
			if (SuspendThread(sMainThread) == (DWORD)-1) { sFailed++; continue; }
			CONTEXT context = {};
			context.ContextFlags = CONTEXT_CONTROL;
			const bool gotContext = GetThreadContext(sMainThread, &context) != 0;
			SIZE_T copied = 0;
			if (gotContext) {
				// The stack above ESP is committed up to its base; a full copy fails only near the base.
				if (!ReadProcessMemory(GetCurrentProcess(), (void*)context.Esp, sStack, kStackBytes, &copied))
					if (!ReadProcessMemory(GetCurrentProcess(), (void*)context.Esp, sStack, 2048, &copied)) copied = 0;
			}
			ResumeThread(sMainThread);
			if (!gotContext) { sFailed++; continue; }

			UInt32 found = 0;
			const UInt32* words = (const UInt32*)sStack;
			for (UInt32 i = 0; i < copied / 4 && found < kMaxReturns; i++) {
				const UInt32 value = words[i];
				if (!IsReturnAddress(value)) continue;
				bool seen = false;
				for (UInt32 k = 0; k < found; k++) if (returns[k] == value) { seen = true; break; }
				if (!seen) returns[found++] = value;
			}
			sSelf[context.Eip]++;
			{
				std::vector<UInt32> stack;
				stack.reserve(found + 1);
				stack.push_back(context.Eip);
				for (UInt32 k = 0; k < found; k++) stack.push_back(returns[k]);
				sStacks[stack]++;
			}
			for (UInt32 k = 0; k < found; k++) sInclusive[returns[k]]++;
			sSamples++;
		}
		timeEndPeriod(1);
	}

	static std::string Describe(UInt32 Address) {
		char text[MAX_PATH + 32];
		if (Address >= sTextStart && Address < sTextEnd) {
			snprintf(text, sizeof(text), "%08X", Address);
			return text;
		}
		HMODULE module = nullptr;
		char name[MAX_PATH] = "?";
		if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)Address, &module) && module) {
			GetModuleFileNameA(module, name, MAX_PATH);
			const char* slash = strrchr(name, '\\');
			snprintf(text, sizeof(text), "%s+%X", slash ? slash + 1 : name, Address - (UInt32)module);
		}
		else snprintf(text, sizeof(text), "%08X (no module)", Address);
		return text;
	}

	static void Write() {
		char path[MAX_PATH] = {};
		HMODULE self = nullptr;
		GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&Write, &self);
		GetModuleFileNameA(self, path, MAX_PATH);
		if (char* slash = strrchr(path, '\\')) strcpy(slash + 1, "NewVegasReloaded_cpu.txt");
		FILE* file = fopen(path, "w");
		if (!file) { Logger::Log("CpuSampler: could not write %s", path); return; }

		std::sort(sFrameTimes.begin(), sFrameTimes.end());
		auto percentile = [](double p) { return sFrameTimes.empty() ? 0.0 : sFrameTimes[(size_t)((sFrameTimes.size() - 1) * p)]; };
		fprintf(file, "NVR CPU capture: %u samples (%u failed) over %u frames\n", sSamples, sFailed, sFrames);
		fprintf(file, "frame ms: average %.2f, median %.2f, 95%% %.2f, 99%% %.2f, worst %.2f\n",
			sFrames ? sFrameSum / sFrames : 0.0, percentile(0.5), percentile(0.95), percentile(0.99), sFrameMax);
		fprintf(file, "high-process actors: average %.1f, most %u\n\n", sFrames ? (double)sHighSum / sFrames : 0.0, sHighMax);

		auto dump = [&](const char* title, const std::unordered_map<UInt32, UInt32>& counts, size_t limit) {
			std::vector<std::pair<UInt32, UInt32>> sorted(counts.begin(), counts.end());
			std::sort(sorted.begin(), sorted.end(), [](auto& a, auto& b) { return a.second > b.second; });
			fprintf(file, "%s\n", title);
			for (size_t i = 0; i < sorted.size() && i < limit; i++)
				fprintf(file, "%7u %6.2f%%  %s\n", sorted[i].second, sSamples ? 100.0 * sorted[i].second / sSamples : 0.0, Describe(sorted[i].first).c_str());
			fprintf(file, "\n");
		};
		dump("== self (instruction pointer)", sSelf, 600);
		dump("== inclusive (call sites on the stack: the call at the address before each)", sInclusive, 3000);
		// Whole samples, for an exact call tree offline (stale return addresses on the stack filtered by the chain), and
		// the modules, to name addresses outside the game.
		fprintf(file, "== modules (base size name)\n");
		{
			HMODULE modules[512];
			DWORD bytes = 0;
			if (EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &bytes))
				for (DWORD i = 0; i < bytes / sizeof(HMODULE) && i < 512; i++) {
					MODULEINFO info = {};
					char name[MAX_PATH] = "?";
					GetModuleInformation(GetCurrentProcess(), modules[i], &info, sizeof(info));
					GetModuleBaseNameA(GetCurrentProcess(), modules[i], name, MAX_PATH);
					fprintf(file, "%08X %08X %s\n", (UInt32)info.lpBaseOfDll, (UInt32)info.SizeOfImage, name);
				}
		}
		fprintf(file, "\n== stacks (samples: instruction pointer, then return addresses inner to outer)\n");
		for (const auto& entry : sStacks) {
			fprintf(file, "%u", entry.second);
			for (UInt32 address : entry.first) fprintf(file, " %X", address);
			fprintf(file, "\n");
		}
		fclose(file);
		Logger::Log("CpuSampler: %u samples written to %s", sSamples, path);
	}

	static void Start() {
		if (!sMainThread &&
			!DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &sMainThread,
				THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, 0)) {
			sMainThread = nullptr;
			Logger::Log("CpuSampler: cannot open the main thread");
			return;
		}
		if (!sTextStart) FindText();
		sSelf.clear();
		sInclusive.clear();
		sStacks.clear();
		sSamples = sFailed = 0;
		sFrames = sHighSum = sHighMax = 0;
		sFrameSum = sFrameMax = 0.0;
		sFrameTimes.clear();
		sSeconds = std::clamp((double)TheSettingManager->GetSettingF(kSection, "Seconds"), 2.0, 120.0);
		QueryPerformanceCounter(&sStart);
		sLastFrame = sStart;
		sRunning = true;
		sThread = new std::thread(SamplerMain);
		SetThreadPriority(sThread->native_handle(), THREAD_PRIORITY_HIGHEST);
		Logger::Log("CpuSampler: capturing for %.0f seconds", sSeconds);
		InterfaceManager->ShowMessage("NVR: CPU capture started");
	}

	static void Finish() {
		sRunning = false;
		if (sThread) {
			sThread->join();
			delete sThread;
			sThread = nullptr;
		}
		Write();
		InterfaceManager->ShowMessage("NVR: CPU capture saved");
	}

	void Frame() {
		if (!TheSettingManager) return;
		const bool want = TheSettingManager->GetSettingI(kSection, "Capture") != 0;
		if (!want) sArmed = true;
		if (want && sArmed && !sRunning) {
			sArmed = false;
			Start();
			return;
		}
		if (!sRunning) return;

		LARGE_INTEGER now;
		QueryPerformanceCounter(&now);
		const double frameMs = 1000.0 * Seconds(sLastFrame, now);
		sLastFrame = now;
		sFrames++;
		sFrameSum += frameMs;
		sFrameMax = max(sFrameMax, frameMs);
		sFrameTimes.push_back(frameMs);
		const UInt32 high = *(UInt32*)(0x11E0E80 + 0x103B0);   // ProcessManager::numHighActors
		sHighSum += high;
		sHighMax = max(sHighMax, high);
		if (Seconds(sStart, now) >= sSeconds || !want) Finish();
	}
}
