#include "ShaderPrecompile.h"
#include <algorithm>
#include <atomic>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <filesystem>
#include <future>
#include <thread>

namespace ShaderPrecompile {

	struct Job {
		bool effect = false;
		std::string name;
		std::string sourcePath, preprocessedPath, compiledPath;
		ShaderTemplate defines;		// game shaders: template + global defines (string literals, safe on any thread)
		D3DXMACRO effectMacros[3];
		std::string source;			// preprocessed
		bool stale = false;
		std::vector<std::string> log;
		std::promise<void> done;
		std::shared_future<void> ready;
	};

	static std::mutex sMutex;
	static std::map<std::string, std::shared_ptr<Job>> sJobs;	// by compiled path, until taken
	static std::atomic<int> sCompiled(0), sStale(0);
	static std::atomic<bool> sFinished(false);
	static int sTotal = 0;
	static bool sSummaryLogged = false;
	static std::atomic<long long> sCompileMs(0);

	static bool ReadFile(const std::string& path, std::string& out) {
		std::ifstream file(path, std::ios::in | std::ios::binary);
		if (!file.is_open()) return false;
		out.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
		return true;
	}

	static void WriteFile(const std::string& path, const void* data, size_t size) {
		std::ofstream file(path, std::ios::out | std::ios::binary);
		file.write((const char*)data, size);
	}

	// Preprocesses, and finds out whether the cache is stale: the loaders' test (the cached preprocessed source
	// differs, or the binary is missing).
	static void Prepare(Job& job) {
		ID3DXBuffer* source = nullptr;
		ID3DXBuffer* errors = nullptr;
		const D3DXMACRO* macros = job.effect ? job.effectMacros : job.defines.Defines;
		if (SUCCEEDED(D3DXPreprocessShaderFromFileA(job.sourcePath.c_str(), macros, NULL, &source, &errors)) && source)
			job.source.assign((const char*)source->GetBufferPointer(), source->GetBufferSize());
		if (source) source->Release();
		if (errors) errors->Release();
		if (job.source.empty()) return;		// the loader preprocesses it again and reports the error

		std::string cached;
		job.stale = !ReadFile(job.preprocessedPath, cached) || cached != job.source || !std::filesystem::exists(job.compiledPath);
	}

	static void Compile(Job& job) {
		ID3DXBuffer* binary = nullptr;
		ID3DXBuffer* errors = nullptr;
		if (job.effect) {
			ID3DXEffectCompiler* compiler = nullptr;
			if (SUCCEEDED(D3DXCreateEffectCompiler(job.source.c_str(), (UINT)job.source.size(), NULL, NULL, NULL, &compiler, &errors)) && compiler) {
				if (errors) { errors->Release(); errors = nullptr; }
				compiler->CompileEffect(NULL, &binary, &errors);
				compiler->Release();
			}
		}
		else {
			const char* profile = strstr(job.name.c_str(), ".vso") ? "vs_3_0" : "ps_3_0";
			D3DXCompileShader(job.source.c_str(), (UINT)job.source.size(), NULL, NULL, "main", profile, NULL, &binary, &errors, NULL);
		}
		if (errors) {
			job.log.push_back((const char*)errors->GetBufferPointer());
			errors->Release();
		}
		if (binary) {
			WriteFile(job.compiledPath, binary->GetBufferPointer(), binary->GetBufferSize());
			WriteFile(job.preprocessedPath, job.source.data(), job.source.size());
			job.log.push_back(std::string(job.effect ? "Effect compiled (precompile): " : "Shader compiled (precompile): ") + job.compiledPath);
			binary->Release();
			sCompiled++;
		}
		// No binary: the loader finds the cache still stale and compiles (and reports) it itself.
	}

	// Runs FN over JOBS on WORKERS threads, each taking the next job.
	template <typename F> static void Parallel(std::vector<std::shared_ptr<Job>>& jobs, unsigned workers, F fn) {
		std::atomic<size_t> next(0);
		std::vector<std::thread> pool;
		for (unsigned t = 0; t < workers; t++)
			pool.emplace_back([&] { for (size_t i; (i = next++) < jobs.size();) fn(*jobs[i]); });
		for (auto& thread : pool) thread.join();
	}

	static void Run(std::vector<std::shared_ptr<Job>> jobs) {
		unsigned workers = std::thread::hardware_concurrency();
		workers = workers > 2 ? workers - 1 : 1;	// the main thread keeps loading meanwhile

		Parallel(jobs, workers, [](Job& job) { Prepare(job); });

		std::vector<std::shared_ptr<Job>> stale;
		for (auto& job : jobs) {
			if (job->stale) stale.push_back(job);
			else job->done.set_value();
		}
		sStale = (int)stale.size();
		// Biggest first: the slow ones (WetnessReflections, the terrain shaders) start at once rather than last.
		std::stable_sort(stale.begin(), stale.end(), [](const auto& a, const auto& b) { return a->source.size() > b->source.size(); });
		auto t0 = std::chrono::steady_clock::now();
		Parallel(stale, workers, [](Job& job) { Compile(job); job.done.set_value(); });
		sCompileMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
		sFinished = true;
	}

	static void AddJob(std::vector<std::shared_ptr<Job>>& jobs, std::shared_ptr<Job> job) {
		job->ready = job->done.get_future().share();
		if (sJobs.emplace(job->compiledPath, job).second) jobs.push_back(job);
	}

