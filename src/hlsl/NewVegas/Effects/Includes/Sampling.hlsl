// Sampling functions.

#if defined(__INTELLISENSE__)
    #include "Helpers.hlsl"
#else
    #include "includes/Helpers.hlsl"
#endif

// Downsample with blur by averaging 13 samples around the texel by weighting their values.
//
// Take 13 samples around current texel (basically forming 5 separate boxes):
// a - b - c
// - j - k -
// d - e - f
// - l - m -
// g - h - i
// === ('e' is the current texel) ===
//
// Apply weighted distribution:
// 0.5 + 0.125 + 0.125 + 0.125 + 0.125 = 1
// a,b,d,e * 0.125
// b,c,e,f * 0.125
// d,e,g,h * 0.125
// e,f,h,i * 0.125
// j,k,l,m * 0.5
float4 DownsampleBox13(uniform sampler2D buffer, float2 uv, float2 texelSize) {
    const float x = texelSize.x;
    const float y = texelSize.y;

    float4 a = tex2D(buffer, float2(uv.x - 2 * x, uv.y + 2 * y));
    float4 b = tex2D(buffer, float2(uv.x, uv.y + 2 * y));
    float4 c = tex2D(buffer, float2(uv.x + 2 * x, uv.y + 2 * y));

    float4 d = tex2D(buffer, float2(uv.x - 2 * x, uv.y));
    float4 e = tex2D(buffer, float2(uv.x, uv.y));
    float4 f = tex2D(buffer, float2(uv.x + 2 * x, uv.y));

    float4 g = tex2D(buffer, float2(uv.x - 2 * x, uv.y - 2 * y));
    float4 h = tex2D(buffer, float2(uv.x, uv.y - 2 * y));
    float4 i = tex2D(buffer, float2(uv.x + 2 * x, uv.y - 2 * y));

    float4 j = tex2D(buffer, float2(uv.x - x, uv.y + y));
    float4 k = tex2D(buffer, float2(uv.x + x, uv.y + y));
    float4 l = tex2D(buffer, float2(uv.x - x, uv.y - y));
    float4 m = tex2D(buffer, float2(uv.x + x, uv.y - y));
    
    float2 weights = float2(0.125, 0.5);
    
    float4 boxes[5];
    
    boxes[0] = (a + b + d + e) * 0.25;
    boxes[1] = (b + c + e + f) * 0.25;
    boxes[2] = (d + e + g + h) * 0.25;
    boxes[3] = (e + f + h + i) * 0.25;
    boxes[4] = (j + k + l + m) * 0.25;
	
    return boxes[0] * weights[0] + boxes[1] * weights[0] + boxes[2] * weights[0] + boxes[3] * weights[0] + boxes[4] * weights[1];
}

// Soft-knee bloom threshold ([Shaders.Bloom.*] Threshold): keeps the part of a linear colour
// above the threshold, ramping in quadratically over a knee of half the threshold so the cut has
// no hard edge. A threshold of 0 returns the colour unchanged. Must match BloomThreshold in
// the ISHDRBLENDINSHADERCIN(AM) composites.
float3 BloomThreshold(float3 color, float threshold) {
    float knee = threshold * 0.5f;
    float brightness = max(color.r, max(color.g, color.b));
    float soft = clamp(brightness - threshold + knee, 0.0f, 2.0f * knee);
    soft = soft * soft / (4.0f * knee + 1e-5f);
    return color * (max(soft, brightness - threshold) / max(brightness, 1e-5f));
}

// The first downsample of a bloom chain: the same 13 taps, but read from the gamma-encoded scene,
// converted to linear light, and each 2x2 box weighted by 1 / (1 + luma) (Karis average).
//
// Bloom has to be blurred in linear light: averaging gamma-encoded values and linearizing
// afterwards underweights bright sources, so lights bloom too little and halos go muddy.
// The Karis weights keep a single very bright pixel (a specular glint, a muzzle flash texel,
// a sub-pixel light the TAA jitter moves around) from spreading into a large flickering blob,
// the fireflies thresholdless HDR bloom is prone to. Only the first level needs them: after it
// every texel is already an average.
float3 KarisBox(float4 p, float4 q, float4 r, float4 s, out float weight) {
    float3 box = (p.rgb + q.rgb + r.rgb + s.rgb) * 0.25f;
    weight = 1.0f / (1.0f + luma(box));
    return box * weight;
}

