#include "RenderPass.h"
#include <algorithm>
#include <unordered_map>


void RenderPass::RenderAccum() {
	if (GeometryList.empty()) return;

	// Could add setup of device/renderstate/current shaders here
	NiDX9RenderState* RenderState = TheRenderManager->renderState;
	RenderState->SetPixelShader(PixelShader->ShaderHandle, false);
	RenderState->SetVertexShader(VertexShader->ShaderHandle, false);

	// Render normal geometry
	while (!GeometryList.empty()) {
		NiGeometry* Geo = GeometryList.top();
		if (!Geo) continue;

		UpdateConstants(Geo);
		PixelShader->SetCT();
		VertexShader->SetCT();

		RenderGeometry(Geo);
		GeometryList.pop();
	}
}


void RenderPass::RenderGeometry(NiGeometry* Geo) {
	NiGeometryData* ModelData = Geo->geomData;
	NiGeometryBufferData* GeoData = ModelData->m_pkBuffData;
	NiD3DShaderDeclaration* ShaderDeclaration = Geo->shader->ShaderDeclaration;

	// Set proper cull based on stencil property.
	NiProperty* pProp = Geo->GetProperty(NiProperty::PropertyType::kType_Stencil);

	NiDX9RenderState* RenderState = TheRenderManager->renderState;
	if (pProp) {
		NiStencilProperty* pStencilProp = static_cast<NiStencilProperty*>(pProp);
		RenderState->SetCullMode(pStencilProp->GetDrawMode());
	}
	else {
		RenderState->SetRenderState(D3DRS_CULLMODE, D3DCULL_CCW, RenderStateArgs);
	}

	TheRenderManager->PackGeometryBuffer(GeoData, ModelData, NULL, ShaderDeclaration);
	if (GeoData && GeoData->VertCount) DrawGeometryBuffer(Geo, GeoData);
}


// draws the geo data from the Geometry buffer
void RenderPass::DrawGeometryBuffer(NiGeometry* Geo, NiGeometryBufferData* GeoData) {
	int StartIndex = 0;
	int PrimitiveCount = 0;

	for (UInt32 i = 0; i < GeoData->StreamCount; i++) {
		TheRenderManager->device->SetStreamSource(i, GeoData->VBChip[i]->VB, 0, GeoData->VertexStride[i]);
	}

	if (GeoData->IB)
		TheRenderManager->device->SetIndices(GeoData->IB);
	if (GeoData->FVF)
		TheRenderManager->renderState->SetFVF(GeoData->FVF, false);
	else
		TheRenderManager->renderState->SetVertexDeclaration(GeoData->VertexDeclaration, false);

	uint16_t dirtyFlags = Geo->geomData->m_usDirtyFlags;
	NiTriStrips* pStrips = Geo->IsTriStrips();
	if (pStrips) {
		ThisStdCall(0xE74840, NiDX9Renderer::GetSingleton(), Geo);  // RenderTriStripsAlt
	}
	else {
		ThisStdCall(0xE745A0, NiDX9Renderer::GetSingleton(), Geo);  // RenderTriShapeAlt
	}
	// Add back the dirty flag that are reset with vanilla render functions.
	Geo->geomData->m_usDirtyFlags = dirtyFlags;
}

void RenderPass::DrawSkinnedGeometryBuffer(NiGeometry* Geo, NiGeometryBufferData* GeoData, NiSkinPartition::Partition* Partition) {
	int StartIndex = 0;
	int PrimitiveCount = 0;

	for (UInt32 i = 0; i < GeoData->StreamCount; i++) {
		TheRenderManager->device->SetStreamSource(i, GeoData->VBChip[i]->VB, 0, GeoData->VertexStride[i]);
	}

	if (GeoData->IB)
		TheRenderManager->device->SetIndices(GeoData->IB);

	if (GeoData->FVF)
		TheRenderManager->renderState->SetFVF(GeoData->FVF, false);
	else
		TheRenderManager->renderState->SetVertexDeclaration(GeoData->VertexDeclaration, false);

	ThisStdCall(0xE6D310, NiDX9Renderer::GetSingleton(), GeoData, Partition, nullptr);  // DrawSkinnedGeometry
}


