// ShadowMap.vso's plain-mesh path (TESR_ShadowData.x 0) for many copies of one mesh in one draw: hardware instancing
// (ShadowRenderPass::RenderAccum). Each copy's camera-relative world matrix arrives in a second vertex stream, one
// row of the transposed 3x4 per TEXCOORD12-14, instead of TESR_ShadowWorldTransform. ShadowMap.pso is unchanged.

row_major float4x4 TESR_ShadowViewProjTransform : register(c4);

struct VS_INPUT {
    float4 position : POSITION;
    float4 texcoord_0 : TEXCOORD0;
    float4 world0 : TEXCOORD12;    // the world matrix's first column (x' = dot(world0, position)), and so on
    float4 world1 : TEXCOORD13;
    float4 world2 : TEXCOORD14;
};

struct VS_OUTPUT {
    float4 position : POSITION;
    float4 texcoord_0 : TEXCOORD0;
    float4 texcoord_1 : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float4 r0 = float4(IN.position.xyz, 1.0f);
    r0 = float4(dot(IN.world0, r0), dot(IN.world1, r0), dot(IN.world2, r0), 1.0f);
    r0 = mul(r0, TESR_ShadowViewProjTransform);

    // Pancaking to ensure geometry outside of near plane is not culled.
    r0.z = max(r0.z, 0.0f);

    OUT.position = r0;
    OUT.texcoord_0 = r0;
    OUT.texcoord_1 = IN.texcoord_0;
    return OUT;
};
