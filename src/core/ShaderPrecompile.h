#pragma once

// Shader precompile: brings the shader cache up to date on all CPU threads at startup, instead of one shader at a
// time as the game asks for them (about 1 s each with d3dx9_43; 4-5 minutes after a change to a shared include).
//
// Start() (ShaderManager::Initialize, before the effects load) lists every effect and every game shader NVR would
// load, with exactly the paths and defines LoadEffect / LoadShader use (EffectRecord::EffectPaths/EffectMacros,
// ShaderRecord::ShaderPaths/AppendGlobalDefines, ShaderManager::ResolveCollection). Worker threads preprocess them
// all, then compile the stale ones, biggest first, into the same cache files the loaders read. d3dx9_43 preprocesses
// and compiles shaders and effects to byte-identical output on several threads at once (checked on all 282).
//
// The loaders then call Take() with their compiled path: it waits for that one job (not the others), hands back the
// preprocessed source (so the loader skips its own preprocess), and logs what the job did. A cache hit then loads
// the binary as before. A shader or effect that failed in the job is preprocessed and compiled again by its loader,
// which reports the error as it always has.
namespace ShaderPrecompile {
	void Start();
	bool Take(const char* CompiledPath, std::string& Preprocessed);
}
