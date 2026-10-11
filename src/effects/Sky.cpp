#include "Sky.h"

void SkyShaders::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_SkyData", &Constants.SkyData);
	TheShaderManager->RegisterConstant("TESR_CloudData", &Constants.CloudData);
	TheShaderManager->RegisterConstant("TESR_CloudVolumeData", &Constants.CloudVolumeData);
	TheShaderManager->RegisterConstant("TESR_CloudVolumeData2", &Constants.CloudVolumeData2);
	TheShaderManager->RegisterConstant("TESR_CloudVolumeLight", &Constants.CloudVolumeLight);
	TheShaderManager->RegisterConstant("TESR_SunsetColor", &Constants.SunsetColor);
	TheShaderManager->RegisterConstant("TESR_SkyIrradiance", &Constants.Irradiance[0]);
}

// Mirrors GetSunColor / GetSkyColor in Shaders/Includes/Sky.hlsl. Kept in step by hand: the
// two trees compile independently, exactly as Shadow.hlsl mirrors Effects/Includes/Shadows.hlsl.
// Change one and change the other.
//
// The atmosphere exponent is SKY.pso's own 8. The ambient path used to soften it to fake the
// width of a diffuse lobe; the integral below covers that properly, so the sky model is used
// unmodified and the ambient agrees with the dome on screen.
// The piecewise sRGB transfer function, matching linearize()/delinearize() in
// Shaders/Includes/Helpers.hlsl. A plain pow(c, 2.2) is NOT the same curve -- it diverges most
// in the darks, which is exactly where the sky colours sit at dawn and dusk.
static float SrgbToLinear(float c) {
	c = max(c, 0.0f);
	return (c <= 0.04045f) ? (c / 12.92f) : powf((c + 0.055f) / 1.055f, 2.4f);
}


static D3DXVECTOR3 Linearize(const D3DXVECTOR4& c) {
	return D3DXVECTOR3(SrgbToLinear(c.x), SrgbToLinear(c.y), SrgbToLinear(c.z));
}


static D3DXVECTOR3 EvalSky(const D3DXVECTOR3& dir, float verticality, float athPow, const D3DXVECTOR4& sunPos, const D3DXVECTOR4& skyData,
	const D3DXVECTOR3& skyC, const D3DXVECTOR3& skyLowC, const D3DXVECTOR3& horizonC,
	const D3DXVECTOR3& sunColor, float sunHeight, float isDayTime) {

	// verticality and athPow depend only on dir, so UpdateConstants tabulates them (same expressions, same bits)
	float athmosphere = athPow * skyData.x;
	float sunDot = (dir.x * sunPos.x + dir.y * sunPos.y + dir.z * sunPos.z) * 0.5f + 0.5f;
	float sunInfluence = powf(fabsf(sunDot), 1.0f / skyData.y);

	D3DXVECTOR3 c = skyLowC + (skyC - skyLowC) * verticality;
	float hz = std::clamp(athmosphere * (0.5f + sunInfluence * 0.5f), 0.0f, 1.0f);
	c = c + (horizonC - c) * hz;
	c += sunColor * (sunInfluence * (1.0f - sunHeight) * athmosphere * skyData.z * isDayTime);
	return c;
}

