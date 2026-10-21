static const float BIAS = 0.018;


float GetPointLightAmountValue(samplerCUBE ShadowCubeMapBuffer, float3 LightDir, float Distance) {
	if (TESR_ShadowFade.z == 0) return 1;

	float lightDepth = texCUBE(ShadowCubeMapBuffer, LightDir).r;
	float Shadow = lightDepth + BIAS * Distance > Distance; // increase BIAS with distance

	// ignore shadow sample if lightDepth is not within range of cube map or if pointLights are disabled (ShadowFade.z set to 0)
	return lerp(1, Shadow, lightDepth > 0.0f && lightDepth < 1.0f);
}


float GetPointLightAtten(float3 LightDir, float Distance, float4 normal) {

	// radius based attenuation based on https://lisyarus.github.io/blog/graphics/2022/07/30/point-light-attenuation.html
	float s = saturate(Distance * Distance); 
	float atten = saturate(((1 - s) * (1 - s)) / (1 + 5.0 * s));

	LightDir = normalize(LightDir); // normalize
	float diffuse = lerp(1, dot(LightDir, normal.xyz), smoothstep(0, 0.2, Distance)); // add some light bleeding at very short distance

	return saturate(diffuse * atten);
}


// returns a point light contribution using a shadow map
float GetPointLightAmount(samplerCUBE ShadowCubeMapBuffer, float4 WorldPos, float4 LightPos, float4 normal) {
	if (!LightPos.w) return 0; // w is light radius.

	float3 LightDir = LightPos.xyz - WorldPos.xyz;
	float3 LightUV = LightDir * float3(-1, -1, 1);

	float Distance = length(LightDir) / LightPos.w; // normalize distance over light range

	float LightAmount = GetPointLightAmountValue(ShadowCubeMapBuffer, LightUV, Distance) * GetPointLightAtten(LightDir, Distance, normal);
	return saturate(LightAmount);
}


// get the normalized distance between the light and a point as a ratio of the light radius
float4 GetPointLightDistance(float4 WorldPos, float4 LightPos){
	float3 LightDir = LightPos.xyz - WorldPos.xyz;
	float Distance = length(LightDir) / LightPos.w; // normalize distance over light range
	return float4(LightDir, Distance);
}


// returns a point light contribution with no shadow map sampling
float GetPointLightContribution(float4 worldPos, float4 LightPos, float4 normal) {
    float4 light = GetPointLightDistance(worldPos, LightPos);
    return GetPointLightAtten(light.xyz, light.w, normal);
}


// Sun shadows (PCF): plain depths compared at the four nearest texels, bilinearly weighted.
float ShadowPCF2x2(sampler2D atlas, float2 uv, float depth, float texel) {
    float2 p = uv / texel - 0.5f;
    float2 base = floor(p);
    float2 f = p - base;
    float2 uv0 = (base + 0.5f) * texel;
    float4 d = float4(tex2Dlod(atlas, float4(uv0, 0.0f, 0.0f)).x, tex2Dlod(atlas, float4(uv0 + float2(texel, 0.0f), 0.0f, 0.0f)).x,
                      tex2Dlod(atlas, float4(uv0 + float2(0.0f, texel), 0.0f, 0.0f)).x, tex2Dlod(atlas, float4(uv0 + texel, 0.0f, 0.0f)).x);
    float4 lit = depth <= d ? 1.0f : 0.0f;
    return lerp(lerp(lit.x, lit.y, f.x), lerp(lit.z, lit.w, f.x), f.y);
}