ShadowRenderPass::ShadowRenderPass() {
	PixelShader = TheShadowManager->ShadowMapPixel;
	VertexShader = TheShadowManager->ShadowMapVertex;
	RegisterConstants();
}


bool ShadowRenderPass::AccumObject(NiGeometry* Geo) {
	if (!Geo->geomData || !Geo->geomData->m_pkBuffData) return false; // discard objects without buffer data

	BSShaderProperty* ShaderProperty = (BSShaderProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);
	if (!ShaderProperty || !ShaderProperty->IsLightingProperty()) return false;

	GeometryList.push(Geo);
	return true;
}


void ShadowRenderPass::RegisterConstants() {
	TheShaderManager->RegisterConstant("TESR_ShadowWorldTransform", (D3DXVECTOR4*)&TheShaderManager->ShaderConst.ShadowWorld);
	//TheTextureManager->RegisterTexture("TESR_DiffuseMap", &Constants.DiffuseMap);
}


void ShadowRenderPass::UpdateConstants(NiGeometry* Geo) {
	ShadowsExteriorEffect::ShadowStruct* ShadowConstants = &TheShaderManager->Effects.ShadowsExteriors->Constants;
	ShadowConstants->Data.x = 0.0f; // Type of geo (0 normal, 1 actors (skinned), 2 speedtree leaves)
	ShadowConstants->Data.y = 0.0f; // Alpha Control
	TheRenderManager->CreateD3DMatrix(&TheShaderManager->ShaderConst.ShadowWorld, &Geo->m_worldTransform);
}



// --- Instancing ----------------------------------------------------------------------------------------------------
// In the sun's cascades the same mesh (one NiGeometryData: rocks, fence posts, poles, walls) is often drawn many times.
// Copies are drawn in one call with D3D9 hardware instancing, as bgfx's D3D9 renderer did: the mesh's streams repeat
// per copy (D3DSTREAMSOURCE_INDEXEDDATA | count) and one more stream steps once per copy (D3DSTREAMSOURCE_INSTANCEDATA)
// with its world matrix, read by ShadowMapInstanced.vso from TEXCOORD12-14.

namespace {
	const UInt32 kInstanceStride = 48;			// three float4: the camera-relative world matrix's columns
	const UInt32 kInstanceCapacity = 16384;		// copies the ring buffer holds
	const UInt32 kMaxPerDraw = 1024;

	IDirect3DVertexBuffer9* InstanceBuffer = nullptr;
	UInt32 InstanceCursor = 0;
	bool InstancingFailed = false;				// the buffer could not be made: draw one by one
	std::unordered_map<IDirect3DVertexDeclaration9*, IDirect3DVertexDeclaration9*> InstancedDeclarations;

	// The mesh's declaration plus the instance stream; nullptr when the mesh's own elements are in the way.
	IDirect3DVertexDeclaration9* InstancedDeclaration(IDirect3DVertexDeclaration9* Base, UInt32 Stream) {
		auto known = InstancedDeclarations.find(Base);
		if (known != InstancedDeclarations.end()) return known->second;
		IDirect3DVertexDeclaration9* result = nullptr;
		D3DVERTEXELEMENT9 elements[MAXD3DDECLLENGTH + 4];
		UINT count = 0;
		if (SUCCEEDED(Base->GetDeclaration(nullptr, &count)) && count >= 1 && count <= MAXD3DDECLLENGTH && SUCCEEDED(Base->GetDeclaration(elements, &count))) {
			const UINT used = count - 1;   // without D3DDECL_END
			bool clash = false;
			for (UINT i = 0; i < used; i++)
				if (elements[i].Stream >= Stream || (elements[i].Usage == D3DDECLUSAGE_TEXCOORD && elements[i].UsageIndex >= 12)) clash = true;
			if (!clash) {
				for (UINT k = 0; k < 3; k++)
					elements[used + k] = { (WORD)Stream, (WORD)(k * 16), D3DDECLTYPE_FLOAT4, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, (BYTE)(12 + k) };
				const D3DVERTEXELEMENT9 end = D3DDECL_END();
				elements[used + 3] = end;
				if (FAILED(TheRenderManager->device->CreateVertexDeclaration(elements, &result))) result = nullptr;
			}
		}
		Base->AddRef();   // kept alive as the key, so its address is never another declaration's
		InstancedDeclarations[Base] = result;
		return result;
	}

