#include "MotionBlur.h"

void MotionBlurEffect::UpdateConstants() {
	ValuesStruct category = Settings.FirstPerson;
	if (!TheCameraManager->IsFirstPerson()) category = Settings.ThirdPerson;

	float AngleZ = D3DXToDegree(Player->rot.z);
	float AngleX = D3DXToDegree(Player->rot.x);
	float fMotionBlurAmtX = Constants.oldAngleZ - AngleZ;
	float fMotionBlurAmtY = Constants.oldAngleX - AngleX;
	float fBlurDistScratchpad = fMotionBlurAmtX + 360.0f;
	float fBlurDistScratchpad2 = (AngleZ - Constants.oldAngleZ + 360.0f) * -1.0f;

	if (abs(fMotionBlurAmtX) > abs(fBlurDistScratchpad))
		fMotionBlurAmtX = fBlurDistScratchpad;
	else if (abs(fMotionBlurAmtX) > abs(fBlurDistScratchpad2))
		fMotionBlurAmtX = fBlurDistScratchpad2;

	if (pow(fMotionBlurAmtX, 2) + pow(fMotionBlurAmtY, 2) < category.BlurCutOff) {
		fMotionBlurAmtX = 0.0f;
		fMotionBlurAmtY = 0.0f;
	}

	Constants.Data.x = (Constants.oldoldAmountX + Constants.oldAmountX + fMotionBlurAmtX) / 3.0f;
	Constants.Data.y = (Constants.oldoldAmountY + Constants.oldAmountY + fMotionBlurAmtY) / 3.0f;
	Constants.oldAngleZ = AngleZ;
	Constants.oldAngleX = AngleX;
	Constants.oldoldAmountX = Constants.oldAmountX;
	Constants.oldoldAmountY = Constants.oldAmountY;
	Constants.oldAmountX = fMotionBlurAmtX;
	Constants.oldAmountY = fMotionBlurAmtY;
	Constants.BlurParams.x = category.GaussianWeight;
	Constants.BlurParams.y = category.BlurScale;
	Constants.BlurParams.z = category.BlurOffsetMax;
	Constants.BlurParams.w = (float)category.Mode;

	UpdateWeaponMotion(category);
}

