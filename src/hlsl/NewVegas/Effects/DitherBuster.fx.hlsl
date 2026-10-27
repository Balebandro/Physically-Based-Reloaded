//-----------------------------------------//
//        __    ____  __    __
//       / /\  | |_  / /\  / /\
//      /_/--\ |_|  /_/--\/_/--\
//-----------------------------------------//
// Advanced Fast Approximate Anti Aliasing
//-----------------------------------------//
// An advanced approach to post process FXAA with more customization and flexibility.
// Based on BIAA by Jose Negrete AKA BlueSkyDefender.
//-----------------------------------------//
// Constants:
//-----------------------------------------//

float4 TESR_ReciprocalResolution;
float4 TESR_DitherBusterData;   // x: Strength (0-1), y: MaskPower, z: DitherThreshold, w: Radius
float4 TESR_DitherBusterGate;
float4 TESR_ToneMappingClip;

//-----------------------------------------//
// Samplers:
//-----------------------------------------//

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };

//-----------------------------------------//
// Vertex Shader:
//-----------------------------------------//

struct VSOUT
{
    float4 vertPos : POSITION;
    float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
    float4 vertPos : POSITION0;
    float2 UVCoord : TEXCOORD0;
};

VSOUT FrameVS(VSIN IN)
{
    VSOUT OUT = (VSOUT) 0.0f;
    OUT.vertPos = IN.vertPos;
    OUT.UVCoord = IN.UVCoord;
    return OUT;
}

//-----------------------------------------//
// Includes:
//-----------------------------------------//

#include "Includes/Helpers.hlsl"
#include "Includes/DitherNoise.hlsl"

//-----------------------------------------//
// Options:
//-----------------------------------------//
// - AFAA Pass Count
// How many times the actual Anti Aliasing effect is ran.
// Requires lower parameters. Still great at one pass.

#define AFAA_PASS_COUNT 1

// - AFAA Debug Modes
// Shows debug modes for developers.
// 1 - Edge mask
// 2 - Depth edges
// 3 - Luma edges
// 4 - Color gradient (Used for SubPix)
// 5 - SubPix gradient (Used for SubPix)

#define AFAA_DEBUG_MODE 0

// - AFAA Depth Detection
// Uses the depth buffer for extra edge detection thats added with the
// luma edge detection, better for interiors and closer objects but works really
// well. Exterior AA power needs to be lowered if used.

#define AFAA_DEPTH_DETECTION 0
#define AFAA_DEPTH_MULTIPLIER half(60.0f)

// - Experimental AFAA Sub Pixel Readjustment
// May help recover details along edges of objects HOWEVER it may also introduce more
// aliasing so theres a trade off point. No performance impact but could add artifacting.
// Goes before actual AFAA technique so it is anti aliased.

#define AFAA_SUBPIXEL_READJUSTMENT 1
#define AFAA_SUBPIXEL_OFFSET half(0.25f)
#define AFAA_SUBPIXEL_POWER half(0.1)

//-----------------------------------------//

#define GetBufferOffset(c, o)    tex2D(c, IN.UVCoord + o * TESR_ReciprocalResolution.xy).rgba

half4 SubPixTest(VSOUT IN) : COLOR
{
    half3 color = tex2D(TESR_RenderedBuffer, IN.UVCoord);
    half2 subpixelOffset = TESR_ReciprocalResolution.xy * AFAA_SUBPIXEL_OFFSET;
    half3 subpixelColor = tex2D(TESR_RenderedBuffer, IN.UVCoord + subpixelOffset);

    half3 dx = ddx(color.xyz);
    half3 dy = ddy(color.xyz);
    half gradient = sqrt(dot(dx, dx) + dot(dy, dy));

    half3 dxSubpixel = ddx(subpixelColor.xyz);
    half3 dySubpixel = ddy(subpixelColor.xyz);
    half gradientSubpixel = sqrt(dot(dxSubpixel, dxSubpixel) + dot(dySubpixel, dySubpixel)) / AFAA_SUBPIXEL_POWER;

    color = (gradientSubpixel > gradient) ? subpixelColor : color;

#if AFAA_DEBUG_MODE == 4
    return half4(gradient, gradient, gradient, 1.0f);
#elif AFAA_DEBUG_MODE == 5
    return half4(gradientSubpixel, gradientSubpixel, gradientSubpixel, 1.0f);
#endif

    return half4(color, 1.0f);
}

