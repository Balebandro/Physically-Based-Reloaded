// Opaque casters only. ShadowManager::Initialize loads this file as ShadowMapOpaque.pso.
// ShadowMap.pso.hlsl without the alpha test: that shader's discard disables early-Z for every caster in the pass,
// and an opaque caster never reaches it (TESR_ShadowData.y is 0). Keep the rest identical to ShadowMap.pso.hlsl.

// Must match [_Shaders.ShadowsExteriors.ShadowMaps] Mode, and SHADOW_FIXED_MODE in
// Shaders/Includes/Shadow.hlsl which decodes what this writes.
//   0 = VSM, 1 = EVSM2, 2 = EVSM4 (toml default)
#ifndef SHADOW_FIXED_MODE
    #define SHADOW_FIXED_MODE 2
#endif

float4 TESR_ShadowData : register(c0);
float4 TESR_ShadowFormatData : register(c1);

sampler2D DiffuseMap : register(s0) = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = POINT; };

static const float FormatBits = TESR_ShadowFormatData.y;

float2 GetEVSMExponents(in float positiveExponent, in float negativeExponent) {
    const float maxExponent = FormatBits == 0.0 ? 5.54f : 42.0f;

    float2 lightSpaceExponents = float2(positiveExponent, negativeExponent);

    // Clamp to maximum range of fp32/fp16 to prevent overflow/underflow
    return min(lightSpaceExponents, maxExponent);
}

// Applies exponential warp to shadow map depth, input depth should be in [0, 1]
float2 WarpDepth(float depth, float2 exponents) {
    // Rescale depth into [-1, 1]
    depth = 2.0f * depth - 1.0f;
    float pos = exp(exponents.x * depth);
    float neg = -exp(-exponents.y * depth);
    return float2(pos, neg);
}

struct VS_OUTPUT {
    float4 texcoord_0 : TEXCOORD0;
	float4 texcoord_1 : TEXCOORD1;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(VS_OUTPUT IN) {
    PS_OUTPUT OUT;

	
	float depth = IN.texcoord_0.z / IN.texcoord_0.w;

	// Mode is a session-wide setting, so it is resolved at COMPILE time. As a runtime branch
	// ps_3_0 flattened it, and every shadow-map texel evaluated VSM, EVSM2 and EVSM4 before
	// discarding two of them -- 40 instruction slots, down to 24 once folded.
	//
	// TESR_ShadowData.z stays a runtime test: it marks the ortho map, which is rendered in the
	// same frame as the cascades and wants plain depth.
	if (TESR_ShadowData.z) {
		// Ortho map: only depth.
		OUT.color_0 = float4(depth, 0.0f, 0.0f, 1.0f);
	}
	else {
#if SHADOW_FIXED_MODE == 0
		// VSM. Cheat to reduce shadow acne in variance maps.
		float dx = ddx(depth);
		float dy = ddy(depth);
		float moment2 = depth * depth + 0.25 * (dx * dx + dy * dy);
		OUT.color_0 = float4(depth, moment2, 0.0f, 1.0f);
#elif SHADOW_FIXED_MODE == 1
		// EVSM2
		float2 exponents = GetEVSMExponents(40.0f, 5.0f);
		float2 evsm2 = WarpDepth(depth, exponents);
		OUT.color_0 = float4(evsm2, 0.0f, 1.0f);
#else
		// EVSM4
		float2 exponents = GetEVSMExponents(40.0f, 5.0f);
		float2 evsm2 = WarpDepth(depth, exponents);
		OUT.color_0 = float4(evsm2, evsm2 * evsm2);
#endif
	}

	return OUT;	
};
