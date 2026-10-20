#pragma once

class TextureRecord {
public:
	TextureRecord();

	enum TextureRecordType {
		None,
		PlanarBuffer,
		VolumeBuffer,
		CubeBuffer
	};
	static TextureRecord*		GetTextureRecord(const char* Name, std::string TexturePath);
	static TextureRecordType	GetTextureType(UINT Type);

	void						GetSamplerStates(std::string samplerStateSubstring);
	bool						BindTexture(const char* Name);
	bool						LoadTexture(TextureRecordType Type, const char* TexturePath);

	IDirect3DBaseTexture9*		Texture;
	IDirect3DBaseTexture9**		TextureRef = nullptr;	// a TextureManager slot (BindTexture): what it holds can change, as the frame chain's buffers do
	DWORD						SamplerStates[SamplerStatesMax];
};
