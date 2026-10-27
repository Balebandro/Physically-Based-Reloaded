#pragma once

class DitherBusterEffect : public EffectRecord
{
public:
	DitherBusterEffect() : EffectRecord("DitherBuster") {};

	struct DitherBusterSettingsStruct {
		float Strength;
		float MaskPower;
		float DitherThreshold;
		float Radius;
		float GateSoftness;
		bool DeDither;
		int DebugView;
	};
	DitherBusterSettingsStruct Settings;

	struct DitherBusterStruct {
		D3DXVECTOR4		Data;
		D3DXVECTOR4			Gate;
	};

	void	UpdateConstants();
	void	RegisterConstants();
	void	UpdateSettings();
	UINT	TechniqueIndex() const { return (Settings.GateSoftness > 0.0f || Settings.DeDither || Settings.DebugView != 0) ? 1 : 0; }

	DitherBusterStruct	Constants;
};
