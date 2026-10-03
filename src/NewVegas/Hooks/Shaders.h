#pragma once

extern VirtFuncDetour kSkyShaderConstantsDetour;
void __fastcall SkyShader__UpdateConstants(SkyShader* apThis, void*, const NiPropertyState* apProperties);

extern VirtFuncDetour kSkinPrepareGeometryDetour;
extern VirtFuncDetour kSkinPostGeometryDetour;
void* __fastcall SkinShader__PrepareGeometryForRendering(void* apThis, void*, void* apGeometry, void* apPartition, void* apRendererData, void* apState);
void __fastcall SkinShader__PostGeometry(void* apThis, void*, void* apProperties);
void InstallFaceGenInteriorPatch();
void WriteObjectMaterial(NiGeometry* Geometry);
extern VirtFuncDetour kLightPrepareGeometryDetour;
extern VirtFuncDetour kLightPostGeometryDetour;
void* __fastcall ShadowLightShader__PrepareGeometryForRendering(void* apThis, void*, void* apGeometry, void* apPartition, void* apRendererData, void* apState);
void __fastcall ShadowLightShader__PostGeometry(void* apThis, void*, void* apProperties);
extern VirtFuncDetour kParallaxPrepareGeometryDetour;
extern VirtFuncDetour kParallaxPostGeometryDetour;
void* __fastcall ParallaxShader__PrepareGeometryForRendering(void* apThis, void*, void* apGeometry, void* apPartition, void* apRendererData, void* apState);
void __fastcall ParallaxShader__PostGeometry(void* apThis, void*, void* apProperties);
extern VirtFuncDetour kHairPrepareGeometryDetour;
extern VirtFuncDetour kHairPostGeometryDetour;
void* __fastcall HairShader__PrepareGeometryForRendering(void* apThis, void*, void* apGeometry, void* apPartition, void* apRendererData, void* apState);
void __fastcall HairShader__PostGeometry(void* apThis, void*, void* apProperties);
void UpdateFaceGenInteriorFlag();