	// The copies' matrices, into the ring buffer; the byte offset where they start.
	bool WriteInstances(NiGeometry** Group, UInt32 Count, UInt32& Offset) {
		if (!InstanceBuffer) {
			if (InstancingFailed) return false;
			if (FAILED(TheRenderManager->device->CreateVertexBuffer(kInstanceCapacity * kInstanceStride, D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY, 0, D3DPOOL_DEFAULT, &InstanceBuffer, NULL))) {
				InstanceBuffer = nullptr;
				InstancingFailed = true;
				Logger::Log("[ERROR] Shadow map instancing: could not create the instance buffer; meshes are drawn one by one.");
				return false;
			}
			InstanceCursor = 0;
		}
		DWORD flags = D3DLOCK_NOOVERWRITE;
		if (InstanceCursor + Count > kInstanceCapacity) {
			InstanceCursor = 0;
			flags = D3DLOCK_DISCARD;
		}
		void* data = nullptr;
		if (FAILED(InstanceBuffer->Lock(InstanceCursor * kInstanceStride, Count * kInstanceStride, &data, flags)) || !data) return false;
		float* out = (float*)data;
		for (UInt32 i = 0; i < Count; i++, out += 12) {
			D3DXMATRIX m;
			TheRenderManager->CreateD3DMatrix(&m, &Group[i]->m_worldTransform);   // camera-relative, row vectors
			out[0] = m._11; out[1] = m._21; out[2] = m._31; out[3] = m._41;
			out[4] = m._12; out[5] = m._22; out[6] = m._32; out[7] = m._42;
			out[8] = m._13; out[9] = m._23; out[10] = m._33; out[11] = m._43;
		}
		InstanceBuffer->Unlock();
		Offset = InstanceCursor * kInstanceStride;
		InstanceCursor += Count;
		return true;
	}

	// What RenderGeometry sets the cull mode from: the stencil property's draw mode, -1 without one.
	int CullKey(NiGeometry* Geo) {
		NiProperty* pProp = Geo->GetProperty(NiProperty::PropertyType::kType_Stencil);
		return pProp ? (int)static_cast<NiStencilProperty*>(pProp)->GetDrawMode() : -1;
	}
}


void ShadowRenderPass::RenderSingle(NiGeometry* Geo) {
	TheRenderManager->renderState->SetVertexShader(VertexShader->ShaderHandle, false);
	UpdateConstants(Geo);
	PixelShader->SetCT();
	VertexShader->SetCT();
	RenderGeometry(Geo);
}


