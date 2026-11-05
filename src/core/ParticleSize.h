#pragma once

// UNOFFICIAL 2026-11-04 ParticleSize: each particle's size on its vertices, for the soft particles of the lit particle shaders
// (NOLIGHT016/017.vso + NOLIGHTTEXVC.pso, Shaders.Particles SoftScale). Ported from Vanilla Plus Particles by pr0bability
// (github.com/pr0bability/fnv-vanilla-plus-particles, GPL-3.0, as this project): the renderer's particle vertex packing
// (NiDX9Renderer::PackPoints / PackPointsSubTexture / PackParticleStrips) rewritten to add the size, the two particle vertex
// declarations, strides and buffer locks widened by 4 bytes. Unlike VPP the size goes AFTER the game's elements (TEXCOORD2 FLOAT1:
// at 40 with the texture-sheet frame, TEXCOORD1 at 36, at 36 without), so the game's shaders and other plugins' read what they did.
// Not installed with VPP loaded (it repacks the same vertices its own way) or with Shaders.Particles off at startup; Installed
// tells the pixel shader whether the size is there.

#include <cmath>

namespace ParticleSize {
	inline bool Installed = false;
	inline thread_local bool LastWithFrames = false;	// the last declaration asked for: with the frame element (the lock sizes follow it)

	struct Point3 { float x, y, z; };
	struct Color4 { float r, g, b, a; };

	inline UInt32 Pack(const Color4& c) {
		return (UInt32)(UInt8)(c.a * 255.0f) << 24 | (UInt32)(UInt8)(c.r * 255.0f) << 16 | (UInt32)(UInt8)(c.g * 255.0f) << 8 | (UInt32)(UInt8)(c.b * 255.0f);
	}

