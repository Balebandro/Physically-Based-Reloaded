// UNOFFICIAL 2026-11-04 soft particles (after Vanilla Plus Particles, pr0bability, GPL-3.0): an unlit draw fades where the scene
// behind it is nearer than its own size x SoftScale, so smoke, dust and glow cards no longer cut a hard line into the ground and
// walls. The world's depth is copied as the first NOLIGHT pixel shader of the world scene binds (effects/Particles); the size
// comes from the vertex shader: a particle's own (core/ParticleSize.h), a mesh's bound radius (ForDraw), 0 when not blended.
// Include after Shadow.hlsl when both are used (it declares the inverse projection).

#ifndef SHADOW_INVPROJ_REG
row_major float4x4 TESR_InvProjectionTransform : register(c100);
#endif
float4 TESR_ParticleSoft : register(c175);   // x: soft scale (0: off for this draw), yz: 1 / resolution
sampler2D TESR_ParticleDepth : register(s15) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

// depthSize: x the draw's view depth (clip w), y its soft size (0: not soft). 1 = no fade.
float SoftParticleFade(float2 screenPos, float2 depthSize) {
    [branch] if (TESR_ParticleSoft.x <= 0.0f || depthSize.y <= 0.0f) return 1.0f;
    // The scene's view depth through the inverse projection (as terrain blending's terrainBlendViewDepth).
    const float depth = tex2Dlod(TESR_ParticleDepth, float4((screenPos + 0.5f) * TESR_ParticleSoft.yz, 0.0f, 0.0f)).x;
    const float2 zw = depth * float2(TESR_InvProjectionTransform[2][2], TESR_InvProjectionTransform[2][3]) +
        float2(TESR_InvProjectionTransform[3][2], TESR_InvProjectionTransform[3][3]);
    return saturate((abs(zw.x / zw.y) - depthSize.x) / (depthSize.y * TESR_ParticleSoft.x));
}
