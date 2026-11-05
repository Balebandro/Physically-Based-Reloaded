// UNOFFICIAL lit particles and blood decals (Shaders.Particles, off by default), shared by NOLIGHT016/017.vso,
// GDECAL.vso, GDECALS.vso (with PARTICLE_VS defined) and NOLIGHTTEXVC.pso, GDECAL.pso.
//
// Particles and decals have no usable normal (thin, camera-facing; a decal's NORMAL carries its texture coordinates),
// so light is taken as reaching them from all sides. The vertex shader adds up what changes slowly across a particle --
// the ambient and the nearby point lights -- once per vertex; the pixel shader adds only the sun through the sun
// shadow, which must follow the shadow edges. Per pixel, the 24-light loop cost several ms in smoke and blood clouds,
// whose large particles stack many layers deep.
//
// Constants bound by name; the registers only decide where they live, pinned clear of the game's (vertex: c0-c97 at
// most, skinned decals' Bones; pixel: Shadow.hlsl's c100-c167).

#ifdef PARTICLE_VS

float4 TESR_ParticleData : register(c200);            // x: strength, y: brightness, z: sun share, w: 1 outdoors
float4 TESR_ParticleAmbient : register(c201);         // rgb: ambient (the sky's outdoors, the cell's indoors)
float4 TESR_CameraPosition : register(c202);
float4 TESR_LightPosition[12] : register(c203);       // other point lights: xyz world position, w radius (0 = unused)
float4 TESR_ShadowLightPosition[12] : register(c215); // shadow-casting point lights, same layout
float4 TESR_LightColor[24] : register(c227);          // 0-11: shadow-casting lights, 12-23: the others; rgb, w dimmer

// Radius-based falloff, as WetWorld's point-light specular uses (lisyarus' smooth window).
float3 ParticlePointLight(float4 light, float4 color, float3 worldPos) {
    [branch] if (light.w <= 0.0f) return 0.0f;
    float s = saturate(dot(light.xyz - worldPos, light.xyz - worldPos) / (light.w * light.w));
    return color.rgb * color.w * ((1.0f - s) * (1.0f - s) / (1.0f + 5.0f * s));
}

// Ambient plus the point lights at a camera-relative position. Skipped (zero) while the strength is 0.
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

float4 TESR_ParticleData : register(c168); // as above
float4 TESR_SunColor : register(c170);     // rgb: the weather's sun (directional) colour

// The multiplier for the colour: the vertex light plus the sun through its shadow, times the brightness, blended in by
// the strength (0 = 1, the game's unlit look).
float3 ParticleLight(float3 vertexLight, float3 cameraRelativePos) {
    [branch] if (TESR_ParticleData.x <= 0.0f) return 1.0f;
    float3 light = vertexLight;
    [branch] if (TESR_ParticleData.w > 0.0f) {
        // Facing the camera; only the shadow bias uses it.
        light += TESR_SunColor.rgb * GetSunShadow(cameraRelativePos, normalize(-cameraRelativePos)) * TESR_ParticleData.z;
    }
    return lerp(1.0f, light * TESR_ParticleData.y, TESR_ParticleData.x);
}

#endif
