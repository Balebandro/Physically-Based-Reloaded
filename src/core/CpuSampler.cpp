#include "CpuSampler.h"

#include <algorithm>
#include <atomic>
#include <thread>
#include <map>
#include <mutex>
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

	// Spikes: every sample is also kept with the frame it fell in, so the slowest frames can be written on their own
	// (NewVegasReloaded_cpu_spikes.txt, same layout). The sampler adds to sPending; Frame() hands it to the frame that
	// just ended. The lock is taken by the sampler only after it resumed the main thread.
	// Other threads the main thread waits for, sampled alongside it, each group to reports of its own
	// (NewVegasReloaded_cpu_<name>.txt and, for the slowest frames, NewVegasReloaded_cpu_<name>_spikes.txt):
	//   ai: the AI threads (AILinearTaskThreadManager at 0x11DFA50: pThreads[3], BSThread, thread id at +0x24), waited for
	//       by AILinearTaskThreadManager::WaitForThreads and WaitOnThreadStage.
	//   io: the background loader's threads (IOManager* at 0x1202D98: uiThreadCount +0x4C, ppThreads +0x50, BSTaskThread,
	//       thread id at +0x08), which hold the FaceGen lock the main thread waits on when it queues a head, and which
	//       IOManager::Pause waits for.
	static const UInt32 kGroups = 2;
	static const UInt32 kMaxGroupThreads = 8;
	struct ThreadGroup {
		const char* name;
		HANDLE threads[kMaxGroupThreads];
		std::unordered_map<UInt32, UInt32> self, inclusive;
		std::map<std::vector<UInt32>, UInt32> stacks;
		UInt32 samples;
		std::vector<std::vector<UInt32>> pending;
	};
	static ThreadGroup sGroups[kGroups] = { { "ai" }, { "io" } };

	struct FrameRecord {
		double ms;
		std::vector<std::vector<UInt32>> stacks;
		std::vector<std::vector<UInt32>> groupStacks[kGroups];
	};
	static std::mutex sPendingLock;
	static std::vector<std::vector<UInt32>> sPending;
	static std::vector<FrameRecord> sFrameRecords;

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

	// One sample of Thread: its instruction pointer, then the return addresses found on its stack, inner to outer.
	static bool Sample(HANDLE Thread, std::vector<UInt32>& Stack) {
		UInt32 returns[kMaxReturns];
		// Paused, the thread may hold the heap's lock: nothing here may allocate until it runs again.
		if (SuspendThread(Thread) == (DWORD)-1) return false;
		CONTEXT context = {};
		context.ContextFlags = CONTEXT_CONTROL;
		const bool gotContext = GetThreadContext(Thread, &context) != 0;
		SIZE_T copied = 0;
		if (gotContext) {
			// The stack above ESP is committed up to its base; a full copy fails only near the base.
			if (!ReadProcessMemory(GetCurrentProcess(), (void*)context.Esp, sStack, kStackBytes, &copied))
				if (!ReadProcessMemory(GetCurrentProcess(), (void*)context.Esp, sStack, 2048, &copied)) copied = 0;
		}
		ResumeThread(Thread);
		if (!gotContext) return false;

		UInt32 found = 0;
		const UInt32* words = (const UInt32*)sStack;
		for (UInt32 i = 0; i < copied / 4 && found < kMaxReturns; i++) {
			const UInt32 value = words[i];
			if (!IsReturnAddress(value)) continue;
			bool seen = false;
			for (UInt32 k = 0; k < found; k++) if (returns[k] == value) { seen = true; break; }
			if (!seen) returns[found++] = value;
		}
		Stack.clear();
		Stack.reserve(found + 1);
		Stack.push_back(context.Eip);
		for (UInt32 k = 0; k < found; k++) Stack.push_back(returns[k]);
		return true;
	}

	static void SamplerMain() {
		timeBeginPeriod(1);
		std::vector<UInt32> stack;
		while (sRunning) {
			Sleep(1);
			if (!Sample(sMainThread, stack)) { sFailed++; continue; }
			sSelf[stack[0]]++;
			for (size_t k = 1; k < stack.size(); k++) sInclusive[stack[k]]++;
			sStacks[stack]++;
			sSamples++;
			{
				std::lock_guard<std::mutex> lock(sPendingLock);
				sPending.push_back(stack);
			}
			for (ThreadGroup& group : sGroups)
				for (HANDLE thread : group.threads) {
					if (!thread || !Sample(thread, stack)) continue;
					group.self[stack[0]]++;
					for (size_t k = 1; k < stack.size(); k++) group.inclusive[stack[k]]++;
					group.stacks[stack]++;
					group.samples++;
					std::lock_guard<std::mutex> lock(sPendingLock);
					group.pending.push_back(stack);
				}
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

	static FILE* OpenBesidePlugin(const char* Name, char* Path) {
		HMODULE self = nullptr;
		GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&OpenBesidePlugin, &self);
		GetModuleFileNameA(self, Path, MAX_PATH);
		if (char* slash = strrchr(Path, '\\')) strcpy(slash + 1, Name);
		FILE* file = fopen(Path, "w");
		if (!file) Logger::Log("CpuSampler: could not write %s", Path);
		return file;
	}

	// The counts, the modules and the whole samples: the part both reports share (the call tree tools read it).
	static void WriteBody(FILE* file, const std::unordered_map<UInt32, UInt32>& self, const std::unordered_map<UInt32, UInt32>& inclusive,
		const std::map<std::vector<UInt32>, UInt32>& stacks, UInt32 samples) {
		auto dump = [&](const char* title, const std::unordered_map<UInt32, UInt32>& counts, size_t limit) {
			std::vector<std::pair<UInt32, UInt32>> sorted(counts.begin(), counts.end());
			std::sort(sorted.begin(), sorted.end(), [](auto& a, auto& b) { return a.second > b.second; });
			fprintf(file, "%s\n", title);
			for (size_t i = 0; i < sorted.size() && i < limit; i++)
				fprintf(file, "%7u %6.2f%%  %s\n", sorted[i].second, samples ? 100.0 * sorted[i].second / samples : 0.0, Describe(sorted[i].first).c_str());
			fprintf(file, "\n");
		};
		dump("== self (instruction pointer)", self, 600);
		dump("== inclusive (call sites on the stack: the call at the address before each)", inclusive, 3000);
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
		for (const auto& entry : stacks) {
			fprintf(file, "%u", entry.second);
			for (UInt32 address : entry.first) fprintf(file, " %X", address);
			fprintf(file, "\n");
		}
	}

	// The slowest frames on their own: those over SpikeMs, or (0) over the capture's 99th percentile and 1.5x its
	// median. Their samples only, in the same layout as the main report, and each such frame with its time.
	// Group: a thread group's samples (FrameRecord::groupStacks) instead of the main thread's (-1).
	static void WriteSpikes(double Median, double P99, int Group) {
		const double setting = TheSettingManager->GetSettingF(kSection, "SpikeMs");
		const double threshold = setting > 0.0 ? setting : max(P99, 1.5 * Median);
		auto samplesOf = [&](const FrameRecord& record) -> const std::vector<std::vector<UInt32>>& {
			return Group < 0 ? record.stacks : record.groupStacks[Group];
		};
		std::unordered_map<UInt32, UInt32> self, inclusive;
		std::map<std::vector<UInt32>, UInt32> stacks;
		UInt32 samples = 0, frames = 0;
		double spikeMs = 0.0;
		for (const FrameRecord& record : sFrameRecords) {
			if (record.ms < threshold) continue;
			frames++;
			spikeMs += record.ms;
			for (const auto& stack : samplesOf(record)) {
				self[stack[0]]++;
				for (size_t k = 1; k < stack.size(); k++) inclusive[stack[k]]++;
				stacks[stack]++;
				samples++;
			}
		}
		char name[64], path[MAX_PATH] = {};
		if (Group < 0) strcpy_s(name, "NewVegasReloaded_cpu_spikes.txt");
		else sprintf_s(name, "NewVegasReloaded_cpu_%s_spikes.txt", sGroups[Group].name);
		FILE* file = OpenBesidePlugin(name, path);
		if (!file) return;
		fprintf(file, "NVR CPU capture%s%s%s: %u samples (%u failed) over %u frames\n", Group < 0 ? "" : " (", Group < 0 ? "" : sGroups[Group].name,
			Group < 0 ? "" : " threads)", samples, 0u, frames);
		fprintf(file, "spike frames: %u of %u at or over %.2f ms (median %.2f, 99%% %.2f), %.1f ms in all\n", frames, sFrames, threshold, Median, P99, spikeMs);
		fprintf(file, "high-process actors: average %.1f, most %u\n\n", sFrames ? (double)sHighSum / sFrames : 0.0, sHighMax);
		fprintf(file, "== spike frames (frame number, ms, samples)\n");
		for (size_t i = 0; i < sFrameRecords.size(); i++)
			if (sFrameRecords[i].ms >= threshold)
				fprintf(file, "%6zu %8.2f %5zu\n", i, sFrameRecords[i].ms, samplesOf(sFrameRecords[i]).size());
		fprintf(file, "\n");
		WriteBody(file, self, inclusive, stacks, samples);
		fclose(file);
		Logger::Log("CpuSampler: %u spike frames (%u samples%s%s) written to %s", frames, samples, Group < 0 ? "" : ", ", Group < 0 ? "" : sGroups[Group].name, path);
	}

	static void WriteGroup(UInt32 Group) {
		const ThreadGroup& group = sGroups[Group];
		char name[64], path[MAX_PATH] = {};
		sprintf_s(name, "NewVegasReloaded_cpu_%s.txt", group.name);
		FILE* file = OpenBesidePlugin(name, path);
		if (!file) return;
		UInt32 threads = 0;
		for (HANDLE thread : group.threads) if (thread) threads++;
		fprintf(file, "NVR CPU capture (%s threads): %u samples (%u failed) over %u frames, %u threads\n", group.name, group.samples, 0u, sFrames, threads);
		fprintf(file, "(each thread sampled with the main thread; samples where a thread waits for work are counted too)\n");
		fprintf(file, "high-process actors: average %.1f, most %u\n\n", sFrames ? (double)sHighSum / sFrames : 0.0, sHighMax);
		WriteBody(file, group.self, group.inclusive, group.stacks, group.samples);
		fclose(file);
		Logger::Log("CpuSampler: %u %s thread samples written to %s", group.samples, group.name, path);
	}

	static void Write() {
		char path[MAX_PATH] = {};
		FILE* file = OpenBesidePlugin("NewVegasReloaded_cpu.txt", path);
		if (!file) return;

		std::sort(sFrameTimes.begin(), sFrameTimes.end());
		auto percentile = [](double p) { return sFrameTimes.empty() ? 0.0 : sFrameTimes[(size_t)((sFrameTimes.size() - 1) * p)]; };
		fprintf(file, "NVR CPU capture: %u samples (%u failed) over %u frames\n", sSamples, sFailed, sFrames);
		fprintf(file, "frame ms: average %.2f, median %.2f, 95%% %.2f, 99%% %.2f, worst %.2f\n",
			sFrames ? sFrameSum / sFrames : 0.0, percentile(0.5), percentile(0.95), percentile(0.99), sFrameMax);
		fprintf(file, "high-process actors: average %.1f, most %u\n\n", sFrames ? (double)sHighSum / sFrames : 0.0, sHighMax);
		WriteBody(file, sSelf, sInclusive, sStacks, sSamples);
		fclose(file);
		Logger::Log("CpuSampler: %u samples written to %s", sSamples, path);
		WriteSpikes(percentile(0.5), percentile(0.99), -1);
		for (UInt32 g = 0; g < kGroups; g++)
			if (sGroups[g].samples) {
				WriteGroup(g);
				WriteSpikes(percentile(0.5), percentile(0.99), (int)g);
			}
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
		sFrameRecords.clear();
		sPending.clear();
		// The groups' threads, opened anew each capture (the game may have made them since the last).
		for (ThreadGroup& group : sGroups) {
			group.self.clear();
			group.inclusive.clear();
			group.stacks.clear();
			group.pending.clear();
			group.samples = 0;
			for (HANDLE& thread : group.threads)
				if (thread) { CloseHandle(thread); thread = nullptr; }
		}
		auto open = [](ThreadGroup& group, UInt32 slot, DWORD id) {
			if (slot < kMaxGroupThreads && id && id != GetCurrentThreadId())
				group.threads[slot] = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, id);
		};
		for (UInt32 i = 0; i < 3; i++) {   // AILinearTaskThreadManager::pThreads[3], BSThread::uiThreadID at +0x24
			const UInt8* thread = *(const UInt8**)(0x11DFA50 + 4 * i);
			open(sGroups[0], i, thread ? *(const DWORD*)(thread + 0x24) : 0);
		}
		if (const UInt8* io = *(const UInt8**)0x1202D98) {   // IOManager: uiThreadCount +0x4C, ppThreads +0x50
			const UInt32 count = *(const UInt32*)(io + 0x4C);
			const UInt8* const* threads = *(const UInt8* const**)(io + 0x50);
			for (UInt32 i = 0; threads && i < count && i < kMaxGroupThreads; i++)
				open(sGroups[1], i, threads[i] ? *(const DWORD*)(threads[i] + 0x08) : 0);   // BSTaskThread::uiThreadID
		}
		for (const ThreadGroup& group : sGroups) {
			UInt32 opened = 0;
			for (HANDLE thread : group.threads) if (thread) opened++;
			Logger::Log("CpuSampler: %u %s thread(s) sampled too", opened, group.name);
		}
		sSeconds =std::clamp((double)TheSettingManager->GetSettingF(kSection, "Seconds"), 2.0, 120.0);
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
		{
			FrameRecord record;
			record.ms = frameMs;
			std::lock_guard<std::mutex> lock(sPendingLock);
			record.stacks.swap(sPending);
			for (UInt32 g = 0; g < kGroups; g++) record.groupStacks[g].swap(sGroups[g].pending);
			sFrameRecords.push_back(std::move(record));
		}
		const UInt32 high = *(UInt32*)(0x11E0E80 + 0x103B0);   // ProcessManager::numHighActors
		sHighSum += high;
		sHighMax = max(sHighMax, high);
		if (Seconds(sStart, now) >= sSeconds || !want) Finish();
	}
}
