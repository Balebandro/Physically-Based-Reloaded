#include <regex>
/*
* Class that wraps an effect shader, in order to load it/render it/set constants.
*/
EffectRecord::EffectRecord(const char* effectName) {

	Name = effectName;

	Effect = NULL;
	Enabled = false;
	renderTime = 0;
	constantUpdateTime = 0;
}

/*Shader Values arrays are freed in the superclass Destructor*/
EffectRecord::~EffectRecord() {
	if (Effect) Effect->Release();
}

/*
 * Unload effects, allowing it to be reloaded from  a blank state.
 */
void EffectRecord::DisposeEffect() {
	if (Effect) Effect->Release();
	Effect = nullptr;

	delete[] FloatShaderValues;
	FloatShaderValues = nullptr;
	FloatShaderValuesCount = 0;

	delete[] TextureShaderValues;
	TextureShaderValues = nullptr;
	TextureShaderValuesCount = 0;

	Enabled = false;
}

/*
The source and cache paths of an effect; false when its source is not there.
*/
bool EffectRecord::EffectPaths(const char* Name, char* SourcePath, char* PreprocessedPath, char* CompiledPath) {
	strcpy(SourcePath, EffectsPath);
	strcat(SourcePath, Name);
	strcat(SourcePath, ".fx.hlsl");

	strcpy(PreprocessedPath, EffectsPath);
	strcat(PreprocessedPath, "Cache\\");
	strcat(PreprocessedPath, Name);
	strcat(PreprocessedPath, ".fx.hlsl");

	strcpy(CompiledPath, EffectsPath);
	strcat(CompiledPath, "Cache\\");
	strcat(CompiledPath, Name);
	strcat(CompiledPath, ".fx");

	return FileExists(SourcePath);
}

/*
Effects get the same compile-time defines the game shaders do. Only the PREPROCESS call needs them --
D3DXCreateEffectCompiler is handed the already-preprocessed source. Toggling any of these changes that source,
so CheckPreprocessResult forces a recompile.
*/
void EffectRecord::EffectMacros(D3DXMACRO (&Macros)[3]) {
	int macroCount = 0;
	Macros[macroCount++] = { "FORWARD_SHADOWS",
		TheSettingManager->GetSettingI("Shaders.ShadowsExteriors.Main", "ForwardShadows") ? "1" : "0" };
	if (TheRenderManager->IsReversedDepth())
		Macros[macroCount++] = { "REVERSED_DEPTH", "" };
	Macros[macroCount] = { NULL, NULL };
}

/*
 * Compile and Load the Effect shader
 */
