
// The sun cascades and the ortho map: plain depth (the cascades are read with PCF, Shaders/Includes/Shadow.hlsl).

float4 TESR_ShadowData : register(c0);

sampler2D DiffuseMap : register(s0) = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = POINT; };

struct VS_OUTPUT {
    float4 texcoord_0 : TEXCOORD0;
	float4 texcoord_1 : TEXCOORD1;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(VS_OUTPUT IN) {
    PS_OUTPUT OUT;

	if (TESR_ShadowData.y == 1.0f) { // Leaves (Speedtrees) or alpha is required
		float4 diffuse = tex2D(DiffuseMap, IN.texcoord_1.xy);
        if (diffuse.a < 0.5f)
            discard;
    }
	
	float depth = IN.texcoord_0.z / IN.texcoord_0.w;

	OUT.color_0 = float4(depth, 0.0f, 0.0f, 1.0f);

	return OUT;	
};