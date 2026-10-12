#include "DrawProfiler.h"
#include "imgui.h"

#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>

namespace DrawProfiler {

	bool Active = false;

	static const char* const kPhaseNames[PhaseCount] = {
		"Other", "World", "First person", "Reflections", "Shadow maps", "NVR effects", "Game image space", "Interface", "Overlay",
	};

	static Phase sPhase = PhaseOther;

	// This frame's counts, and the window's (summed over the frames of half a second).
	struct Counts {
		UInt32 Draws[PhaseCount] = {};
		UInt64 Primitives[PhaseCount] = {};
	};
	static Counts sFrame;
	static Counts sWindow;
	static UInt32 sWindowFrames = 0;
	static std::unordered_map<void*, UInt32> sShaderDraws;   // pixel shader -> draws over the window
	static std::unordered_map<void*, std::string> sShaderNames;

	// What is shown: per-frame averages of the last window.
	struct Shown {
		float Draws[PhaseCount] = {};
		float Primitives[PhaseCount] = {};
		float TotalDraws = 0.0f;
		float TotalPrimitives = 0.0f;
		std::vector<std::pair<std::string, float>> Shaders;   // name, draws a frame
		bool Valid = false;
	};
	static Shown sShown;

	Scope::Scope(Phase P) : Previous(sPhase) { sPhase = P; }
	Scope::~Scope() { sPhase = Previous; }

	void NameShader(void* Handle, const char* Name, bool Vanilla) {
		if (!Active || !Handle || !Name) return;
		auto Found = sShaderNames.find(Handle);
		if (Found != sShaderNames.end()) return;
		sShaderNames.emplace(Handle, Vanilla ? std::string(Name) + " (vanilla)" : std::string(Name));
	}