half4 AFAA(VSOUT IN) : COLOR0
{
    half3 center = tex2D(TESR_RenderedBuffer, IN.UVCoord).rgb;
    half3 colorW = GetBufferOffset(TESR_RenderedBuffer, half2(-1.0f, 0.0f)).rgb;
    half3 colorE = GetBufferOffset(TESR_RenderedBuffer, half2(1.0f, 0.0f)).rgb;
    half3 colorN = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, 1.0f)).rgb;
    half3 colorS = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, -1.0f)).rgb;
    half3 color = center * (1.0f - TESR_DitherBusterData.x);

    // --- Luma FXAA Edge Detection ---
    // Super simple easy luma edge detection, better for exteriors
    // and general use. More closely related to BIAA edge detection.
    // These were assigning a float4 straight into a half, so HLSL took .x and every "luma" was in
    // fact the red channel alone - green carries about 71% of perceived luminance, so edges that
    // live mostly in green or blue were being under-weighted or missed. Rec.709 weights instead.
    static const half3 LumaWeights = half3(0.2126f, 0.7152f, 0.0722f);
    half lumaW = dot(colorW, LumaWeights);
    half lumaE = dot(colorE, LumaWeights);
    half lumaN = dot(colorN, LumaWeights);
    half lumaS = dot(colorS, LumaWeights);
    half2 lumaEdge = half2(lumaS - lumaN, lumaE - lumaW) * 0.5f;

    // --- Isolated pixel (dither) detection ---
    // The central differences above are exactly zero on a one pixel checkerboard: N and S are the
    // same phase as each other, so lumaS - lumaN cancels, and likewise for E and W. That is the
    // Nyquist frequency, invisible to any symmetric difference - which means the edge mask below
    // never fires on alpha test dither, the artifact this effect is named for. DXVK's dithered
    // grass is precisely that pattern.
    //
    // Comparing each neighbour against the CENTRE instead is largest exactly where the central
    // differences vanish. Subtracting the central gradient separates the two cases without a
    // second contrast threshold: on a step edge the centre agrees with one side, so spike and
    // gradient cancel to zero, while an isolated pixel disagrees with every neighbour at once and
    // survives. Worked through: a step of d gives spike = d and length(lumaEdge) = d/2, so
    // isolation = 0; a checkerboard of d gives spike = 4d and length(lumaEdge) = 0.
    half lumaC = dot(center, LumaWeights);
    half spike = abs(lumaC - lumaN) + abs(lumaC - lumaS) + abs(lumaC - lumaE) + abs(lumaC - lumaW);
    half isolation = max(0.0f, spike - 4.0f * length(lumaEdge));

#if AFAA_DEPTH_DETECTION == 1
    // --- Depth Edge Detection ---
    // Better for interiors and closer objects.
    // Similar to NFAA edge detection.
    half depth = tex2D(TESR_DepthBuffer, IN.UVCoord);
    half lumaValues0 = GetBufferOffset(TESR_DepthBuffer, half2(-1.0f, -1.0f));
    half lumaValues1 = GetBufferOffset(TESR_DepthBuffer, half2(0.0f, -1.0f));
    half lumaValues2 = GetBufferOffset(TESR_DepthBuffer, half2(0.0f, -1.0f));
    half lumaValues3 = GetBufferOffset(TESR_DepthBuffer, half2(1.0f, -1.0f));
    half lumaValues4 = GetBufferOffset(TESR_DepthBuffer, half2(-1.0f, 0.0f));
    half lumaValues5 = GetBufferOffset(TESR_DepthBuffer, half2(0.0f, 0.0f));
    half lumaValues6 = GetBufferOffset(TESR_DepthBuffer, half2(1.0f, 0.0f));
    half lumaValues7 = GetBufferOffset(TESR_DepthBuffer, half2(-1.0f, 1.0f));

    half max_luma01 = max(lumaValues0, lumaValues1);
    half max_luma23 = max(lumaValues2, lumaValues3);
    half max_luma45 = max(lumaValues4, lumaValues5);
    half max_luma67 = max(lumaValues6, lumaValues7);

    half max_luma0123 = max(max_luma01, max_luma23);
    half max_luma4567 = max(max_luma45, max_luma67);

    half max_luma = max(max_luma0123, max_luma4567);

    half min_luma0123 = min(lumaValues0, min(lumaValues1, min(lumaValues2, lumaValues3)));
    half min_luma4567 = min(lumaValues4, min(lumaValues5, min(lumaValues6, lumaValues7)));

    half min_luma = min(min_luma0123, min_luma4567);

    half depthEdges = clamp(max(depth - min_luma, max_luma - min(depth, min_luma)), 0.0, 1.0);
    depthEdges *= AFAA_DEPTH_MULTIPLIER;
    lumaEdge += depthEdges;
