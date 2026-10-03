// Merged light passes: the lamps the game would add to a mesh in extra additive passes, lit in its
// light-only pass instead so they sum in linear space ([Shaders.PBR.Main] MergeLightPasses; see
// MergedLights in NewVegas/Hooks/Shaders.cpp). Written per draw by the hook, not through the
// TESR_ constant table. Two arrays, not one interleaved: ps_3_0 indexes constants only by the
// loop counter, with a stride of 1.
#ifndef MERGEDLIGHTS_INCLUDED
#define MERGEDLIGHTS_INCLUDED

#define MERGED_MAX_LIGHTS 16

float4 TESR_MergedLightCount : register(c154);                       // x lights (0: none), y 1 when the highlight passes are merged too
float4 TESR_MergedLightPosition[MERGED_MAX_LIGHTS] : register(c155);   // xyz camera-relative position, w radius
float4 TESR_MergedLightColor[MERGED_MAX_LIGHTS] : register(c171);      // rgb colour, gamma, as PSLightColor

#endif
