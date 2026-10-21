#ifdef PARTICLE_VS

float4 TESR_ParticleData : register(c200);
float4 TESR_ParticleAmbient : register(c201);
float4 TESR_CameraPosition : register(c202);
float4 TESR_LightPosition[12] : register(c203);
float4 TESR_ShadowLightPosition[12] : register(c215);
float4 TESR_LightColor[24] : register(c227);

float3 ParticlePointLight(float4 light, float4 color, float3 worldPos) {
    [branch] if (light.w <= 0.0f) return 0.0f;
    float s = saturate(dot(light.xyz - worldPos, light.xyz - worldPos) / (light.w * light.w));
    return color.rgb * color.w * ((1.0f - s) * (1.0f - s) / (1.0f + 5.0f * s));
}

float3 ParticleVertexLight(float3 cameraRelativePos) {
    [branch] if (TESR_ParticleData.x <= 0.0f) return 0.0f;
    float3 light = TESR_ParticleAmbient.rgb;
    float3 worldPos = cameraRelativePos + TESR_CameraPosition.xyz;
    [loop] for (int i = 0; i < 12; i++) {
        light += ParticlePointLight(TESR_ShadowLightPosition[i], TESR_LightColor[i], worldPos);
        light += ParticlePointLight(TESR_LightPosition[i], TESR_LightColor[i + 12], worldPos);
    }
    return light;
}

#else

float4 TESR_ParticleData : register(c168);
float4 TESR_SunColor : register(c170);

float3 ParticleLight(float3 vertexLight, float3 cameraRelativePos) {
    [branch] if (TESR_ParticleData.x <= 0.0f) return 1.0f;
    float3 light = vertexLight;
    [branch] if (TESR_ParticleData.w > 0.0f) {
        light += TESR_SunColor.rgb * GetSunShadow(cameraRelativePos, normalize(-cameraRelativePos)) * TESR_ParticleData.z;
    }
    return lerp(1.0f, light * TESR_ParticleData.y, TESR_ParticleData.x);
}

#endif