#endif

    // Ported from BIAA
    half2 edge = half2(lumaEdge.x, -lumaEdge.y);
    half Mask = length(edge) < pow(0.002f, TESR_DitherBusterData.y);

    // Dither gets an isotropic average rather than the directional pass below. A checkerboard has
    // no orientation, so smearing along an edge direction is meaningless where the direction is
    // itself degenerate - averaging the neighbourhood is what cancels it. Gated on isolation so it
    // stays off ordinary edges and off flat texture.
    if (isolation > TESR_DitherBusterData.z && TESR_DitherBusterData.z > 0.0f)
    {
        half3 neighbourhood = center + colorN + colorS + colorE + colorW;
        neighbourhood *= 0.2f;

        return half4(lerp(center, neighbourhood, saturate(TESR_DitherBusterData.x)), 1.0f);
    }

    if (Mask)
    {
        color = center;
    }
    else
    {
        // edge is a luma DIFFERENCE, and below it is used directly as a distance in texels. On an
        // ordinary edge of delta 0.1 that puts the widest tap 0.1 of a texel from the centre, so
        // all six samples return essentially the same pixel and the pass does nothing visible;
        // even at maximum contrast it reaches only half a texel. NFAA and BIAA normalise the
        // direction and scale it by a radius, which is what actually lets the taps straddle the
        // edge. Radius restores that. Radius = 0 keeps the raw magnitude, i.e. the old behaviour.
        half2 dir = edge;
        if (TESR_DitherBusterData.w > 0.0f)
        {
            half len = length(edge);
            dir = (len > 0.0001f) ? (edge / len) * TESR_DitherBusterData.w : half2(0.0f, 0.0f);
        }

        for (int i = 0; i < AFAA_PASS_COUNT; ++i) // Honestly the loop is useless
        {
	        // Like NFAA reproject with samples along the edge and adjust againts it self.
            const float NormalizedStength = TESR_DitherBusterData.x / 6.0f;
            color += GetBufferOffset(TESR_RenderedBuffer, (dir * 0.5f)) * NormalizedStength;
            color += GetBufferOffset(TESR_RenderedBuffer, -(dir * 0.5f)) * NormalizedStength;
            color += GetBufferOffset(TESR_RenderedBuffer, (dir * 0.25f)) * NormalizedStength;
            color += GetBufferOffset(TESR_RenderedBuffer, -(dir * 0.25f)) * NormalizedStength;
            color += GetBufferOffset(TESR_RenderedBuffer, dir) * NormalizedStength;
            color += GetBufferOffset(TESR_RenderedBuffer, -dir) * NormalizedStength;
        }
        color /= AFAA_PASS_COUNT;
    }

#if AFAA_DEBUG_MODE == 1
        return lerp(half3(1.0f, 0.0f, 0.0f), color, Mask);
#elif AFAA_DEBUG_MODE == 2
        return half4(depthEdges.x, depthEdges.x, depthEdges.x, 1.0f);
#elif AFAA_DEBUG_MODE == 3
        return half4(lumaEdge.x, lumaEdge.x, lumaEdge.x, 1.0f);
#endif

    return half4(color, 1.0f);
}

