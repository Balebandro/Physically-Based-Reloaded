#pragma once
#include <unordered_set>

class RenderPass {
public:
	RenderPass() {};
	virtual ~RenderPass() {
		VertexShader = NULL;
		PixelShader = NULL;
	};

	ShaderRecordVertex* VertexShader;
	ShaderRecordPixel* PixelShader;

	std::stack<NiGeometry*>	GeometryList;
	virtual bool AccumObject(NiGeometry* Geo) { return true; };
	virtual void UpdateConstants(NiGeometry* Geo) {};
	virtual void RenderGeometry(NiGeometry* Geo);
	virtual void RegisterConstants() {};

	void DrawGeometryBuffer(NiGeometry* Geo, NiGeometryBufferData* GeoData);
	void DrawSkinnedGeometryBuffer(NiGeometry* Geo, NiGeometryBufferData* GeoData, NiSkinPartition::Partition* Partition);
	void RenderAccum();

	// Terrain blending's ShadowDrop: the loaded land's geometry in the sun shadow map being drawn, and how far down
	// it is drawn there (ShadowManager::RenderShadowMap; 0 off).
	static inline float LandDrop = 0.0f;
	static inline std::unordered_set<NiGeometry*> LandSet;
};


class ShadowRenderPass : public RenderPass {
public:
	ShadowRenderPass();

	struct ConstantsStruct {
	};
	ConstantsStruct Constants;

	bool AccumObject(NiGeometry* Geo);
	void RegisterConstants();
	void UpdateConstants(NiGeometry* Geo);
	void RenderAccum();		// hides RenderPass::RenderAccum: in the sun's cascades, copies of one mesh are drawn together

private:
	void RenderSingle(NiGeometry* Geo);
	bool RenderInstanced(NiGeometry** Group, UInt32 Count);
	std::vector<NiGeometry*> Items;
};

class AlphaShadowRenderPass : public RenderPass {
public:
	AlphaShadowRenderPass();

	struct ConstantsStruct {
		IDirect3DBaseTexture9* DiffuseMap;
	};
	ConstantsStruct Constants;

	bool AccumObject(NiGeometry* Geo);
	void RegisterConstants();
	void UpdateConstants(NiGeometry* Geo);
};


class SkinnedGeoShadowRenderPass : public RenderPass {
public:
	SkinnedGeoShadowRenderPass();

	struct ConstantsStruct {
		D3DXVECTOR4* BoneMatrices;
	};
	ConstantsStruct Constants;

	bool AccumObject(NiGeometry* Geo);
	void RegisterConstants();
	void UpdateConstants(NiGeometry* Geo);
	void RenderGeometry(NiGeometry* Geo);
};


class SpeedTreeShadowRenderPass : public RenderPass {
public:
	SpeedTreeShadowRenderPass();

	struct ConstantsStruct {
		D3DXVECTOR4* BillboardRight;
		D3DXVECTOR4* BillboardUp;
		D3DXVECTOR4* LeafBase;
		IDirect3DBaseTexture9* DiffuseMap;
	};
	ConstantsStruct Constants;

	bool AccumObject(NiGeometry* Geo);
	void RegisterConstants(); 
	void UpdateConstants(NiGeometry* Geo);
};


class TerrainLODPass : public RenderPass {
public:
	TerrainLODPass();

	struct ConstantsStruct {
		D3DXMATRIX	WorldTranspose;
		D3DXVECTOR4 LODLandParams;
		D3DXVECTOR4 HighDetailRange;
	};
	ConstantsStruct Constants;

	bool AccumObject(NiGeometry* Geo);
	void UpdateConstants(NiGeometry* Geo);
};