bool EffectRecord::LoadEffect() {
	auto timer = TimeLogger();
	bool success = false;

	ID3DXEffect* Effect = NULL;
	ID3DXEffectCompiler* Compiler = NULL;
	ID3DXBuffer* EffectSource = NULL;
	ID3DXBuffer* Errors = NULL;
	ID3DXBuffer* EffectBuffer = NULL;

	char EffectSourcePath[MAX_PATH];
	char EffectPreprocessedPath[MAX_PATH];
	char EffectCompiledPath[MAX_PATH];

	if (!EffectPaths(Name, EffectSourcePath, EffectPreprocessedPath, EffectCompiledPath)) {
		return success;
	}

	D3DXMACRO Macros[3];
	EffectMacros(Macros);

	// ShaderPrecompile has already preprocessed this effect on its threads (and compiled it into the cache if it was
	// stale): its source is taken as is, once that job is done.
	HRESULT prepass;
	std::string Precompiled;
	if (ShaderPrecompile::Take(EffectCompiledPath, Precompiled) && SUCCEEDED(D3DXCreateBuffer((DWORD)Precompiled.size(), &EffectSource))) {
		memcpy(EffectSource->GetBufferPointer(), Precompiled.data(), Precompiled.size());
		prepass = D3D_OK;
	}
	else
		prepass = D3DXPreprocessShaderFromFileA(EffectSourcePath, Macros, NULL, &EffectSource, &Errors);
	if (prepass == D3D_OK) {
		bool Compile = !CheckPreprocessResult(EffectPreprocessedPath, EffectSource);
		bool CompiledExists = FileExists(EffectCompiledPath);

		if (!Compile && CompiledExists) {
			HRESULT loaded = D3DXCreateEffectFromFileA(TheRenderManager->device, EffectCompiledPath, NULL, NULL, D3DXFX_LARGEADDRESSAWARE, NULL, &Effect, &Errors);
			if (FAILED(loaded)) {
				ReportError(loaded);
				if (Errors) Logger::Log((char*)Errors->GetBufferPointer());

				if (Effect) { Effect->Release(); Effect = NULL; }
				if (Errors) { Errors->Release(); Errors = NULL; }
			}

			if (Errors) Logger::Log((char*)Errors->GetBufferPointer());
			
			success = true;
		}

		if (Compile || !CompiledExists || !Effect) {
			// compile if option was enabled or compiled version not found
			HRESULT compiled = D3DXCreateEffectCompiler(
				(const char*)EffectSource->GetBufferPointer(), 
				EffectSource->GetBufferSize(), 
				NULL, 
				NULL, 
				NULL, 
				&Compiler, 
				&Errors
			);
			if (FAILED(compiled)) {
				ReportError(compiled);
				if (Errors) Logger::Log((char*)Errors->GetBufferPointer());
				if (Compiler) Compiler->Release();
				if (EffectSource) EffectSource->Release();
				if (Effect) Effect->Release();
				if (Errors) Errors->Release();
				Enabled = false;
				return success;
			}
			if (Errors) Logger::Log((char*)Errors->GetBufferPointer());

			compiled = Compiler->CompileEffect(NULL, &EffectBuffer, &Errors);
			if (FAILED(compiled)) {
				ReportError(compiled);
				if (Errors) Logger::Log((char*)Errors->GetBufferPointer());
				if (Compiler) Compiler->Release();
				if (EffectSource) EffectSource->Release();
				if (Effect) Effect->Release();
				if (Errors) Errors->Release();
				Enabled = false;
				return success;
			}
			if (Errors) Logger::Log((char*)Errors->GetBufferPointer());

			if (EffectBuffer) {
				std::ofstream FileBinary(EffectCompiledPath, std::ios::out | std::ios::binary);
				FileBinary.write((const char*)EffectBuffer->GetBufferPointer(), EffectBuffer->GetBufferSize());
				FileBinary.flush();
				FileBinary.close();

				std::ofstream FilePreprocess(EffectPreprocessedPath, std::ios::out | std::ios::binary);
				FilePreprocess.write((const char*)EffectSource->GetBufferPointer(), EffectSource->GetBufferSize());
				FilePreprocess.flush();
				FilePreprocess.close();

				Logger::Log("Effect compiled: %s", EffectPreprocessedPath);
			}

			HRESULT loaded = D3DXCreateEffectFromFileA(TheRenderManager->device, EffectCompiledPath, NULL, NULL, D3DXFX_LARGEADDRESSAWARE, NULL, &Effect, &Errors);
			if (FAILED(loaded)) {
				ReportError(loaded);
				if (Errors) Logger::Log((char*)Errors->GetBufferPointer());
				if (Compiler) Compiler->Release();
				if (EffectSource) EffectSource->Release();
				if (Effect) Effect->Release();
				if (Errors) Errors->Release();
				if (EffectBuffer) EffectBuffer->Release();
				Enabled = false;
				return success;
			}
			if (Errors) Logger::Log((char*)Errors->GetBufferPointer());

			success = true;
		}
	}
	else {
		ReportError(prepass);
		if (Errors) Logger::Log((char*)Errors->GetBufferPointer());
	}

	if (Effect) {
		this->Effect = Effect;
		CreateCT(EffectSource, NULL); //Create the object which will associate a register index to a float pointer for constants updates;
		Logger::Log("Effect loaded: %s", EffectCompiledPath);
	}

	// set enabled status of effect based on success and setting
	Enabled = Effect != nullptr && TheSettingManager->GetMenuShaderEnabled(Name);

	if (Compiler) Compiler->Release();
	if (Errors) Errors->Release();
	if (EffectBuffer) EffectBuffer->Release();
	if (EffectSource) EffectSource->Release();

	timer.LogTime("EffectRecord::LoadEffect");

	return success;
}