	inline IDirect3DVertexDeclaration9* MakeDecl(void* renderer, UInt32 slotOffset, bool frames) {
		IDirect3DVertexDeclaration9** slot = (IDirect3DVertexDeclaration9**)((UInt8*)renderer + slotOffset);
		LastWithFrames = frames;
		if (*slot) return *slot;
		const D3DVERTEXELEMENT9 withFrames[] = {
			{ 0, 0, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
			{ 0, 12, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL, 0 },
			{ 0, 24, D3DDECLTYPE_D3DCOLOR, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_COLOR, 0 },
			{ 0, 28, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
			{ 0, 36, D3DDECLTYPE_FLOAT1, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 1 },
			{ 0, 40, D3DDECLTYPE_FLOAT1, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 2 },
			D3DDECL_END() };
		const D3DVERTEXELEMENT9 plain[] = {
			{ 0, 0, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
			{ 0, 12, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL, 0 },
			{ 0, 24, D3DDECLTYPE_D3DCOLOR, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_COLOR, 0 },
			{ 0, 28, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
			{ 0, 36, D3DDECLTYPE_FLOAT1, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 2 },
			D3DDECL_END() };
		IDirect3DDevice9* device = *(IDirect3DDevice9**)((UInt8*)renderer + 0x288);
		return device->CreateVertexDeclaration(frames ? withFrames : plain, slot) == D3D_OK ? *slot : nullptr;
	}

	// 0xE69790 (hParticleVertexDecls[1], with frames) and 0xE696A0 ([0]).
	inline IDirect3DVertexDeclaration9* __fastcall GetDeclFrames(void* renderer, void*) { return MakeDecl(renderer, 0x284, true); }
	inline IDirect3DVertexDeclaration9* __fastcall GetDeclPlain(void* renderer, void*) { return MakeDecl(renderer, 0x280, false); }

	// The camera-facing quads, as the game builds them; frames: the texture-sheet frame (or null), written as a float.
	inline void PackQuads(void* renderer, float* out, const Point3* positions, const Color4* colors, const float* radii, const float* sizes,
		const float* angles, const UInt8* frames, bool withFrames, UInt16 count) {
		const Point3 R = *(Point3*)((UInt8*)renderer + 0x64C), U = *(Point3*)((UInt8*)renderer + 0x658);
		const Point3 N = { U.z * R.y - U.y * R.z, R.z * U.x - U.z * R.x, U.y * R.x - R.y * U.x };
		static const float corners[4][4] = { { -1, 0, 0, 1 }, { 0, -1, 1, 1 }, { 1, 0, 1, 0 }, { 0, 1, 0, 0 } };	// along right, along up, u, v
		for (UInt16 i = 0; i < count; i++) {
			const Point3 p = positions[i];
			const float size = radii[i] * sizes[i];
			const UInt32 color = colors ? Pack(colors[i]) : 0xFFFFFFFF;
			const float frame = frames ? (float)frames[i] : -1.0f;
			float a = 1.0f, b = 1.0f;
			if (angles) { const float c = cosf(angles[i]), s = sinf(angles[i]); a = s + c; b = c - s; }
			const Point3 right = { (R.x * a + U.x * b) * size, (R.y * a + U.y * b) * size, (R.z * a + U.z * b) * size };
			const Point3 up = { (U.x * a - R.x * b) * size, (U.y * a - R.y * b) * size, (U.z * a - R.z * b) * size };
			for (const auto& k : corners) {
				*out++ = p.x + right.x * k[0] + up.x * k[1];
				*out++ = p.y + right.y * k[0] + up.y * k[1];
				*out++ = p.z + right.z * k[0] + up.z * k[1];
				*out++ = N.x; *out++ = N.y; *out++ = N.z;
				*(UInt32*)out++ = color;
				*out++ = k[2]; *out++ = k[3];
				if (withFrames) *out++ = frame;
				*out++ = size;
			}
		}
	}

	// 0xE6AB40 NiDX9Renderer::PackPoints (with frames) and 0xE69EA0 PackPointsSubTexture (without).
	inline void __fastcall PackPoints(void* renderer, void*, void* buffer, Point3* positions, Color4* colors, float* radii, float* sizes, float* angles, UInt8* frames, UInt16 count) {
		PackQuads(renderer, (float*)buffer, positions, colors, radii, sizes, angles, frames, true, count);
	}
	inline void __fastcall PackPointsPlain(void* renderer, void*, void* buffer, Point3* positions, Color4* colors, float* radii, float* sizes, float* angles, UInt16 count) {
		PackQuads(renderer, (float*)buffer, positions, colors, radii, sizes, angles, nullptr, false, count);
	}

	// BSStripPSysData (0x90 bytes): NiGeometryData::m_pkColor +0x28, NiParticlesData::m_usActiveVertices +0x50 (the strip count) and
	// m_pucTextureIndices +0x64, pStripList +0x7C.
	struct StripPoint { Point3 point, vertex[4], dir, normal[2], velocity; Color4 color; float size, radii; };
	struct Strip { StripPoint* points; UInt16 pointCount, highestPointCount; UInt32 unk8, unkC, maxPointCount; SInt32 firstIndex, lastIndex; float lastTime; };

	inline float* StripVertex(float* out, const Point3& p, const Point3& n, UInt32 color, float u, float v, float size, float frame) {
		*out++ = p.x; *out++ = p.y; *out++ = p.z;
		*out++ = n.x; *out++ = n.y; *out++ = n.z;
		*(UInt32*)out++ = color;
		*out++ = u; *out++ = v;
		if (frame >= 0.0f) *out++ = frame;
		*out++ = size;
		return out;
	}

	// 0xE6D3A0 NiDX9Renderer::PackParticleStrips: VPP's port of the game's function, the size added to each vertex.
	inline UInt32 __fastcall PackStrips(void* renderer, void*, void* vertexBuffer, UInt16* indices, void* data, UInt32* vertexCount, UInt32* indexCount) {
		*vertexCount = 0;
		*indexCount = 0;
		const UInt8* base = (const UInt8*)data;
		const bool colored = *(void* const*)(base + 0x28) != nullptr;
		const UInt16 strips = *(const UInt16*)(base + 0x50);
		const UInt8* frames = *(UInt8* const*)(base + 0x64);
		const Strip* list = *(Strip* const*)(base + 0x7C);
		const Color4 white = { 1, 1, 1, 1 };

		float* out = (float*)vertexBuffer;
		UInt16* index = indices;
		UInt16 vertex = 0;
		bool first = true;
		for (UInt16 s = 0; s < strips; s++) {
			const Strip& strip = list[s];
			const UInt16 points = strip.pointCount, maxPoints = (UInt16)strip.maxPointCount;
			if (points >= 2) {
				if (!first) { *index++ = vertex - 1; *index++ = vertex; *indexCount += 2; }
				first = false;
				const float du = (float)(1.0 / (strip.highestPointCount - 1.0));
				float u = 0.0f;
				UInt16 point = (UInt16)strip.firstIndex;
				UInt16 start = vertex + 2;
				*vertexCount += 4 * points;
				const float frame = frames ? (float)frames[s] : -1.0f;
				for (UInt16 i = 0; i < points; i++) {
					const StripPoint& pd = strip.points[point];
					const UInt32 color = Pack(colored ? pd.color : white);
					const float size = pd.size * pd.radii;
					out = StripVertex(out, pd.vertex[0], pd.normal[0], color, u, 0.0f, size, frame);
					out = StripVertex(out, pd.vertex[1], pd.normal[0], color, u, 1.0f, size, frame);
					out = StripVertex(out, pd.vertex[2], pd.normal[1], color, u, 0.0f, size, frame);
					out = StripVertex(out, pd.vertex[3], pd.normal[1], color, u, 1.0f, size, frame);
					*index++ = vertex; *index++ = vertex + 1;
					vertex += 4;
					*indexCount += 2;
					u += du;
					point = (UInt16)((point + 1) % maxPoints);
				}
				*index++ = vertex - 3; *index++ = start;
				*indexCount += 2;
				for (UInt16 i = 0; i < points; i++) {
					*index++ = start; *index++ = start + 1;
					start += 4;
					*indexCount += 2;
				}
			}
		}
		return *indexCount;
	}

	inline void* __fastcall LockParticles(void* manager, void*, IDirect3DVertexBuffer9* buffer, UInt32 offset, UInt32 size, UInt32 flags) {
		size = LastWithFrames ? size / 40 * 44 : size / 36 * 40;
		return ThisStdCall<void*>(0xE8BFF0, manager, buffer, offset, size, flags);
	}

	inline void Install() {
		if (GetModuleHandleA("VanillaPlusParticles.dll")) {
			Logger::Log("ParticleSize: Vanilla Plus Particles is loaded and packs the particle vertices its own way: soft particles stay off");
			return;
		}
		// The game's code, as this was written against (another plugin may have patched the same places).
		const SIZE_T calls[][2] = { { 0xE70560, 0xE6AB40 }, { 0xE705FE, 0xE69EA0 }, { 0xE70AE1, 0xE6D3A0 }, { 0xE705D0, 0xE8BFF0 }, { 0xE7052D, 0xE8BFF0 }, { 0xE709F3, 0xE8BFF0 } };
		bool game = *(UInt16*)0xE69790 == 0xEC83 && *(UInt16*)0xE696A0 == 0xEC83 && *(UInt8*)0xE704DD == 0x28 && *(UInt8*)0xE70582 == 0x24 &&
			*(UInt8*)0xE708FD == 0x24 && *(UInt8*)0xE708BC == 0x28;
		for (const auto& c : calls) game = game && *(UInt8*)c[0] == 0xE8 && GetRelJumpAddr(c[0]) == c[1];
		if (!game) {
			Logger::Log("ParticleSize: the game's particle vertex packing is already patched (another plugin?): soft particles stay off");
			return;
		}
		WriteRelJump(0xE69790, &GetDeclFrames);
		WriteRelJump(0xE696A0, &GetDeclPlain);
		ReplaceCall(0xE70560, (SIZE_T)&PackPoints);
		ReplaceCall(0xE705FE, (SIZE_T)&PackPointsPlain);
		ReplaceCall(0xE70AE1, (SIZE_T)&PackStrips);
		SafeWrite8(0xE704DD, 0x2C);	// strides 40 -> 44, 36 -> 40
		SafeWrite8(0xE70582, 0x28);
		SafeWrite8(0xE708FD, 0x28);
		SafeWrite8(0xE708BC, 0x2C);
		ReplaceCall(0xE705D0, (SIZE_T)&LockParticles);
		ReplaceCall(0xE7052D, (SIZE_T)&LockParticles);
		ReplaceCall(0xE709F3, (SIZE_T)&LockParticles);
		Installed = true;
		Logger::Log("ParticleSize: particle vertices carry their size (soft particles)");
	}
}
