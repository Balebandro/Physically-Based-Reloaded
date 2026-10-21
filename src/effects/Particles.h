#pragma once

class ParticleShaders : public ShaderCollection
{
public:
	ParticleShaders() : ShaderCollection("Particles") {};

	struct ParticleStruct {
		D3DXVECTOR4		Data;
		D3DXVECTOR4		Ambient;
	};
	ParticleStruct	Constants;

	struct ParticleSettings {
		float	Strength;
		float	Brightness;
		float	SunShare;
	};
	ParticleSettings	Settings;

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
};
