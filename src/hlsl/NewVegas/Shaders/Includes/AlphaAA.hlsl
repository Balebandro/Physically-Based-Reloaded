// Anti-aliased alpha test on grass and leaves without MSAA ([Main.Main.Misc] AlphaAA; Hooks/Shaders.cpp AlphaAA).
// x: 1 while the draw blends instead of testing (set per draw, 0 otherwise), y: the draw's alpha test reference (0-1).
// The alpha ramps from 0 at the vanilla cutoff to 1 one pixel inside it, so the pixels drawn are vanilla's and the
// edge blends instead of stepping. Off: vanilla's alpha, for the game's own test (or alpha to coverage under MSAA).
#ifndef ALPHAAA_INCLUDED
#define ALPHAAA_INCLUDED

float4 TESR_AlphaAA : register(c222);

// Top level of main only: fwidth is a derivative.
float AlphaAA(float alpha) {
    float ramp = saturate((alpha - TESR_AlphaAA.y) / max(fwidth(alpha), 1e-4f));
    return TESR_AlphaAA.x > 0.5f ? ramp : alpha;
}

#endif