half4 DitherOnly(VSOUT IN) : COLOR0
{
    half3 center = tex2D(TESR_RenderedBuffer, IN.UVCoord).rgb;
    half3 colorW = GetBufferOffset(TESR_RenderedBuffer, half2(-1.0f, 0.0f)).rgb;
    half3 colorE = GetBufferOffset(TESR_RenderedBuffer, half2(1.0f, 0.0f)).rgb;
    half3 colorN = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, 1.0f)).rgb;
    half3 colorS = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, -1.0f)).rgb;
    static const half3 LumaWeights = half3(0.2126f, 0.7152f, 0.0722f);
    half lumaC = dot(center, LumaWeights);
    half lumaW = dot(colorW, LumaWeights);
    half lumaE = dot(colorE, LumaWeights);
    half lumaN = dot(colorN, LumaWeights);
    half lumaS = dot(colorS, LumaWeights);
    half2 gradient = half2(lumaS - lumaN, lumaE - lumaW) * 0.5f;
    half spike = abs(lumaC - lumaN) + abs(lumaC - lumaS) +
                 abs(lumaC - lumaE) + abs(lumaC - lumaW);
    half isolation = max(0.0f, spike - 4.0f * length(gradient));

    if (TESR_DitherBusterData.z > 0.0f && isolation > TESR_DitherBusterData.z) {
        half3 neighbourhood = (center + colorN + colorS + colorE + colorW) * 0.2f;
        center = lerp(center, neighbourhood, saturate(TESR_DitherBusterData.x));
    }
    return half4(center, 1.0f);
}



half4 DitherOnlyStable(VSOUT IN, float2 vpos : VPOS) : COLOR0
{
    half3 center = tex2D(TESR_RenderedBuffer, IN.UVCoord).rgb;
    half3 colorW = GetBufferOffset(TESR_RenderedBuffer, half2(-1.0f, 0.0f)).rgb;
    half3 colorE = GetBufferOffset(TESR_RenderedBuffer, half2(1.0f, 0.0f)).rgb;
    half3 colorN = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, 1.0f)).rgb;
    half3 colorS = GetBufferOffset(TESR_RenderedBuffer, half2(0.0f, -1.0f)).rgb;
    static const half3 LumaWeights = half3(0.2126f, 0.7152f, 0.0722f);
    half lumaC = dot(center, LumaWeights);
    half lumaW = dot(colorW, LumaWeights);
    half lumaE = dot(colorE, LumaWeights);
    half lumaN = dot(colorN, LumaWeights);
    half lumaS = dot(colorS, LumaWeights);
    [branch] if (TESR_DitherBusterGate.y > 0.5f) {
        lumaC = LumaWithoutDither(lumaC, vpos);
        lumaW = LumaWithoutDither(lumaW, vpos + float2(-1.0f, 0.0f));
        lumaE = LumaWithoutDither(lumaE, vpos + float2(1.0f, 0.0f));
        lumaN = LumaWithoutDither(lumaN, vpos + float2(0.0f, 1.0f));
        lumaS = LumaWithoutDither(lumaS, vpos + float2(0.0f, -1.0f));
    }
    half2 gradient = half2(lumaS - lumaN, lumaE - lumaW) * 0.5f;
    half spike = abs(lumaC - lumaN) + abs(lumaC - lumaS) +
                 abs(lumaC - lumaE) + abs(lumaC - lumaW);
    half isolation = max(0.0f, spike - 4.0f * length(gradient));

    [branch] if (TESR_DitherBusterGate.z > 0.5f)
        return half4(saturate(center - TonemapDitherAt(vpos) * saturate(center * 128.0f)), 1.0f);

    half gate = isolation > TESR_DitherBusterData.z ? 1.0f : 0.0f;
    [branch] if (TESR_DitherBusterGate.x > 0.0f)
        gate = smoothstep(TESR_DitherBusterData.z * (1.0f - TESR_DitherBusterGate.x), TESR_DitherBusterData.z * (1.0f + TESR_DitherBusterGate.x), isolation);

    if (TESR_DitherBusterData.z > 0.0f && gate > 0.0f) {
        half3 neighbourhood = (center + colorN + colorS + colorE + colorW) * 0.2f;
        center = lerp(center, neighbourhood, saturate(TESR_DitherBusterData.x) * gate);
    }
    return half4(center, 1.0f);
}



technique POST_PROCESS_ANTI_ALIASING
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 DitherOnly();
    }
}

technique POST_PROCESS_ANTI_ALIASING_STABLE
{
    pass
    {
        VertexShader = compile vs_3_0 FrameVS();
        PixelShader = compile ps_3_0 DitherOnlyStable();
    }
}