// All of Group share their mesh data and cull mode. False when they cannot be instanced (drawn one by one instead).
bool ShadowRenderPass::RenderInstanced(NiGeometry** Group, UInt32 Count) {
	NiGeometry* First = Group[0];
	NiGeometryData* ModelData = First->geomData;
	NiGeometryBufferData* GeoData = ModelData->m_pkBuffData;
	if (!GeoData || !First->shader) return false;

	TheRenderManager->PackGeometryBuffer(GeoData, ModelData, NULL, First->shader->ShaderDeclaration);
	if (!GeoData->VertCount || !GeoData->IB || GeoData->FVF || !GeoData->VertexDeclaration || !GeoData->NumArrays ||
		GeoData->StreamCount < 1 || GeoData->StreamCount > 8) return false;
	const UInt32 stream = GeoData->StreamCount;
	IDirect3DVertexDeclaration9* declaration = InstancedDeclaration(GeoData->VertexDeclaration, stream);
	if (!declaration) return false;

	IDirect3DDevice9* Device = TheRenderManager->device;
	NiDX9RenderState* RenderState = TheRenderManager->renderState;
	ShaderRecordVertex* Instanced = TheShadowManager->ShadowMapInstancedVertex;

	// The cull mode, as RenderGeometry sets it.
	if (NiProperty* pProp = First->GetProperty(NiProperty::PropertyType::kType_Stencil))
		RenderState->SetCullMode(static_cast<NiStencilProperty*>(pProp)->GetDrawMode());
	else
		RenderState->SetRenderState(D3DRS_CULLMODE, D3DCULL_CCW, RenderStateArgs);

	UpdateConstants(First);   // TESR_ShadowData as for any plain mesh (its world matrix goes unused)
	RenderState->SetVertexShader(Instanced->ShaderHandle, false);
	PixelShader->SetCT();
	Instanced->SetCT();

	for (UInt32 done = 0; done < Count;) {
		const UInt32 n = min(Count - done, kMaxPerDraw);
		UInt32 offset = 0;
		if (!WriteInstances(Group + done, n, offset)) {
			// No room or no buffer: the rest one by one.
			for (UInt32 i = done; i < Count; i++) RenderSingle(Group[i]);
			return true;
		}
		for (UInt32 i = 0; i < stream; i++) {
			Device->SetStreamSource(i, GeoData->VBChip[i]->VB, 0, GeoData->VertexStride[i]);
			Device->SetStreamSourceFreq(i, D3DSTREAMSOURCE_INDEXEDDATA | n);
		}
		Device->SetStreamSource(stream, InstanceBuffer, offset, kInstanceStride);
		Device->SetStreamSourceFreq(stream, D3DSTREAMSOURCE_INSTANCEDATA | 1u);
		Device->SetIndices(GeoData->IB);
		RenderState->SetVertexDeclaration(declaration, false);

		// As the game's RenderTriShape/RenderTriStrips draw it (0xE745A0): one call per strip, or one for the list.
		UInt32 start = 0;
		for (UInt32 k = 0; k < GeoData->NumArrays; k++) {
			const UInt32 primitives = GeoData->ArrayLengths ? (UInt32)GeoData->ArrayLengths[k] - 2 : GeoData->TriCount;
			Device->DrawIndexedPrimitive(GeoData->PrimitiveType, GeoData->BaseVertexIndex, 0, GeoData->VertCount, start, primitives);
			start += primitives + 2;
		}
		done += n;
	}

	// Back to one copy per draw for everything after.
	for (UInt32 i = 0; i <= stream; i++) Device->SetStreamSourceFreq(i, 1);
	Device->SetStreamSource(stream, NULL, 0, 0);
	return true;
}


void ShadowRenderPass::RenderAccum() {
	if (GeometryList.empty()) return;
	ShadowsExteriorEffect* Shadows = TheShaderManager->Effects.ShadowsExteriors;
	if (!TheShadowManager->ShadowMapInstancedVertex || VertexShader != TheShadowManager->ShadowMapVertex ||
		!Shadows || !Shadows->Settings.ShadowMaps.Instancing || InstancingFailed) {
		RenderPass::RenderAccum();   // cube maps (their own shader), or instancing off
		return;
	}

	Items.clear();
	while (!GeometryList.empty()) {
		if (NiGeometry* Geo = GeometryList.top()) Items.push_back(Geo);
		GeometryList.pop();
	}
	// Copies of one mesh next to each other (the order does not matter in a depth map).
	std::sort(Items.begin(), Items.end(), [](NiGeometry* a, NiGeometry* b) {
		if (a->geomData != b->geomData) return a->geomData < b->geomData;
		return CullKey(a) < CullKey(b);
	});

	NiDX9RenderState* RenderState = TheRenderManager->renderState;
	RenderState->SetPixelShader(PixelShader->ShaderHandle, false);
	for (size_t i = 0; i < Items.size();) {
		size_t j = i + 1;
		const int cull = CullKey(Items[i]);
		while (j < Items.size() && Items[j]->geomData == Items[i]->geomData && CullKey(Items[j]) == cull) j++;
		if (j - i < 2 || !RenderInstanced(&Items[i], (UInt32)(j - i)))
			for (size_t k = i; k < j; k++) RenderSingle(Items[k]);
		i = j;
	}
	Items.clear();
}