/**
* Loads an effect shader by name (The post process effects stored in the Effects folder)
* @param Name the name for the effect
* @returns an EffectRecord describing the effect shader.
*/
bool EffectRecord::IsLoaded() {
	return Effect != nullptr;
}


/**
Creates the Constant Table for the Effect Record.
*/
void EffectRecord::CreateCT(ID3DXBuffer* ShaderSource, ID3DXConstantTable* ConstantTable) {
	auto timer = TimeLogger();

	D3DXEFFECT_DESC ConstantTableDesc;
	D3DXPARAMETER_DESC ConstantDesc;
	D3DXHANDLE Handle;
	UINT ConstantCount = 1;
	UInt32 FloatIndex = 0;
	UInt32 TextureIndex = 0;

	Effect->GetDesc(&ConstantTableDesc);

	// The frame chain ([Main.Main.Performance] FrameChain, ShaderManager.h) writes each pass into a buffer that does
	// not hold the frame: a pass that leaves pixels untouched (clip, discard, blending, stencil, alpha test, a colour
	// write mask) gets the frame copied into its destination first. Effects that never read TESR_SourceBuffer are not
	// given a copy of the frame in it. Ported from NVR UNOFFICIAL Boutique.
	usesSourceBuffer = false;
	needsPrefill = true;
	if (ShaderSource && ShaderSource->GetBufferPointer()) {
		static const std::regex partialWrite(
			R"(\bclip\s*\(|\bdiscard\b|AlphaBlendEnable\s*=\s*(true|1)|StencilEnable\s*=\s*(true|1)|)"
			R"(ColorWriteEnable|SeparateAlphaBlendEnable\s*=\s*(true|1)|AlphaTestEnable\s*=\s*(true|1))",
			std::regex::icase | std::regex::optimize);
		std::string source((const char*)ShaderSource->GetBufferPointer(), ShaderSource->GetBufferSize());
		needsPrefill = std::regex_search(source, partialWrite);
	}
	if (needsPrefill) Logger::Log("%s: partial-write passes, the frame chain pre-fills their destination.", Name);
	for (UINT c = 0; c < ConstantTableDesc.Parameters; c++) {
		Handle = Effect->GetParameter(NULL, c);
		Effect->GetParameterDesc(Handle, &ConstantDesc);
		if (memcmp(ConstantDesc.Name, "TESR_", 5)) continue;
		if (!strcmp(ConstantDesc.Name, "TESR_SourceBuffer")) usesSourceBuffer = true;
		if ((ConstantDesc.Class == D3DXPC_VECTOR || ConstantDesc.Class == D3DXPC_MATRIX_ROWS)) FloatShaderValuesCount += 1;
		if (ConstantDesc.Class == D3DXPC_OBJECT && ConstantDesc.Type >= D3DXPT_SAMPLER && ConstantDesc.Type <= D3DXPT_SAMPLERCUBE) TextureShaderValuesCount += 1;
	}
	FloatShaderValues = new ShaderFloatValue[FloatShaderValuesCount];
	TextureShaderValues = new ShaderTextureValue[TextureShaderValuesCount];

	//Logger::Debug("CreateCT: Effect has %i constants", ConstantTableDesc.Parameters);

	for (UINT c = 0; c < ConstantTableDesc.Parameters; c++) {
		Handle = Effect->GetParameter(NULL, c);
		Effect->GetParameterDesc(Handle, &ConstantDesc);
		if (memcmp(ConstantDesc.Name, "TESR_", 5)) continue; // Only treat constants named with TESR prefix

		switch (ConstantDesc.Class) {
		case D3DXPC_VECTOR:
			FloatShaderValues[FloatIndex].Name = ConstantDesc.Name;
			FloatShaderValues[FloatIndex].Type = (D3DXPARAMETER_TYPE)D3DXPC_VECTOR;
			FloatShaderValues[FloatIndex].RegisterIndex = (UInt32)Handle;
			FloatShaderValues[FloatIndex].RegisterCount = ConstantDesc.Elements;
			FloatIndex++;
			break;
		case D3DXPC_MATRIX_ROWS:
			FloatShaderValues[FloatIndex].Name = ConstantDesc.Name;
			FloatShaderValues[FloatIndex].Type = (D3DXPARAMETER_TYPE)D3DXPC_MATRIX_ROWS;
			FloatShaderValues[FloatIndex].RegisterIndex = (UInt32)Handle;
			FloatShaderValues[FloatIndex].RegisterCount = ConstantDesc.Elements;
			FloatIndex++;
			break;
		case D3DXPC_OBJECT:
			if (ConstantDesc.Class == D3DXPC_OBJECT && ConstantDesc.Type >= D3DXPT_SAMPLER && ConstantDesc.Type <= D3DXPT_SAMPLERCUBE) {
				TextureShaderValues[TextureIndex].Name = ConstantDesc.Name;
				TextureShaderValues[TextureIndex].Type = TextureRecord::GetTextureType(ConstantDesc.Type);
				TextureShaderValues[TextureIndex].RegisterIndex = TextureIndex;
				TextureShaderValues[TextureIndex].RegisterCount = 1;
				TextureShaderValues[TextureIndex].GetSamplerStateString(ShaderSource, TextureIndex);
				TextureShaderValues[TextureIndex].GetTextureRecord();

				TextureIndex++;
			}
			break;
		}
	}

	timer.LogTime("EffectRecord::ConstantTableDesc");
}