	static void AddShader(std::vector<std::shared_ptr<Job>>& jobs, const char* name, const char* subPath, const ShaderTemplate& shaderTemplate) {
		char source[MAX_PATH], preprocessed[MAX_PATH], compiled[MAX_PATH];
		if (!ShaderRecord::ShaderPaths(name, subPath, shaderTemplate, source, preprocessed, compiled)) return;
		auto job = std::make_shared<Job>();
		job->name = name;
		job->sourcePath = source;
		job->preprocessedPath = preprocessed;
		job->compiledPath = compiled;
		job->defines = shaderTemplate;
		ShaderRecord::AppendGlobalDefines(job->defines);
		AddJob(jobs, job);
	}

	// The "*.pso" / "*.vso" names of the shader sources in a folder.
	static std::vector<std::string> ShaderNames(const char* folder) {
		std::vector<std::string> names;
		std::error_code ec;
		for (auto& entry : std::filesystem::directory_iterator(folder, ec)) {
			std::string file = entry.path().filename().string();
			if (file.size() > 9 && (!file.compare(file.size() - 9, 9, ".pso.hlsl") || !file.compare(file.size() - 9, 9, ".vso.hlsl")))
				names.push_back(file.substr(0, file.size() - 5));
		}
		return names;
	}

	void Start() {
		std::vector<std::shared_ptr<Job>> jobs;

		// Effects: every effect source, with LoadEffect's paths and defines.
		std::error_code ec;
		for (auto& entry : std::filesystem::directory_iterator(EffectsPath, ec)) {
			std::string file = entry.path().filename().string();
			if (file.size() <= 8 || file.compare(file.size() - 8, 8, ".fx.hlsl")) continue;
			std::string name = file.substr(0, file.size() - 8);
			auto job = std::make_shared<Job>();
			job->effect = true;
			job->name = name;
			char source[MAX_PATH], preprocessed[MAX_PATH], compiled[MAX_PATH];
			if (!EffectRecord::EffectPaths(name.c_str(), source, preprocessed, compiled)) continue;
			job->sourcePath = source;
			job->preprocessedPath = preprocessed;
			job->compiledPath = compiled;
			EffectRecord::EffectMacros(job->effectMacros);
			AddJob(jobs, job);
		}

		// Game shaders: every name a collection has a template for, and every shader source on disk, resolved to its
		// collection and template as ShaderManager::LoadShader does (temporary collections: only their templates are
		// read), in the default, Exteriors and Interiors folders.
		ShaderManager::ShadersStruct collections{};
		collections.Water = new WaterShaders();
		collections.Tonemapping = new TonemappingShaders();
		collections.POM = new POMShaders();
		collections.PBR = new PBRShaders();
		collections.Sky = new SkyShaders();
		collections.Skin = new SkinShaders();
		collections.Grass = new GrassShaders();
		collections.Particles = new ParticleShaders();
		collections.Terrain = new TerrainShaders();
		collections.Wetness = new WetnessEffectsShaders();
		ShaderCollection* all[] = { collections.Water, collections.Tonemapping, collections.POM, collections.PBR, collections.Sky,
			collections.Skin, collections.Grass, collections.Particles, collections.Terrain, collections.Wetness };

		std::set<std::string> names;
		for (ShaderCollection* collection : all)
			for (auto& [name, shaderTemplate] : collection->Templates()) names.emplace(name);
		for (auto& name : ShaderNames(ShadersPath)) names.insert(name);
		for (auto& name : names) {
			ShaderCollection* collection = ShaderManager::ResolveCollection(name.c_str(), collections);
			if (!collection) continue;
			ShaderTemplate shaderTemplate = collection->GetTemplate(name.c_str());
			AddShader(jobs, name.c_str(), NULL, shaderTemplate);
			AddShader(jobs, name.c_str(), "Exteriors\\", shaderTemplate);
			AddShader(jobs, name.c_str(), "Interiors\\", shaderTemplate);
		}
		for (ShaderCollection* collection : all) delete collection;

		// The shadow map and Bink shaders (ShadowManager, BinkManager): no template.
		for (const char* subPath : { "Shadows\\", "Bink\\" }) {
			std::string folder = std::string(ShadersPath) + subPath;
			for (auto& name : ShaderNames(folder.c_str())) AddShader(jobs, name.c_str(), subPath, ShaderTemplate{});
		}

		sTotal = (int)jobs.size();
		Logger::Log("Shader precompile: %i shaders and effects, checked and compiled on %u threads.", sTotal,
			max(1u, std::thread::hardware_concurrency() > 2 ? std::thread::hardware_concurrency() - 1 : 1u));
		std::thread(Run, std::move(jobs)).detach();
	}

	bool Take(const char* CompiledPath, std::string& Preprocessed) {
		std::shared_ptr<Job> job;
		{
			std::lock_guard<std::mutex> lock(sMutex);
			auto found = sJobs.find(CompiledPath);
			if (found == sJobs.end()) return false;
			job = found->second;
			sJobs.erase(found);
		}
		job->ready.wait();
		for (auto& line : job->log) Logger::Log("%s", line.c_str());
		Preprocessed = std::move(job->source);

		if (sFinished && !sSummaryLogged) {
			sSummaryLogged = true;
			Logger::Log("Shader precompile: %i of %i were out of date, %i compiled in %.1f s.", sStale.load(), sTotal, sCompiled.load(),
				sCompileMs.load() / 1000.0f);
		}
		return !Preprocessed.empty();
	}
}