AlphaShadowRenderPass::AlphaShadowRenderPass() {
	PixelShader = TheShadowManager->ShadowMapPixel;
	VertexShader = TheShadowManager->ShadowMapVertex;
	RegisterConstants();
}


bool AlphaShadowRenderPass::AccumObject(NiGeometry* Geo) {
	if (!Geo->geomData || !Geo->geomData->m_pkBuffData) return false; // discard objects without buffer data

	BSShaderProperty* ShaderProperty = (BSShaderProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);
	NiAlphaProperty* AProp = (NiAlphaProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Alpha);

	if (!ShaderProperty || !ShaderProperty->IsLightingProperty()) return false;
	if (!AProp) return false;
	if (!(AProp->flags & NiAlphaProperty::AlphaFlags::ALPHA_BLEND_MASK) && !(AProp->flags & NiAlphaProperty::AlphaFlags::TEST_ENABLE_MASK)) return false;

	GeometryList.push(Geo);
	return true;
}


void AlphaShadowRenderPass::RegisterConstants() {
}


void AlphaShadowRenderPass::UpdateConstants(NiGeometry* Geo) {
	ShadowsExteriorEffect::ShadowStruct* ShadowConstants = &TheShaderManager->Effects.ShadowsExteriors->Constants;
	ShadowConstants->Data.x = 0.0f; // Type of geo (0 normal, 1 actors (skinned), 2 speedtree leaves)
	ShadowConstants->Data.y = 0.0f; // Alpha Control
	TheRenderManager->CreateD3DMatrix(&TheShaderManager->ShaderConst.ShadowWorld, &Geo->m_worldTransform);

	BSShaderProperty* ShaderProperty = (BSShaderProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);
	NiTexture* Texture = *((BSShaderPPLightingProperty*)ShaderProperty)->ppTextures[0];

	if (Texture && Texture->rendererData->dTexture) {

		ShadowConstants->Data.y = 1.0f; // Alpha Control
//			Constants.DiffuseMap = Texture->rendererData->dTexture;

		//// Set diffuse texture at register 0
		NiDX9RenderState* RenderState = TheRenderManager->renderState;
		RenderState->SetTexture(0, Texture->rendererData->dTexture);
		RenderState->SetSamplerState(0, D3DSAMP_ADDRESSU, D3DTADDRESS_WRAP, false);
		RenderState->SetSamplerState(0, D3DSAMP_ADDRESSV, D3DTADDRESS_WRAP, false);
		RenderState->SetSamplerState(0, D3DSAMP_MAGFILTER, D3DTEXF_POINT, false);
		RenderState->SetSamplerState(0, D3DSAMP_MINFILTER, D3DTEXF_POINT, false);
		RenderState->SetSamplerState(0, D3DSAMP_MIPFILTER, D3DTEXF_POINT, false);
	}
}


SkinnedGeoShadowRenderPass::SkinnedGeoShadowRenderPass() {
	PixelShader = TheShadowManager->ShadowMapPixel;
	VertexShader = TheShadowManager->ShadowMapVertex;
	RegisterConstants();
}