/*
*Sets the Effect Shader constants table and texture registers.
*/
void EffectRecord::SetCT() {
	if (!Enabled || Effect == nullptr) return;

	ShaderTextureValue* Sampler;
	for (UInt32 c = 0; c < TextureShaderValuesCount; c++) {
		Sampler = &TextureShaderValues[c];
		if (Sampler->Texture->TextureRef) Sampler->Texture->Texture = *Sampler->Texture->TextureRef;   // follows the frame chain's buffers
		if (!Sampler->Texture->Texture) {
			Sampler->Texture->BindTexture(Sampler->Name);

			if (Sampler->Texture->Texture) Logger::Log("%s : Texture %s Succesfully bound", Name, Sampler->Name);
			//else Logger::Log("[ERROR] : Could not bind texture %s for effect %s", Sampler->Name, Name);
		}

		if (Sampler->Texture->Texture != nullptr) {
			TheRenderManager->device->SetTexture(Sampler->RegisterIndex, Sampler->Texture->Texture);
			for (int i = 1; i < SamplerStatesMax; i++) {
				TheRenderManager->SetSamplerState(Sampler->RegisterIndex, (D3DSAMPLERSTATETYPE)i, Sampler->Texture->SamplerStates[i]);
			}
		}
	}

	ShaderFloatValue* Constant;
	for (UInt32 c = 0; c < FloatShaderValuesCount; c++) {
		Constant = &FloatShaderValues[c];
		if (Constant->Value == nullptr)  Constant->GetValueFromConstantTable();
		if (Constant->Value == nullptr) {
			Logger::Log("[Error] %s : Couldn't get value for Constant %s", Name, Constant->Name);
			continue;
		}

		if (Constant->Type == (D3DXPARAMETER_TYPE)D3DXPC_VECTOR) {
			if (Constant->RegisterCount > 1)
				Effect->SetVectorArray((D3DXHANDLE)Constant->RegisterIndex, Constant->Value, Constant->RegisterCount);
			else
				Effect->SetVector((D3DXHANDLE)Constant->RegisterIndex, Constant->Value);
		}
		else
			if (Constant->RegisterCount > 1)
				Effect->SetMatrixArray((D3DXHANDLE)Constant->RegisterIndex, (D3DXMATRIX*)Constant->Value, Constant->RegisterCount);
			else
				Effect->SetMatrix((D3DXHANDLE)Constant->RegisterIndex, (D3DXMATRIX*)Constant->Value);
	}
}

// Between the passes of one effect the frame chain moves TESR_RenderedBuffer to the other buffer: the samplers that
// name a texture slot get what the slot holds now.
void EffectRecord::RebindSlotTextures() {
	for (UInt32 c = 0; c < TextureShaderValuesCount; c++) {
		ShaderTextureValue* Sampler = &TextureShaderValues[c];
		if (!Sampler->Texture || !Sampler->Texture->TextureRef || !*Sampler->Texture->TextureRef) continue;
		if (Sampler->Texture->Texture == *Sampler->Texture->TextureRef) continue;
		Sampler->Texture->Texture = *Sampler->Texture->TextureRef;
		TheRenderManager->device->SetTexture(Sampler->RegisterIndex, Sampler->Texture->Texture);
	}
}

