float DitherGradientNoise(float2 p)
{
    return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715))));
}

float TonemapDitherAt(float2 pixel)
{
    const float2 p = pixel + TESR_ToneMappingClip.z * float2(5.588238, 3.235);
    return (DitherGradientNoise(p) + DitherGradientNoise(p + float2(47.0, 17.0)) - 1.0) * TESR_ToneMappingClip.y;
}

float LumaWithoutDither(float luma, float2 pixel)
{
    return luma - TonemapDitherAt(pixel) * saturate(luma * 128.0);
}