bool SkinnedGeoShadowRenderPass::AccumObject(NiGeometry* Geo) {
	// check data for rigged geometry
	if (!Geo->skinInstance)
		return false;

	NiSkinInstance* skinInstance = Geo->skinInstance;
	if (skinInstance->IsKindOf<BSDismemberSkinInstance>() && !((BSDismemberSkinInstance*)skinInstance)->IsRenderable)
		return true;

	if (Geo->skinInstance->SkinPartition && Geo->skinInstance->SkinPartition->Partitions) {

		// only accum if valid data preset
		//if (Geo->skinInstance->SkinPartition->Partitions[0].BuffData)
			GeometryList.push(Geo);
	
		// we return true in any case because we still found skinned geo either way
		return true;
	}

	return false;
}


void SkinnedGeoShadowRenderPass::RegisterConstants() {
	//TheShaderManager->RegisterConstant("TESR_Bones", NULL);
}


void SkinnedGeoShadowRenderPass::UpdateConstants(NiGeometry* Geo) {
	// Render skinned geometry
	ShadowsExteriorEffect::ShadowStruct* Constants = &TheShaderManager->Effects.ShadowsExteriors->Constants;
	Constants->Data.x = 1.0f; // Type of geo (0 normal, 1 actors (skinned), 2 speedtree leaves)
	Constants->Data.y = 0.0f; // Alpha control
	TheRenderManager->CreateD3DMatrix(&TheShaderManager->ShaderConst.ShadowWorld, &Geo->m_worldTransform);
}


void SkinnedGeoShadowRenderPass::RenderGeometry(NiGeometry* Geo) {
	NiGeometryData* ModelData = Geo->geomData;
	NiGeometryBufferData* GeoData = ModelData->m_pkBuffData;
	NiSkinInstance* SkinInstance = Geo->skinInstance;
	NiD3DShaderDeclaration* ShaderDeclaration = Geo->shader->ShaderDeclaration;

	// Set proper cull based on stencil property.
	NiProperty* pProp = Geo->GetProperty(NiProperty::PropertyType::kType_Stencil);

	NiDX9RenderState* RenderState = TheRenderManager->renderState;
	if (pProp) {
		NiStencilProperty* pStencilProp = static_cast<NiStencilProperty*>(pProp);
		RenderState->SetCullMode(pStencilProp->GetDrawMode());
	}
	else {
		RenderState->SetRenderState(D3DRS_CULLMODE, D3DCULL_CCW, RenderStateArgs);
	}

	NiSkinPartition* SkinPartition = SkinInstance->SkinPartition;
	TheRenderManager->CalculateBoneMatrixes(SkinInstance, &Geo->m_worldTransform);
	
	if (SkinInstance->SkinToWorldWorldToSkin) 
		memcpy(&TheShaderManager->Effects.ShadowsExteriors->Constants.ShadowWorld, SkinInstance->SkinToWorldWorldToSkin, 0x40);

	DismemberPartition* pDismemberPartition = NULL;
	if (SkinInstance->IsKindOf<BSDismemberSkinInstance>())
		pDismemberPartition = ((BSDismemberSkinInstance*)SkinInstance)->partitions;

	for (UInt32 p = 0; p < SkinPartition->PartitionsCount; p++) {
		if (pDismemberPartition && !pDismemberPartition[p].Enabled)
			continue;

		NiSkinPartition::Partition* Partition = &SkinPartition->Partitions[p];
		if (!Partition)
			continue;

		GeoData = Partition->BuffData;
		if (GeoData) {
			//Constants.BoneMatrices = (D3DXVECTOR4*)SkinInstance->BoneMatrixes;
			int StartRegister = 9;
			for (int i = 0; i < Partition->Bones; i++) {
				UInt16 NewIndex = (Partition->pBones == NULL) ? i : Partition->pBones[i];
				TheRenderManager->device->SetVertexShaderConstantF(StartRegister, ((float*)SkinInstance->BoneMatrixes) + (NewIndex * 3 * 4), 3);
				StartRegister += 3;
			}

			//TheRenderManager->PackSkinnedGeometryBuffer(GeoData, ModelData, SkinInstance, Partition, ShaderDeclaration);
			DrawSkinnedGeometryBuffer(Geo, GeoData, Partition);
		}

		if (!pDismemberPartition)
			continue;

		for (UInt32 d = p + 1; d < SkinPartition->PartitionsCount; d++) {
			if (pDismemberPartition[p + 1].StartCap)
				break;

			++p;
			++Partition;
			if (pDismemberPartition[p].Enabled) {
				int StartRegister = 9;
				GeoData = Partition->BuffData;
				if (GeoData) {
					for (int i = 0; i < Partition->Bones; i++) {
						UInt16 NewIndex = (Partition->pBones == NULL) ? i : Partition->pBones[i];
						TheRenderManager->device->SetVertexShaderConstantF(StartRegister, ((float*)SkinInstance->BoneMatrixes) + (NewIndex * 3 * 4), 3);
						StartRegister += 3;
					}


					DrawSkinnedGeometryBuffer(Geo, GeoData, Partition);
				}
			}

		}
	}
}