/*
 * Enable or Disable Effect, with loading if not loaded
 */
bool EffectRecord::SwitchEffect() {
	bool change = true;
	if (!IsLoaded() && !Enabled) {
		Logger::Log("Effect %s is not loaded", Name);
		DisposeEffect();
		change = LoadEffect();
	}
	if (change) {
		Enabled = !Enabled;
	}
	else {
		char Message[256] = "Error: Couldn't enable effect ";
		strcat(Message, Name);

		InterfaceManager->ShowMessage(Message);
		Logger::Log(Message);
	}
	return Enabled;
}


/**
* Renders the given effect shader.
*/
void EffectRecord::Render(IDirect3DDevice9* Device, IDirect3DSurface9* RenderTarget, IDirect3DSurface9* RenderedSurface, UINT techniqueIndex, bool ClearRenderTarget, IDirect3DSurface9* SourceBuffer) {

	if (!Enabled || Effect == nullptr || !ShouldRender()) {
		renderTime = 0.0f;
		return; // skip rendering of disabled effects
	}

	auto timer = TimeLogger();

	// The frame chain: each pass draws into the buffer that does not hold the frame, which then becomes the frame. No
	// copy of the whole frame after every pass.
	FrameChain& chain = TheShaderManager->Chain;
	if (chain.Owns(RenderTarget, RenderedSurface)) {
		if (SourceBuffer && usesSourceBuffer && SourceBuffer != RenderTarget)
			Device->StretchRect(TheTextureManager->RenderedSurface, NULL, SourceBuffer, NULL, D3DTEXF_LINEAR);
		Effect->SetTechnique(Effect->GetTechnique(techniqueIndex));
		SetCT();
		UINT Passes = 0;
		if (SUCCEEDED(Effect->Begin(&Passes, NULL))) {
			const bool prefill = !ClearRenderTarget && needsPrefill;
			for (UINT p = 0; p < Passes; p++) {
				IDirect3DSurface9* destination = chain.Output();
				if (prefill) Device->StretchRect(TheTextureManager->RenderedSurface, NULL, destination, NULL, D3DTEXF_NONE);
				Device->SetRenderTarget(0, destination);
				if (ClearRenderTarget) Device->Clear(0L, NULL, D3DCLEAR_TARGET, D3DCOLOR_ARGB(255, 0, 0, 0), 1.0f, 0L);
				Effect->BeginPass(p);
				RebindSlotTextures();
				Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
				Effect->EndPass();
				chain.Commit();
			}
			Effect->End();
		}
		Device->SetRenderTarget(0, RenderTarget);
		std::string name = "EffectRecord::Render " + std::string(Name);
		renderTime = timer.LogTime(name.c_str());
		return;
	}

	if (SourceBuffer && usesSourceBuffer && SourceBuffer != RenderTarget)
		Device->StretchRect(RenderTarget, NULL, SourceBuffer, NULL, D3DTEXF_LINEAR);

	try {
		D3DXHANDLE technique = Effect->GetTechnique(techniqueIndex);
		Effect->SetTechnique(technique);
		SetCT(); // update the constant table
		UINT Passes;
		Effect->Begin(&Passes, NULL);
		for (UINT p = 0; p < Passes; p++) {
			if (ClearRenderTarget) Device->Clear(0L, NULL, D3DCLEAR_TARGET, D3DCOLOR_ARGB(255, 0, 0, 0), 1.0f, 0L);
			Effect->BeginPass(p);
			Device->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
			Effect->EndPass();
			if (RenderedSurface && RenderedSurface != RenderTarget) Device->StretchRect(RenderTarget, NULL, RenderedSurface, NULL, D3DTEXF_LINEAR); // copy the result from the pass into the texture
		}
		Effect->End();
	}
	catch (const std::exception& e) {
		Logger::Log("Error during rendering of effect %s: %s", Name, e.what());
	}

	std::string name = "EffectRecord::Render " + std::string(Name);
	renderTime = timer.LogTime(name.c_str());
}
