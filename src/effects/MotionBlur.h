#pragma once

class MotionBlurEffect : public EffectRecord
{
public:
	MotionBlurEffect() : EffectRecord("MotionBlur") {};

	struct ValuesStruct {
		float BlurCutOff;
		float GaussianWeight;
		float BlurScale;
		float BlurOffsetMax;
		int Mode;			// what blurs: 0 everything, 1 the first-person weapon (viewmodel) only, 2 everything but it,
							// 3 the weapon from its own movement while firing, reloading or aiming, the world sharp
		float WeaponBlurScale;	// mode 3: blur length as a multiple of the weapon's on-screen motion in one frame
		float WeaponBlurMax;	// mode 3: longest blur, as a fraction of the screen height
		float WeaponBlurHold;	// mode 3: seconds the blur keeps going after a shot, reload or aim change
	};

	struct MotionBlurSettings {
		ValuesStruct ThirdPerson;
		ValuesStruct FirstPerson;
	};
	MotionBlurSettings Settings;

	struct MotionBlurStruct {
		D3DXVECTOR4		BlurParams;
		D3DXVECTOR4		Data;
		float			oldAngleX;
		float			oldAngleZ;
		float			oldAmountX;
		float			oldAmountY;
		float			oldoldAmountX;
		float			oldoldAmountY;
		// Mode 3: the weapon's screen motion this frame as a field v(uv) = Move + Spin * (uv - Center)
		D3DXVECTOR4		WeaponMotion;	// xy Center, zw Move (uv per frame, scaled)
		D3DXVECTOR4		WeaponSpin;		// x scale - 1, y rotation (both scaled)
		D3DXVECTOR2		oldPoints[6];	// the tracked first-person nodes on screen last frame
		bool			oldValid[6];
		D3DXVECTOR4		WeaponRaw;		// the smoothed motion before the gate: xy move, z scale, w turn
		float			WeaponHold;		// seconds of blur left since the last shot, reload or aim change
		float			WeaponGate;		// 0-1, eases the blur in and out
		bool			WasAiming;
	};
	MotionBlurStruct	Constants;

	void	UpdateConstants();
	void	UpdateWeaponMotion(const ValuesStruct& category);
	void	RegisterConstants();
	void	UpdateSettings();
	bool	ShouldRender();
};