// Mode 3: how the first-person hands and weapon moved on screen since last frame. A few rig nodes are projected
// to the screen and a move + rotation + scale is fitted from last frame's spots to this frame's; the shader blurs
// the weapon's pixels along that field. It runs only while the player fires, reloads or raises/lowers the sights
// (plus WeaponBlurHold seconds after, for the recoil to settle): the sway from turning the camera or walking
// doesn't blur the weapon.
void MotionBlurEffect::UpdateWeaponMotion(const ValuesStruct& category) {
	static const char* Nodes[6] = { "Bip01 R Hand", "Bip01 L Hand", "Bip01 R Forearm", "Bip01 L Forearm", "Weapon", "ProjectileNode" };
	D3DXVECTOR4 motion(0.0f, 0.0f, 0.0f, 0.0f), spin(0.0f, 0.0f, category.WeaponBlurMax, 0.0f);
	NiNode* Root = Player ? Player->firstPersonNiNode : nullptr;

	if (category.Mode != 3 || !Root || !TheCameraManager->IsFirstPerson()) {
		for (int i = 0; i < 6; i++) Constants.oldValid[i] = false;
		Constants.WeaponMotion = motion;
		Constants.WeaponSpin = spin;
		Constants.WeaponRaw = D3DXVECTOR4(0.0f, 0.0f, 0.0f, 0.0f);
		Constants.WeaponHold = Constants.WeaponGate = 0.0f;
		return;
	}

	// When it blurs: attacking (the shot and its recoil), reloading, and the moment the sights go up or down.
	SInt16 action = Player->process ? Player->process->GetCurrentAction() : HighProcess::kAnimAction_None;
	bool acting = false;
	switch (action) {
		case HighProcess::kAnimAction_Attack:
		case HighProcess::kAnimAction_Attack_Eject:
		case HighProcess::kAnimAction_Attack_Follow_Through:
		case HighProcess::kAnimAction_Attack_Throw:
		case HighProcess::kAnimAction_Attack_Throw_Attach:
		case HighProcess::kAnimAction_Recoil:
		case HighProcess::kAnimAction_Reload:
		case HighProcess::kAnimAction_ReloadLoopStart:
		case HighProcess::kAnimAction_ReloadLoopEnd:
		case HighProcess::kAnimAction_ReloadLoop:
			acting = true;
	}
	bool aiming = Player->IsAiming();
	if (aiming != Constants.WasAiming) acting = true;
	Constants.WasAiming = aiming;

	float elapsed = std::clamp((float)TheFrameRateManager->ElapsedTime, 0.0f, 0.1f);
	Constants.WeaponHold = acting ? category.WeaponBlurHold : max(0.0f, Constants.WeaponHold - elapsed);
	// Eased in and out over a tenth of a second, so the blur never pops.
	float target = Constants.WeaponHold > 0.0f ? 1.0f : 0.0f;
	float step = elapsed / 0.1f;
	Constants.WeaponGate = target > Constants.WeaponGate ? min(target, Constants.WeaponGate + step) : max(target, Constants.WeaponGate - step);

	// Screen spots, with x scaled by the aspect ratio so turns fit as turns.
	const D3DXMATRIX& View = TheRenderManager->ViewMatrix;
	D3DXVECTOR3 Right(View._11, View._21, View._31), Up(View._12, View._22, View._32), Forward(View._13, View._23, View._33);
	D3DXVECTOR3 Eye(TheRenderManager->CameraPosition.x, TheRenderManager->CameraPosition.y, TheRenderManager->CameraPosition.z);
	float aspect = (float)TheRenderManager->width / (float)TheRenderManager->height;
	float fov = Player->GetFoV(true);
	if (fov < 10.0f || fov > 170.0f) fov = 75.0f;
	float tanX = tan(D3DXToRadian(fov) * 0.5f);
	float tanY = tanX / aspect;

	D3DXVECTOR2 points[6];
	bool valid[6];
	D3DXVECTOR2 prevCenter(0, 0), center(0, 0);
	int pairs = 0;
	for (int i = 0; i < 6; i++) {
		NiAVObject* Node = Root->GetObjectByName(Nodes[i]);
		valid[i] = false;
		if (!Node) continue;
		NiPoint3& P = Node->m_worldTransform.pos;
		D3DXVECTOR3 rel(P.x - Eye.x, P.y - Eye.y, P.z - Eye.z);
		float z = D3DXVec3Dot(&rel, &Forward);
		if (z < 1.0f) continue;
		float u = 0.5f + 0.5f * D3DXVec3Dot(&rel, &Right) / (z * tanX);
		float v = 0.5f - 0.5f * D3DXVec3Dot(&rel, &Up) / (z * tanY);
		points[i] = D3DXVECTOR2(u * aspect, v);
		valid[i] = true;
		if (Constants.oldValid[i]) {
			prevCenter += Constants.oldPoints[i];
			center += points[i];
			pairs++;
		}
	}

	if (pairs > 0) {
		prevCenter /= (float)pairs;
		center /= (float)pairs;
		D3DXVECTOR2 move = center - prevCenter;
		// Teleports, load screens, camera switches: no trail.
		if (D3DXVec2Length(&move) < 0.3f) {
			float dot = 0.0f, cross = 0.0f, spread = 0.0f;
			for (int i = 0; i < 6; i++) {
				if (!valid[i] || !Constants.oldValid[i]) continue;
				D3DXVECTOR2 p = Constants.oldPoints[i] - prevCenter, q = points[i] - center;
				dot += p.x * q.x + p.y * q.y;
				cross += p.x * q.y - p.y * q.x;
				spread += p.x * p.x + p.y * p.y;
			}
			float scale = 0.0f, turn = 0.0f;
			if (pairs > 1 && spread > 1e-6f) {
				scale = std::clamp(dot / spread - 1.0f, -0.5f, 0.5f);
				turn = std::clamp(cross / spread, -0.5f, 0.5f);
			}
			float k = category.WeaponBlurScale;
			// Half of last frame's motion carried over, steadying single-frame jitter in the animation.
			D3DXVECTOR4& raw = Constants.WeaponRaw;
			raw = D3DXVECTOR4(0.5f * (move.x * k + raw.x), 0.5f * (move.y * k + raw.y), 0.5f * (scale * k + raw.z), 0.5f * (turn * k + raw.w));
			float gate = Constants.WeaponGate;
			motion = D3DXVECTOR4(prevCenter.x, prevCenter.y, raw.x * gate, raw.y * gate);
			spin.x = raw.z * gate;
			spin.y = raw.w * gate;
			// Under a tenth of a pixel of blur: nothing to draw.
			float tiny = 0.1f / (float)TheRenderManager->height;
			if (abs(motion.z) < tiny && abs(motion.w) < tiny && abs(spin.x) < tiny && abs(spin.y) < tiny)
				motion.z = motion.w = spin.x = spin.y = 0.0f;
		}
	}

	for (int i = 0; i < 6; i++) {
		Constants.oldValid[i] = valid[i];
		if (valid[i]) Constants.oldPoints[i] = points[i];
	}
	Constants.WeaponMotion = motion;
	Constants.WeaponSpin = spin;
}

