#pragma once

// Lamp scissor ([Main.Main.Performance] LampScissor), ported from NVR UNOFFICIAL Optimized (P81): the passes that only
// add lamps' light to an object (SLS2045/2046 and the lamp highlight passes SLS2051-2056) are drawn only inside the
// screen rectangle those lamps can reach (each lamp's radius, as a box, projected), instead of over the whole object;
// a pass whose lamps are all off the screen is skipped. A lamp lights nothing beyond its radius, so the picture is the
// same. Called by the world scene's render pass hooks (RenderPassStandardHook, RenderPassSkinnedHook in Hooks/Render.cpp).
namespace LampScissor {

	// BSShaderProperty::RenderPass, as far as this needs it.
	struct RenderPassView {
		NiGeometry*			geometry;		// 00
		UInt16				passEnum;		// 04
		UInt8				unk06;
		UInt8				unk07;
		UInt8				unk08;
		UInt8				numLights;		// 09
		UInt8				maxLights;
		UInt8				unk0B;
		ShadowSceneLight**	lights;			// 0C
	};
	static_assert(offsetof(RenderPassView, numLights) == 0x09 && offsetof(RenderPassView, lights) == 0x0C, "RenderPass layout");

	inline bool Enabled = false;
	inline bool LampOnlyPass = false;	// the bound pixel shader is one of the lamp-only ones
	inline bool Scissored = false;
	inline DWORD SavedEnable = FALSE;
	inline RECT SavedRect = {};

	// Once a frame.
	inline void BeginFrame() {
		Enabled = TheSettingManager->GetSettingI("Main.Main.Performance", "LampScissor") != 0;
		LampOnlyPass = false;
		Scissored = false;
	}

	// The batch's pixel shader (SetShadersHook): NVR's SLS2045, 2046 and 2051-2056 in the world scene.
	inline void OnBind(const NiD3DPixelShaderEx* shader, bool world) {
		LampOnlyPass = false;
		if (!Enabled || !world || !shader || !shader->Name || !shader->ShaderHandleBackup ||
			shader->ShaderHandle == shader->ShaderHandleBackup) return;
		const char* name = shader->Name;
		if (strncmp(name, "SLS20", 5) || strlen(name) != 11 || strcmp(name + 7, ".pso")) return;
		const int number = (name[5] - '0') * 10 + (name[6] - '0');
		LampOnlyPass = number == 45 || number == 46 || (number >= 51 && number <= 56);
	}

	enum Result { Draw, Skip };