void SkyShaders::UpdateConstants() {
	if (TheShaderManager->Shaders.Tonemapping->Enabled)
		Constants.SunsetColor.w = TheShaderManager->GetTransitionValue(Settings.SkyMultiplierDay, Settings.SkyMultiplierNight, 1.0);
	else
		Constants.SunsetColor.w = 1.0;

	// Order-2 spherical harmonic projection of the sky, convolved with the clamped-cosine
	// kernel: E(N) = INTEGRAL L(w) max(N.w, 0) dw. The cosine kernel is a severe low-pass
	// filter, so 9 coefficients carry that integral to within about 1% (Ramamoorthi & Hanrahan
	// 2001), and the kernel has only three non-zero bands, A0 = pi, A1 = 2pi/3, A2 = pi/4.
	//
	// Integrated in LINEAR radiance, which is what the integral is defined on. The shader
	// encodes the reconstruction, because the object and terrain shaders carry no gamma
	// conversion and their ambient is gamma-encoded.
	//
	// Everything the ambient used to fake falls out of this: the wall/floor split, the sun-side
	// azimuthal bias, the cosine form factor, and the fact that a floor integrates the whole
	// dome while a wall integrates half. No directionality parameter is needed or meaningful.
	//
	// Radiance below the horizon is ZERO -- no ground bounce is modelled. That reproduces the
	// old form factor exactly: a floor sees the full dome, a wall half of it, a ceiling none.
	const D3DXVECTOR4& sunPos = TheShaderManager->ShaderConst.SunPosition;
	D3DXVECTOR3 skyC = Linearize(TheShaderManager->ShaderConst.skyColor);
	D3DXVECTOR3 skyLowC = Linearize(TheShaderManager->ShaderConst.skyLowColor);
	D3DXVECTOR3 horizonC = Linearize(TheShaderManager->ShaderConst.horizonColor);

	float sunHeight = max(sunPos.z, 0.0f);   // shade(sunPos, up)
	float dayTime = TheShaderManager->ShaderConst.SunAmount.x;
	float isDayTime = std::clamp(dayTime / 0.5f, 0.0f, 1.0f);
	isDayTime = isDayTime * isDayTime * (3.0f - 2.0f * isDayTime);   // smoothstep(0, 0.5, x)

	D3DXVECTOR3 sunDisk = Linearize(TheShaderManager->ShaderConst.sunDiskColor);
	D3DXVECTOR3 sunsetC = Linearize(Constants.SunsetColor);
	float sunSet = std::clamp(powf(1.0f - sunHeight, 8.0f), 0.0f, 1.0f) * dayTime;
	D3DXVECTOR3 sunColor = (1.0f + sunHeight) * sunDisk + sunsetC * (sunSet * Constants.SkyData.x);

	// Upper hemisphere only; the lower half contributes nothing, so it is skipped rather than
	// evaluated. Order-2 SH is smooth enough that this stratification is ample.
	const int STEPS_T = 16, STEPS_P = 32;
	const float dTheta = (D3DX_PI * 0.5f) / STEPS_T;
	const float dPhi = (2.0f * D3DX_PI) / STEPS_P;

	// The integral is a pure function of the inputs below. When every one matches the previous
	// integral bit for bit, the stored Irradiance is already exactly what a recompute gives, so it is
	// kept. SunsetColor.w is left out because the integral never reads it.
	D3DXVECTOR4 sunsetKey = Constants.SunsetColor;
	sunsetKey.w = 0.0f;
	const D3DXVECTOR4 key[8] = { sunPos, Constants.SkyData, TheShaderManager->ShaderConst.skyColor,
		TheShaderManager->ShaderConst.skyLowColor, TheShaderManager->ShaderConst.horizonColor,
		TheShaderManager->ShaderConst.sunDiskColor, sunsetKey, D3DXVECTOR4(dayTime, 0.0f, 0.0f, 0.0f) };
	static D3DXVECTOR4 lastKey[8];
	static bool haveLastKey = false;
	if (haveLastKey && memcmp(key, lastKey, sizeof(key)) == 0) return;
	memcpy(lastKey, key, sizeof(key));
	haveLastKey = true;

	// The direction-dependent terms never change, so they are tabulated once: the unit direction,
	// the solid angle and the nine basis values, each formed exactly as the loop used to form it.
	struct SHSample { D3DXVECTOR3 d; float dOmega; float vertical; float athPow; float basis[9]; };
	static SHSample samples[STEPS_T * STEPS_P];
	static bool samplesBuilt = false;
	if (!samplesBuilt) {
		for (int i = 0; i < STEPS_T; i++) {
			float theta = (i + 0.5f) * dTheta;
			float st = sinf(theta), ct = cosf(theta);
			float dOmega = st * dTheta * dPhi;
			for (int j = 0; j < STEPS_P; j++) {
				float phi = (j + 0.5f) * dPhi;
				const D3DXVECTOR3 d(st * cosf(phi), st * sinf(phi), ct);
				SHSample& s = samples[i * STEPS_P + j];
				s.d = d;
				s.dOmega = dOmega;
				s.vertical = powf(fabsf(d.z * 0.5f + 0.5f), 3.0f);
				s.athPow = powf(fabsf(1.0f - s.vertical), 8.0f);
				s.basis[0] = 0.282095f;
				s.basis[1] = 0.488603f * d.y;
				s.basis[2] = 0.488603f * d.z;
				s.basis[3] = 0.488603f * d.x;
				s.basis[4] = 1.092548f * d.x * d.y;
				s.basis[5] = 1.092548f * d.y * d.z;
				s.basis[6] = 0.315392f * (3.0f * d.z * d.z - 1.0f);
				s.basis[7] = 1.092548f * d.x * d.z;
				s.basis[8] = 0.546274f * (d.x * d.x - d.y * d.y);
			}
		}
		samplesBuilt = true;
	}

	D3DXVECTOR3 sh[9];
	for (int i = 0; i < 9; i++) sh[i] = D3DXVECTOR3(0.0f, 0.0f, 0.0f);

	for (int k = 0; k < STEPS_T * STEPS_P; k++) {
		const SHSample& s = samples[k];

		// LINEAR radiance, as GetSkyColor returns and as the integral requires. The shader
		// encodes on reconstruction. Integrating encoded values instead was measurably
		// wrong -- it cost walls about a third of their brightness, since their lobe spans
		// the widest range of sky and a concave curve pulls an average of spread values
		// down hardest.
		D3DXVECTOR3 L = EvalSky(s.d, s.vertical, s.athPow, sunPos, Constants.SkyData, skyC, skyLowC, horizonC,
			sunColor, sunHeight, isDayTime) * s.dOmega;

		for (int i = 0; i < 9; i++) sh[i] += L * s.basis[i];
	}

	// Convolve, and fold in each basis function's constant plus the 1/pi that converts
	// irradiance back to an average radiance -- the units the ambient path already works in, so
	// the existing scales keep their meaning. A0/pi = 1, A1/pi = 2/3, A2/pi = 1/4.
	const float A0 = 1.0f, A1 = 2.0f / 3.0f, A2 = 0.25f;
	const float band[9] = { A0, A1, A1, A1, A2, A2, A2, A2, A2 };
	const float basis[9] = { 0.282095f, 0.488603f, 0.488603f, 0.488603f,
							 1.092548f, 1.092548f, 0.315392f, 1.092548f, 0.546274f };

	for (int i = 0; i < 9; i++) {
		D3DXVECTOR3 c = sh[i] * (band[i] * basis[i]);
		Constants.Irradiance[i] = D3DXVECTOR4(c.x, c.y, c.z, 0.0f);
	}
}

