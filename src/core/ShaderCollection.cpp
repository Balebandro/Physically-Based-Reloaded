bool ShaderCollection::SwitchShader() {
	Enabled = !TheSettingManager->GetMenuShaderEnabled(Name);
	TheSettingManager->SetMenuShaderEnabled(Name, Enabled);

	// TODO: handle unloading/reloading of shaders here
	for (auto & pixelShader : PixelShaderList) {
		pixelShader->Enabled = Enabled;
	}

	for (auto& vertexShader : VertexShaderList) {
		vertexShader->Enabled = Enabled;
	}

	return Enabled;
}


void ShaderCollection::DisposeShaders() {

	for (auto& pixelShader : PixelShaderList) {
		pixelShader->DisposeShader();
	}

	for (auto& vertexShader : VertexShaderList) {
		vertexShader->DisposeShader();
	}
}

/*
* Recompiles this collection's pixel shaders from their templates while the game runs, for a
* template define that follows a setting (Complex Water's DebugView). Call between frames (from
* UpdateSettings). Each shader's new records are built before the old ones go, so a failed compile
* keeps the old one, and a new shader can never be handed the address of one just released while
* the engine's render state still remembers it; the device is taken off whatever shader it was left
* on first, as the old handles are released.
*/
void ShaderCollection::ReloadPixelShaders() {
	const char* SubPaths[3] = { NULL, "Exteriors\\", "Interiors\\" };	// ShaderRecordType order
	TheRenderManager->renderState->SetPixelShader(NULL, false);

	for (auto& pixelShader : PixelShaderList) {
		ShaderTemplate Template = GetTemplate(pixelShader->Name);
		for (int i = 0; i < 3; i++) {
			ShaderRecord* old = pixelShader->ShaderProg[i];
			if (!old) continue;	// only what loaded before
			ShaderRecord* fresh = ShaderRecord::LoadShader(pixelShader->Name, SubPaths[i], Template);
			if (!fresh) {
				Logger::Log("%s: %s kept as it was (the reload did not compile)", Name, pixelShader->Name);
				continue;
			}
			pixelShader->ShaderProg[i] = fresh;
			delete (ShaderRecordPixel*)old;
		}
	}
	Logger::Log("%s: pixel shaders reloaded", Name);
}

ShaderTemplate ShaderCollection::GetTemplate(const char* Name) {
	std::map<std::string_view, ShaderTemplate> templates = Templates();
	if (auto temp = templates.find(Name); temp != templates.end()) {
		return temp->second;
	}
	else {
		return ShaderTemplate{};
	}
}