	// --- the device's draw calls ---------------------------------------------------------------------
	typedef HRESULT (STDMETHODCALLTYPE* DrawPrimitiveFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT);
	typedef HRESULT (STDMETHODCALLTYPE* DrawIndexedPrimitiveFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT);
	typedef HRESULT (STDMETHODCALLTYPE* DrawPrimitiveUPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, CONST void*, UINT);
	typedef HRESULT (STDMETHODCALLTYPE* DrawIndexedPrimitiveUPFn)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT, UINT, CONST void*, D3DFORMAT, CONST void*, UINT);
	static DrawPrimitiveFn sDrawPrimitive = nullptr;
	static DrawIndexedPrimitiveFn sDrawIndexedPrimitive = nullptr;
	static DrawPrimitiveUPFn sDrawPrimitiveUP = nullptr;
	static DrawIndexedPrimitiveUPFn sDrawIndexedPrimitiveUP = nullptr;
	static bool sInstalled = false;

	static void Count(IDirect3DDevice9* Device, UINT Primitives) {
		if (!Active) return;
		sFrame.Draws[sPhase]++;
		sFrame.Primitives[sPhase] += Primitives;
		IDirect3DPixelShader9* Shader = nullptr;
		Device->GetPixelShader(&Shader);
		sShaderDraws[Shader]++;
		if (Shader) Shader->Release();
	}

	static HRESULT STDMETHODCALLTYPE DrawPrimitiveHook(IDirect3DDevice9* Device, D3DPRIMITIVETYPE Type, UINT Start, UINT Count_) {
		Count(Device, Count_);
		return sDrawPrimitive(Device, Type, Start, Count_);
	}
	static HRESULT STDMETHODCALLTYPE DrawIndexedPrimitiveHook(IDirect3DDevice9* Device, D3DPRIMITIVETYPE Type, INT Base, UINT MinIndex, UINT Vertices, UINT Start, UINT Count_) {
		Count(Device, Count_);
		return sDrawIndexedPrimitive(Device, Type, Base, MinIndex, Vertices, Start, Count_);
	}
	static HRESULT STDMETHODCALLTYPE DrawPrimitiveUPHook(IDirect3DDevice9* Device, D3DPRIMITIVETYPE Type, UINT Count_, CONST void* Data, UINT Stride) {
		Count(Device, Count_);
		return sDrawPrimitiveUP(Device, Type, Count_, Data, Stride);
	}
	static HRESULT STDMETHODCALLTYPE DrawIndexedPrimitiveUPHook(IDirect3DDevice9* Device, D3DPRIMITIVETYPE Type, UINT MinIndex, UINT Vertices, UINT Count_, CONST void* Indices, D3DFORMAT Format, CONST void* Data, UINT Stride) {
		Count(Device, Count_);
		return sDrawIndexedPrimitiveUP(Device, Type, MinIndex, Vertices, Count_, Indices, Format, Data, Stride);
	}

	static void Install() {
		IDirect3DDevice9* Device = TheRenderManager ? TheRenderManager->device : nullptr;
		if (sInstalled || !Device) return;
		sInstalled = true;
		void** Vtbl = *(void***)Device;
		DWORD Old;
		VirtualProtect(&Vtbl[81], 4 * sizeof(void*), PAGE_EXECUTE_READWRITE, &Old);
		sDrawPrimitive = (DrawPrimitiveFn)Vtbl[81];
		sDrawIndexedPrimitive = (DrawIndexedPrimitiveFn)Vtbl[82];
		sDrawPrimitiveUP = (DrawPrimitiveUPFn)Vtbl[83];
		sDrawIndexedPrimitiveUP = (DrawIndexedPrimitiveUPFn)Vtbl[84];
		Vtbl[81] = (void*)DrawPrimitiveHook;
		Vtbl[82] = (void*)DrawIndexedPrimitiveHook;
		Vtbl[83] = (void*)DrawPrimitiveUPHook;
		Vtbl[84] = (void*)DrawIndexedPrimitiveUPHook;
		VirtualProtect(&Vtbl[81], 4 * sizeof(void*), Old, &Old);
		Logger::Log("DrawProfiler: device draw calls hooked");
	}

	// --- the window, the numbers and the log -----------------------------------------------------------
	static void CloseWindow(int TopShaders) {
		Shown Next;
		if (sWindowFrames > 0) {
			const float PerFrame = 1.0f / (float)sWindowFrames;
			for (int p = 0; p < PhaseCount; p++) {
				Next.Draws[p] = sWindow.Draws[p] * PerFrame;
				Next.Primitives[p] = (float)sWindow.Primitives[p] * PerFrame;
				Next.TotalDraws += Next.Draws[p];
				Next.TotalPrimitives += Next.Primitives[p];
			}
			std::vector<std::pair<void*, UInt32>> Sorted(sShaderDraws.begin(), sShaderDraws.end());
			std::sort(Sorted.begin(), Sorted.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
			for (int i = 0; i < (int)Sorted.size() && i < TopShaders; i++) {
				std::string Name;
				auto Found = sShaderNames.find(Sorted[i].first);
				if (Found != sShaderNames.end()) Name = Found->second;
				else if (!Sorted[i].first) Name = "(no pixel shader)";
				else {
					char Buffer[48];
					snprintf(Buffer, sizeof(Buffer), "effect or unnamed %p", Sorted[i].first);
					Name = Buffer;
				}
				Next.Shaders.emplace_back(Name, Sorted[i].second * PerFrame);
			}
			Next.Valid = true;
		}
		sShown = std::move(Next);
		sWindow = Counts();
		sWindowFrames = 0;
		sShaderDraws.clear();
	}

	static void LogShown() {
		if (!sShown.Valid) return;
		Logger::Log("DrawProfiler: %.0f draws, %.0fk primitives a frame", sShown.TotalDraws, sShown.TotalPrimitives / 1000.0f);
		for (int p = 0; p < PhaseCount; p++)
			if (sShown.Draws[p] >= 0.5f)
				Logger::Log("DrawProfiler:   %-17s %6.0f draws  %8.1fk primitives", kPhaseNames[p], sShown.Draws[p], sShown.Primitives[p] / 1000.0f);
		for (const auto& Shader : sShown.Shaders)
			Logger::Log("DrawProfiler:   shader %-32s %6.0f draws", Shader.first.c_str(), Shader.second);
	}

	static void Draw(int Corner) {
		if (!sShown.Valid) return;
		std::vector<std::string> Lines;
		char Line[160];
		snprintf(Line, sizeof(Line), "Draw calls %.0f   primitives %.0fk", sShown.TotalDraws, sShown.TotalPrimitives / 1000.0f);
		Lines.emplace_back(Line);
		for (int p = 0; p < PhaseCount; p++) {
			if (sShown.Draws[p] < 0.5f) continue;
			snprintf(Line, sizeof(Line), "  %-17s %5.0f  %7.1fk", kPhaseNames[p], sShown.Draws[p], sShown.Primitives[p] / 1000.0f);
			Lines.emplace_back(Line);
		}
		if (!sShown.Shaders.empty()) Lines.emplace_back("Top pixel shaders (draws a frame)");
		for (const auto& Shader : sShown.Shaders) {
			snprintf(Line, sizeof(Line), "  %5.0f  %s", Shader.second, Shader.first.c_str());
			Lines.emplace_back(Line);
		}

		const float LineHeight = ImGui::GetTextLineHeight();
		float Width = 0.0f;
		for (const auto& Text : Lines) Width = max(Width, ImGui::CalcTextSize(Text.c_str()).x);
		const float Height = LineHeight * Lines.size();
		const ImVec2 Display = ImGui::GetIO().DisplaySize;
		const float Margin = 8.0f;
		// Below the frame counter when they share a corner.
		const float Offset = LineHeight + 10.0f;
		ImVec2 Pos((Corner & 1) ? Display.x - Width - Margin : Margin, (Corner & 2) ? Display.y - Height - Margin - Offset : Margin + Offset);

		ImDrawList* List = ImGui::GetForegroundDrawList();
		List->AddRectFilled(ImVec2(Pos.x - 4.0f, Pos.y - 2.0f), ImVec2(Pos.x + Width + 4.0f, Pos.y + Height + 2.0f), IM_COL32(0, 0, 0, 160), 3.0f);
		for (size_t i = 0; i < Lines.size(); i++) {
			bool Heading = i == 0 || Lines[i][0] != ' ';
			List->AddText(ImVec2(Pos.x, Pos.y + LineHeight * i), Heading ? IM_COL32(240, 220, 140, 255) : IM_COL32(225, 225, 225, 255), Lines[i].c_str());
		}
	}

	void Frame() {
		const char* Section = "Main.Main.DrawProfiler";
		bool Enabled = TheSettingManager && TheSettingManager->GetSettingI(Section, "Enabled") != 0;
		if (Enabled && !Active) {
			// Switched on: start clean.
			sFrame = Counts();
			sWindow = Counts();
			sWindowFrames = 0;
			sShaderDraws.clear();
			sShown = Shown();
		}
		Active = Enabled;
		if (!Active) return;
		Install();

		for (int p = 0; p < PhaseCount; p++) {
			sWindow.Draws[p] += sFrame.Draws[p];
			sWindow.Primitives[p] += sFrame.Primitives[p];
		}
		sFrame = Counts();
		sWindowFrames++;

		static LARGE_INTEGER Frequency = {}, WindowStart = {}, LogStart = {};
		if (!Frequency.QuadPart) QueryPerformanceFrequency(&Frequency);
		LARGE_INTEGER Now;
		QueryPerformanceCounter(&Now);
		if (!WindowStart.QuadPart) WindowStart = LogStart = Now;
		const double WindowMs = 1000.0 * (double)(Now.QuadPart - WindowStart.QuadPart) / (double)Frequency.QuadPart;
		if (WindowMs >= 500.0) {
			CloseWindow(std::clamp(TheSettingManager->GetSettingI(Section, "TopShaders"), 0, 30));
			WindowStart = Now;
			const float LogInterval = TheSettingManager->GetSettingF(Section, "LogInterval");
			const double LogSeconds = (double)(Now.QuadPart - LogStart.QuadPart) / (double)Frequency.QuadPart;
			if (LogInterval > 0.0f && LogSeconds >= LogInterval) {
				LogShown();
				LogStart = Now;
			}
		}

		Draw(std::clamp(TheSettingManager->GetSettingI(Section, "Position"), 0, 3));
	}
}