SpeedTreeShadowRenderPass::SpeedTreeShadowRenderPass() {
	PixelShader = TheShadowManager->ShadowMapPixel;
	VertexShader = TheShadowManager->ShadowMapVertex;
	RegisterConstants();
}


void SpeedTreeShadowRenderPass::RegisterConstants() {
	//TheShaderManager->RegisterConstant("TESR_BillboardRight", Constants.BillboardRight);
	//TheShaderManager->RegisterConstant("TESR_BillboardUp", Constants.BillboardUp);
	//TheShaderManager->RegisterConstant("TESR_RockParams", (D3DXVECTOR4*)Pointers::ShaderParams::RockParams);
	//TheShaderManager->RegisterConstant("TESR_RustleParams", (D3DXVECTOR4*)Pointers::ShaderParams::RustleParams);
	//TheShaderManager->RegisterConstant("TESR_WindMatrices", (D3DXVECTOR4*)Pointers::ShaderParams::WindMatrixes);
	//TheShaderManager->RegisterConstant("TESR_LeafBase", Constants.LeafBase);
	//TheTextureManager->RegisterTexture("TESR_LeafDiffuseMap", &Constants.DiffuseMap);
}


bool SpeedTreeShadowRenderPass::AccumObject(NiGeometry* Geo) {

	NiShadeProperty* shaderProp = static_cast<NiShadeProperty*>(Geo->GetProperty(NiProperty::kType_Shade));
	if (shaderProp->m_eShaderType != NiShadeProperty::kProp_SpeedTreeLeaf) return false;

	GeometryList.push(Geo);
	return true;
}