void SkyShaders::UpdateSettings() {

	useSunDiskColor = TheSettingManager->GetSettingF("Shaders.Sky.Main", "UseSunDiskColor");

	Settings.SkyMultiplierDay = TheSettingManager->GetSettingF("Shaders.Tonemapping.Main", "SkyMultiplier");
	Settings.SkyMultiplierNight = TheSettingManager->GetSettingF("Shaders.Tonemapping.Night", "SkyMultiplier");

	Constants.SkyData.x = TheSettingManager->GetSettingF("Shaders.Sky.Main", "AthmosphereThickness");
	Constants.SkyData.y = TheSettingManager->GetSettingF("Shaders.Sky.Main", "SunInfluence");
	Constants.SkyData.z = TheSettingManager->GetSettingF("Shaders.Sky.Main", "SunStrength");
	Constants.SkyData.w = TheSettingManager->GetSettingF("Shaders.Sky.Main", "StarStrength");

	Constants.CloudData.x = TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "UseNormals");
	//Constants.CloudData.y = TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "SphericalNormals"); // not used much so it's disabled
	Constants.CloudData.z = TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Transparency");
	Constants.CloudData.w = TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Brightness");

	Constants.CloudData.y = TheSettingManager->GetSettingF("Shaders.Sky.Main", "StarTwinkle");

	// Volumetric clouds. DetailScale and UVScale are entered per 1000 game units (the menu cannot show
	// values as small as 1 / 40000), and the shader wants them per game unit.
	Constants.CloudVolumeData.x = TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Volumetric");
	Constants.CloudVolumeData.y = std::clamp(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Steps"), 1.0f, 16.0f);
	Constants.CloudVolumeData.z = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "CloudHeight"), 0.0f);
	Constants.CloudVolumeData.w = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "CloudThickness"), 0.0f);
	Constants.CloudVolumeData2.x = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Density"), 0.0f);
	Constants.CloudVolumeData2.y = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Absorption"), 0.0f);
	Constants.CloudVolumeData2.z = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "DetailScale"), 0.0f) * 0.001f;
	Constants.CloudVolumeData2.w = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "UVScale"), 0.0f) * 0.001f;
	Constants.CloudVolumeLight.x = std::clamp(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "Scattering"), 0.0f, 0.9f);
	Constants.CloudVolumeLight.y = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "SilverLining"), 0.0f);
	Constants.CloudVolumeLight.z = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "AmbientStrength"), 0.0f);
	Constants.CloudVolumeLight.w = max(TheSettingManager->GetSettingF("Shaders.Sky.Clouds", "DetailSpeed"), 0.0f);

	// only add sunset color boost in exteriors
	if (TheShaderManager->GameState.isExterior) {
		Constants.SunsetColor.x = TheSettingManager->GetSettingF("Shaders.Sky.Main", "SunsetR");
		Constants.SunsetColor.y = TheSettingManager->GetSettingF("Shaders.Sky.Main", "SunsetG");
		Constants.SunsetColor.z = TheSettingManager->GetSettingF("Shaders.Sky.Main", "SunsetB");
	}
	else {
		Constants.SunsetColor.x = 0;
		Constants.SunsetColor.y = 0;
		Constants.SunsetColor.z = 0;
	}

}