void MotionBlurEffect::UpdateSettings() {
	Settings.FirstPerson.BlurCutOff = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "BlurCutOff");
	Settings.FirstPerson.GaussianWeight = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "GaussianWeight");
	Settings.FirstPerson.BlurScale = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "BlurScale");
	Settings.FirstPerson.BlurOffsetMax = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "BlurOffsetMax");
	Settings.FirstPerson.Mode = std::clamp(TheSettingManager->GetSettingI("Shaders.MotionBlur.FirstPersonView", "Mode"), 0, 3);
	Settings.FirstPerson.WeaponBlurScale = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "WeaponBlurScale");
	Settings.FirstPerson.WeaponBlurMax = TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "WeaponBlurMax");
	Settings.FirstPerson.WeaponBlurHold = max(0.0f, TheSettingManager->GetSettingF("Shaders.MotionBlur.FirstPersonView", "WeaponBlurHold"));
	Settings.ThirdPerson.Mode = 0;   // no viewmodel in third person: always the whole screen
	Settings.ThirdPerson.WeaponBlurScale = 0.0f;
	Settings.ThirdPerson.WeaponBlurMax = 0.0f;
	Settings.ThirdPerson.WeaponBlurHold = 0.0f;

	Settings.ThirdPerson.BlurCutOff = TheSettingManager->GetSettingF("Shaders.MotionBlur.ThirdPersonView", "BlurCutOff");
	Settings.ThirdPerson.GaussianWeight = TheSettingManager->GetSettingF("Shaders.MotionBlur.ThirdPersonView", "GaussianWeight");
	Settings.ThirdPerson.BlurScale = TheSettingManager->GetSettingF("Shaders.MotionBlur.ThirdPersonView", "BlurScale");
	Settings.ThirdPerson.BlurOffsetMax = TheSettingManager->GetSettingF("Shaders.MotionBlur.ThirdPersonView", "BlurOffsetMax");
}

void MotionBlurEffect::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_MotionBlurParams", &Constants.BlurParams);
	TheShaderManager->RegisterConstant("TESR_MotionBlurData", &Constants.Data);
	TheShaderManager->RegisterConstant("TESR_MotionBlurWeapon", &Constants.WeaponMotion);
	TheShaderManager->RegisterConstant("TESR_MotionBlurWeaponSpin", &Constants.WeaponSpin);
}

bool MotionBlurEffect::ShouldRender()
{
	if (Constants.BlurParams.w == 3.0f)   // the weapon's own movement: the camera turning plays no part
		return Constants.WeaponMotion.z || Constants.WeaponMotion.w || Constants.WeaponSpin.x || Constants.WeaponSpin.y;
	return Constants.Data.x || Constants.Data.y;
};