float4 DownsampleBox13KarisLinear(uniform sampler2D buffer, float2 uv, float2 texelSize) {
    const float x = texelSize.x;
    const float y = texelSize.y;

    // Negative values from earlier passes are clamped BEFORE linearizing (pow of a negative is
    // NaN, which would then spread through the whole chain); 64000 keeps the result inside FP16.
    #define BLOOM_TAP(o) min(linearize(max(tex2D(buffer, uv + (o)), 0.0f)), 64000.0f)
    float4 a = BLOOM_TAP(float2(-2 * x,  2 * y));
    float4 b = BLOOM_TAP(float2(     0,  2 * y));
    float4 c = BLOOM_TAP(float2( 2 * x,  2 * y));
    float4 d = BLOOM_TAP(float2(-2 * x,      0));
    float4 e = BLOOM_TAP(float2(     0,      0));
    float4 f = BLOOM_TAP(float2( 2 * x,      0));
    float4 g = BLOOM_TAP(float2(-2 * x, -2 * y));
    float4 h = BLOOM_TAP(float2(     0, -2 * y));
    float4 i = BLOOM_TAP(float2( 2 * x, -2 * y));
    float4 j = BLOOM_TAP(float2(    -x,      y));
    float4 k = BLOOM_TAP(float2(     x,      y));
    float4 l = BLOOM_TAP(float2(    -x,     -y));
    float4 m = BLOOM_TAP(float2(     x,     -y));
    #undef BLOOM_TAP

    float w0, w1, w2, w3, w4;
    float3 sum = (KarisBox(a, b, d, e, w0) + KarisBox(b, c, e, f, w1) + KarisBox(d, e, g, h, w2) + KarisBox(e, f, h, i, w3)) * 0.125f
               + KarisBox(j, k, l, m, w4) * 0.5f;
    float total = (w0 + w1 + w2 + w3) * 0.125f + w4 * 0.5f;
    return float4(sum / total, 1.0f);
}

// Upsample with tent filter.
//
// Take 9 samples around current texel:
// a - b - c
// d - e - f
// g - h - i
// === ('e' is the current texel) ===
//
// Apply weighted distribution, by using a 3x3 tent filter:
//  1   | 1 2 1 |
// -- * | 2 4 2 |
// 16   | 1 2 1 |
float4 UpsampleTent9(uniform sampler2D buffer, float2 uv, float2 filterRadius) {
	// The filter kernel is applied with a radius, specified in texture
    // coordinates, so that the radius will vary across mip resolutions.
    float x = filterRadius.x;
    float y = filterRadius.y;

    float4 a = tex2D(buffer, float2(uv.x - x, uv.y + y));
    float4 b = tex2D(buffer, float2(uv.x, uv.y + y));
    float4 c = tex2D(buffer, float2(uv.x + x, uv.y + y));

    float4 d = tex2D(buffer, float2(uv.x - x, uv.y));
    float4 e = tex2D(buffer, float2(uv.x, uv.y));
    float4 f = tex2D(buffer, float2(uv.x + x, uv.y));

    float4 g = tex2D(buffer, float2(uv.x - x, uv.y - y));
    float4 h = tex2D(buffer, float2(uv.x, uv.y - y));
    float4 i = tex2D(buffer, float2(uv.x + x, uv.y - y));

    float4 upsample = e * 4.0;
    upsample += (b + d + f + h) * 2.0;
    upsample += (a + c + g + i);
    upsample *= 1.0 / 16.0;
    
    return upsample;
}