	// Before a pass is drawn: the scissor set to the screen rectangle its lamps reach, or Skip when none is on the screen.
	// Anything unusual (a lamp behind the camera, a viewport that is not the screen) draws the pass whole.
	inline Result Before(const RenderPassView* pass, bool world) {
		Scissored = false;
		if (!Enabled || !LampOnlyPass || !world || !pass || !pass->numLights || !pass->lights) return Draw;
		IDirect3DDevice9* device = TheRenderManager->device;
		D3DVIEWPORT9 port;
		NiCamera* camera = WorldSceneGraph ? WorldSceneGraph->camera : nullptr;
		if (!camera || camera->Frustum.Ortho || FAILED(device->GetViewport(&port)) || port.X || port.Y ||
			port.Width != TheRenderManager->width || port.Height != TheRenderManager->height) return Draw;
		const NiMatrix33& rot = camera->m_worldTransform.rot;
		const NiPoint3& eye = camera->m_worldTransform.pos;
		const NiFrustum& frustum = camera->Frustum;
		const float frustumWidth = frustum.Right - frustum.Left, frustumHeight = frustum.Top - frustum.Bottom;
		if (frustumWidth <= 0.0f || frustumHeight <= 0.0f || frustum.Near <= 0.0f) return Draw;
		// The camera's axes (Gamebryo: x forward, y up, z right), its world rotation's columns.
		const float forward[3] = { rot.data[0][0], rot.data[1][0], rot.data[2][0] };
		const float up[3] = { rot.data[0][1], rot.data[1][1], rot.data[2][1] };
		const float right[3] = { rot.data[0][2], rot.data[1][2], rot.data[2][2] };
		float minX = 1e30f, minY = 1e30f, maxX = -1e30f, maxY = -1e30f;
		bool anyOnScreen = false;
		for (UInt8 k = 0; k < pass->numLights; k++) {
			const ShadowSceneLight* light = pass->lights[k];
			if (!light || !light->bPointLight || !light->sourceLight) return Draw;
			const NiPointLight* source = light->sourceLight;
			const float radius = source->Spec.r;
			if (!(radius > 0.0f) || radius > 1e6f) return Draw;
			const float reach = radius * 1.02f + 2.0f;
			const NiPoint3& centre = source->m_worldTransform.pos;
			float lampMinX = 1e30f, lampMinY = 1e30f, lampMaxX = -1e30f, lampMaxY = -1e30f;
			for (int corner = 0; corner < 8; corner++) {
				const float p[3] = { centre.x + ((corner & 1) ? reach : -reach) - eye.x, centre.y + ((corner & 2) ? reach : -reach) - eye.y,
					centre.z + ((corner & 4) ? reach : -reach) - eye.z };
				const float z = p[0] * forward[0] + p[1] * forward[1] + p[2] * forward[2];
				if (z < frustum.Near * 0.5f) return Draw;   // part of its reach behind the camera: not worth the bother
				const float x = p[0] * right[0] + p[1] * right[1] + p[2] * right[2];
				const float y = p[0] * up[0] + p[1] * up[1] + p[2] * up[2];
				const float ndcX = (2.0f * x / z - (frustum.Right + frustum.Left)) / frustumWidth;
				const float ndcY = (2.0f * y / z - (frustum.Top + frustum.Bottom)) / frustumHeight;
				const float sx = (ndcX + 1.0f) * 0.5f * port.Width, sy = (1.0f - ndcY) * 0.5f * port.Height;
				lampMinX = (std::min)(lampMinX, sx); lampMaxX = (std::max)(lampMaxX, sx);
				lampMinY = (std::min)(lampMinY, sy); lampMaxY = (std::max)(lampMaxY, sy);
			}
			if (lampMaxX < 0.0f || lampMaxY < 0.0f || lampMinX > (float)port.Width || lampMinY > (float)port.Height) continue;
			anyOnScreen = true;
			minX = (std::min)(minX, lampMinX); maxX = (std::max)(maxX, lampMaxX);
			minY = (std::min)(minY, lampMinY); maxY = (std::max)(maxY, lampMaxY);
		}
		if (!anyOnScreen) return Skip;
		RECT rect;
		rect.left = (LONG)(std::max)(0.0f, floorf(minX) - 1.0f);
		rect.top = (LONG)(std::max)(0.0f, floorf(minY) - 1.0f);
		rect.right = (LONG)(std::min)((float)port.Width, ceilf(maxX) + 1.0f);
		rect.bottom = (LONG)(std::min)((float)port.Height, ceilf(maxY) + 1.0f);
		if (rect.right <= rect.left || rect.bottom <= rect.top) return Skip;
		if (rect.left == 0 && rect.top == 0 && rect.right == (LONG)port.Width && rect.bottom == (LONG)port.Height) return Draw;
		if (FAILED(device->GetRenderState(D3DRS_SCISSORTESTENABLE, &SavedEnable)) || FAILED(device->GetScissorRect(&SavedRect))) return Draw;
		device->SetScissorRect(&rect);
		device->SetRenderState(D3DRS_SCISSORTESTENABLE, TRUE);
		Scissored = true;
		return Draw;
	}

	// After the pass: the scissor as it was.
	inline void After() {
		if (!Scissored) return;
		Scissored = false;
		IDirect3DDevice9* device = TheRenderManager->device;
		device->SetScissorRect(&SavedRect);
		device->SetRenderState(D3DRS_SCISSORTESTENABLE, SavedEnable);
	}
}