void SpeedTreeShadowRenderPass::UpdateConstants(NiGeometry* Geo) {

	ShadowsExteriorEffect::ShadowStruct* ShadowConstants = &TheShaderManager->Effects.ShadowsExteriors->Constants;
	IDirect3DDevice9* Device = TheRenderManager->device;
	NiDX9RenderState* RenderState = TheRenderManager->renderState;

	ShadowConstants->Data.x = 2.0f; // Type of geo (0 normal, 1 actors (skinned), 2 speedtree leaves)
	ShadowConstants->Data.y = 0.0f; // Alpha control
	TheRenderManager->CreateD3DMatrix(&TheShaderManager->ShaderConst.ShadowWorld, &Geo->m_worldTransform);

	// Bind constant values for leaf transformation
	Device->SetVertexShaderConstantF(63, (float*)&TheShadowManager->BillboardRight, 1);
	Device->SetVertexShaderConstantF(64, (float*)&TheShadowManager->BillboardUp, 1);
	Device->SetVertexShaderConstantF(65, Pointers::ShaderParams::RockParams, 1);
	Device->SetVertexShaderConstantF(66, Pointers::ShaderParams::RustleParams, 1);
	Device->SetVertexShaderConstantF(67, Pointers::ShaderParams::WindMatrixes, 16);

	SpeedTreeLeafShaderProperty* STProp = (SpeedTreeLeafShaderProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);
	BSTreeNode* Node = (BSTreeNode*)Geo->m_parent->m_parent;
	NiDX9SourceTextureData* Texture = (NiDX9SourceTextureData*)Node->TreeModel->LeavesTexture->rendererData;

	if (Texture) ShadowConstants->Data.y = 1.0f;

	// Bind constant values for leaf transformation
	Device->SetVertexShaderConstantF(83, STProp->leafData->leafBase, 48);
	
	// Set diffuse texture at register 0
	RenderState->SetTexture(0, Texture->dTexture);
	RenderState->SetSamplerState(0, D3DSAMP_ADDRESSU, D3DTADDRESS_WRAP, false);
	RenderState->SetSamplerState(0, D3DSAMP_ADDRESSV, D3DTADDRESS_WRAP, false);
	RenderState->SetSamplerState(0, D3DSAMP_MAGFILTER, D3DTEXF_POINT, false);
	RenderState->SetSamplerState(0, D3DSAMP_MINFILTER, D3DTEXF_POINT, false);
	RenderState->SetSamplerState(0, D3DSAMP_MIPFILTER, D3DTEXF_POINT, false);
}


TerrainLODPass::TerrainLODPass() {
	PixelShader = TheShadowManager->ShadowMapPixel;
	VertexShader = TheShadowManager->ShadowMapVertex;
	RegisterConstants();
}


bool TerrainLODPass::AccumObject(NiGeometry* Geo) {
	if (!Geo->geomData || !Geo->geomData->m_pkBuffData) return false; // discard objects without buffer data

	BSShaderProperty* ShaderProperty = (BSShaderProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);
	if (!ShaderProperty || !ShaderProperty->IsLightingProperty()) return false;

	GeometryList.push(Geo);
	return true;
}


void TerrainLODPass::UpdateConstants(NiGeometry* Geo) {
	ShadowsExteriorEffect::ShadowStruct* ShadowConstants = &TheShaderManager->Effects.ShadowsExteriors->Constants;
	ShadowConstants->Data.x = 3.0f; // Type of geo (0 normal, 1 actors (skinned), 2 speedtree leaves, 3 terrain LOD)
	ShadowConstants->Data.y = 0.0f; // Alpha Control
	TheRenderManager->CreateD3DMatrix(&TheShaderManager->ShaderConst.ShadowWorld, &Geo->m_worldTransform);
	D3DXMatrixTranspose(&Constants.WorldTranspose, &TheShaderManager->ShaderConst.ShadowWorld);

	BSShaderPPLightingProperty* prop = (BSShaderPPLightingProperty*)Geo->GetProperty(NiProperty::PropertyType::kType_Shade);

	Constants.LODLandParams.x = prop->fMorphDistance;
	Constants.LODLandParams.y = *BSShaderManager::fLODLandDrop;

	Constants.HighDetailRange.x = BSShaderManager::kLoadedRange->x - BSShaderManager::kCameraPos->x;
	Constants.HighDetailRange.y = BSShaderManager::kLoadedRange->y - BSShaderManager::kCameraPos->y;
	Constants.HighDetailRange.z = BSShaderManager::kLoadedRange->z - 15;
	Constants.HighDetailRange.w = BSShaderManager::kLoadedRange->w - 15;

	IDirect3DDevice9* Device = TheRenderManager->device;
	Device->SetVertexShaderConstantF(140, (float*)&Constants.WorldTranspose, 4);
	Device->SetVertexShaderConstantF(144, (float*)&Constants.HighDetailRange, 1);
	Device->SetVertexShaderConstantF(145, (float*)&Constants.LODLandParams, 1);
}
