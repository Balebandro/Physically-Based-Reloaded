float4 TESR_BounceLightData;
float4 TESR_ReciprocalResolution;
float4 NVR_BounceLayout;
float4 NVR_BounceTemporal;
float4 NVR_BounceAmbient;
float4x4 NVR_BounceReproject;
float4 NVR_BounceSpill = float4(0.0f, 1.0f, 1.0f, 6.0f);
float4 NVR_SpillDebug;
float4 NVR_SpillShape = float4(1.0f, 1.0f, 0.0f, 0.0f);
float4 NVR_SpillTarget;
float4 NVR_SpillMemory;
float4 NVR_SpillOptions;

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D TESR_DepthBuffer : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D TESR_SourceBuffer : register(s2) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D TESR_NormalsBuffer : register(s3) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D TESR_BlueNoiseSampler : register(s4) < string ResourceName = "Effects\bluenoise256.dds"; > = sampler_state { ADDRESSU = WRAP; ADDRESSV = WRAP; MAGFILTER = NONE; MINFILTER = NONE; MIPFILTER = NONE; };
sampler2D NVR_BounceBuffer : register(s5) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D NVR_BouncePrep : register(s6) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D NVR_BounceHistory : register(s7) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };
sampler2D NVR_Spill0 : register(s8) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill1 : register(s9) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill2 : register(s10) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill3 : register(s11) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill4 : register(s12) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill5 : register(s13) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_Spill6 : register(s14) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
sampler2D NVR_SpillSteadyBuffer : register(s15) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = NONE; };
float4 NVR_SpillSteady;

static const float Strength = TESR_BounceLightData.x;
static const float Radius = max(TESR_BounceLightData.y, 1.0f);
static const float DrawDistance = TESR_BounceLightData.z;
static const float BlurRadius = TESR_BounceLightData.w;
static const int SAMPLES = 8;
static const float NearFade = 40.0f;
static const float MaxScreenRadius = 0.06f;

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
	VSOUT OUT = (VSOUT)0.0f;
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
	return OUT;
}

VSOUT HalfVS(VSIN IN)
{
	VSOUT OUT = FrameVS(IN);
	OUT.UVCoord += 0.5f * (NVR_BounceLayout.zw - TESR_ReciprocalResolution.xy);
	return OUT;
}

#include "Includes/Helpers.hlsl"
#include "Includes/Depth.hlsl"
#include "Includes/Blur.hlsl"
// projectedDepthFromLinear and readDepthLod: Includes/Depth.hlsl (from NVR UNOFFICIAL Optimized, as this effect).

float3 NormalLod(float2 uv)
{
	return normalize(tex2Dlod(TESR_NormalsBuffer, float4(uv, 0.0f, 0.0f)).xyz * 2 - 1);
}

float3 PositionFromLinear(float2 uv, float linear01)
{
	float z = projectedDepthFromLinear(linear01);
	float4 viewSpace = mul(float4(uv.x * 2 - 1, (1 - uv.y) * 2 - 1, z, 1.0f), TESR_InvProjectionTransform);
	return viewSpace.xyz / viewSpace.w;
}

float Pack2(float2 v)
{
	v = floor(saturate(v) * 4095.0f + 0.5f);
	return v.x * 4096.0f + v.y;
}

float2 Unpack2(float p)
{
	float high = floor(p / 4096.0f);
	return float2(high, p - high * 4096.0f) / 4095.0f;
}

float2 OctEncode(float3 n)
{
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 s = n.xy >= 0.0f ? 1.0f : -1.0f;
	float2 e = n.z >= 0.0f ? n.xy : (1.0f - abs(n.yx)) * s;
	return e * 0.5f + 0.5f;
}

float3 OctDecode(float2 e)
{
	e = e * 2.0f - 1.0f;
	float3 n = float3(e, 1.0f - abs(e.x) - abs(e.y));
	float t = saturate(-n.z);
	n.xy += n.xy >= 0.0f ? -t : t;
	return normalize(n);
}

float4 Prepare(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;
	float linear01 = tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).x;
	float3 normal = NormalLod(uv);
	float3 light = min(linearize(tex2Dlod(TESR_SourceBuffer, float4(uv, 0.0f, 0.0f)).rgb), 1.0f);
	return float4(linear01, Pack2(OctEncode(normal)), Pack2(sqrt(light.rg)), light.b);
}

float4 Gather(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;
	float4 center = tex2Dlod(NVR_BouncePrep, float4(uv, 0.0f, 0.0f));
	float3 origin = PositionFromLinear(uv, center.x);
	float fade = smoothstep(NearFade, NearFade * 2.0f, origin.z) * (1.0f - smoothstep(DrawDistance * 0.7f, DrawDistance, origin.z));
	[branch] if (fade <= 0.0f) return float4(0.0f, 0.0f, 0.0f, origin.z);

	float3 normal = OctDecode(Unpack2(center.y));
	float3 noise = tex2Dlod(TESR_BlueNoiseSampler, float4(uv / (256.0f * NVR_BounceLayout.zw), 0.0f, 0.0f)).xyz;
	float3 up = abs(normal.z) < 0.99f ? float3(0.0f, 0.0f, 1.0f) : float3(1.0f, 0.0f, 0.0f);
	float3 tangent = normalize(cross(up, normal));
	float3 bitangent = cross(normal, tangent);
	float radius = min(Radius, MaxScreenRadius * 2.0f * origin.z / TESR_ProjectionTransform[0][0]);

	float3 indirect = 0.0f;
	[unroll]
	for (int i = 0; i < SAMPLES; i++) {
		float angle = (i + noise.x) * (6.2831853f / SAMPLES);
		float r = radius * (0.15f + 0.85f * frac(noise.y + i * 0.618034f));
		float3 p = origin + (tangent * cos(angle) + bitangent * sin(angle)) * r + normal * (r * 0.25f);
		float2 sampleUV = projectPosition(p).xy;
		float onScreen = step(0.0f, sampleUV.x) * step(sampleUV.x, 1.0f) * step(0.0f, sampleUV.y) * step(sampleUV.y, 1.0f);
		sampleUV = (floor(saturate(sampleUV) / NVR_BounceLayout.zw) + 0.5f) * NVR_BounceLayout.zw;

		float4 texel = tex2Dlod(NVR_BouncePrep, float4(sampleUV, 0.0f, 0.0f));
		float3 s = PositionFromLinear(sampleUV, texel.x);
		float3 toSample = s - origin;
		float dist = length(toSample) + 0.001f;
		float3 dir = toSample / dist;
		float nearAim = saturate(1.0f - length(s - p) / radius);
		float weight = saturate(dot(normal, dir)) * saturate(dot(OctDecode(Unpack2(texel.y)), -dir)) * nearAim * onScreen * step(NearFade, s.z);
		float2 rg = Unpack2(texel.z);
		indirect += float3(rg * rg, texel.w) * weight;
	}
	return float4(indirect * (2.0f / SAMPLES) * fade, origin.z);
}

float4 Blur(VSOUT IN, uniform float2 axis, uniform bool hard) : COLOR0
{
	float4 center = tex2Dlod(NVR_BounceBuffer, float4(IN.UVCoord, 0.0f, 0.0f));
	float tolerance = max(center.a * 0.03f, 2.0f);
	float slope = 0.0f;
	[branch] if (NVR_BounceSpill.x > 0.0f) {
		float2 texel = axis * NVR_BounceLayout.zw;
		float before = tex2Dlod(NVR_BounceBuffer, float4(IN.UVCoord - texel, 0.0f, 0.0f)).a;
		float after = tex2Dlod(NVR_BounceBuffer, float4(IN.UVCoord + texel, 0.0f, 0.0f)).a;
		if (hard) slope = (center.a - before) * (after - center.a) > 0.0f ? 1.5f * BlurRadius * min(abs(center.a - before), abs(after - center.a)) : 0.0f;
		else slope = 1.5f * BlurRadius * min(abs(center.a - before), abs(after - center.a));
	}
	float3 sum = center.rgb * 0.114725602f;
	float weights = 0.114725602f;
	[unroll]
	for (int i = 0; i < cKernelSize; i++) {
		float2 uv = IN.UVCoord + BlurOffsets[i] * axis * BlurRadius * (NVR_BounceLayout.zw / TESR_ReciprocalResolution.xy);
		float4 tap = tex2Dlod(NVR_BounceBuffer, float4(uv, 0.0f, 0.0f));
		float steps = abs(dot(BlurOffsets[i] / TESR_ReciprocalResolution.xy, axis));
		float weight = BlurWeights[i] * (abs(tap.a - center.a) <= tolerance + slope * steps);
		sum += tap.rgb * weight;
		weights += weight;
	}
	return float4(sum / weights, center.a);
}

float SpillBrightness(float3 c)
{
	float peak = max(c.r, max(c.g, c.b));
	float saturation = 1.0f - min(c.r, min(c.g, c.b)) / max(peak, 1.0e-4f);
	return lerp(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), peak, saturation);
}
float SpillAmount(float3 c, float threshold)
{
	return saturate((SpillBrightness(c) - threshold) / threshold);
}

float3 UpsampleHardEdges(float2 uv, float depth, float2 base, float2 fraction)
{
	float tolerance = max(depth * 0.03f, 2.0f);
	float2 px = TESR_ReciprocalResolution.xy;
	float left = readDepthLod(uv - float2(px.x, 0.0f)), right = readDepthLod(uv + float2(px.x, 0.0f));
	float up = readDepthLod(uv - float2(0.0f, px.y)), down = readDepthLod(uv + float2(0.0f, px.y));
	float slopeX = (depth - left) * (right - depth) > 0.0f ? min(abs(depth - left), abs(right - depth)) : 0.0f;
	float slopeY = (depth - up) * (down - depth) > 0.0f ? min(abs(depth - up), abs(down - depth)) : 0.0f;
	tolerance += 1.5f * (slopeX + slopeY) / NVR_BounceLayout.x;
	float3 sum = 0.0f;
	float weights = 1.0e-5f;
	[unroll] for (int y = 0; y < 2; y++) {
		[unroll] for (int x = 0; x < 2; x++) {
			float4 tap = tex2Dlod(NVR_BounceBuffer, float4((base + float2(x, y) + 0.5f) * NVR_BounceLayout.zw, 0.0f, 0.0f));
			float weight = (x ? fraction.x : 1 - fraction.x) * (y ? fraction.y : 1 - fraction.y) * (abs(tap.a - depth) <= tolerance);
			sum += tap.rgb * weight;
			weights += weight;
		}
	}
	return sum / weights;
}

float4 Combine(VSOUT IN, uniform bool hard) : COLOR0
{
	float4 color = tex2D(TESR_SourceBuffer, IN.UVCoord);
	float depth = readDepth(IN.UVCoord);
	[branch] if (depth < NearFade || depth > DrawDistance) return color;

	float2 position = IN.UVCoord / NVR_BounceLayout.zw - 0.5f;
	float2 base = floor(position);
	float2 fraction = position - base;
	float3 indirect;
	if (hard) indirect = UpsampleHardEdges(IN.UVCoord, depth, base, fraction);
	else {
	float tolerance = max(depth * 0.03f, 2.0f);
	[branch] if (NVR_BounceSpill.x > 0.0f) {
		float2 px = TESR_ReciprocalResolution.xy;
		float left = readDepthLod(IN.UVCoord - float2(px.x, 0.0f)), right = readDepthLod(IN.UVCoord + float2(px.x, 0.0f));
		float up = readDepthLod(IN.UVCoord - float2(0.0f, px.y)), down = readDepthLod(IN.UVCoord + float2(0.0f, px.y));
		float slope = min(abs(depth - left), abs(right - depth)) + min(abs(depth - up), abs(down - depth));
		tolerance += 1.5f * slope / NVR_BounceLayout.x;
	}
	float3 sum = 0.0f;
	float weights = 1.0e-5f;
	[unroll] for (int y = 0; y < 2; y++) {
		[unroll] for (int x = 0; x < 2; x++) {
			float4 tap = tex2Dlod(NVR_BounceBuffer, float4((base + float2(x, y) + 0.5f) * NVR_BounceLayout.zw, 0.0f, 0.0f));
			float weight = (x ? fraction.x : 1 - fraction.x) * (y ? fraction.y : 1 - fraction.y);
			weight /= 1.0f + abs(tap.a - depth) / tolerance;
			sum += tap.rgb * weight;
			weights += weight;
		}
	}
	indirect = sum / weights;
	}

	float3 lin = linearize(color.rgb);
	float peak = max(max(lin.r, lin.g), max(lin.b, 0.0001f));
	float3 albedo = lin / peak * 0.6f;
	[branch] if (NVR_SpillDebug.x > 0.5f) {
		float3 shown = NVR_SpillDebug.x < 1.5f ? lin * 0.12f + tex2Dlod(NVR_Spill0, float4(IN.UVCoord, 0.0f, 0.0f)).rgb
			: Strength * indirect * albedo;
		return delinearize(float4(shown, color.a));
	}
	[branch] if (NVR_BounceSpill.x > 0.0f && NVR_SpillOptions.z <= 0.0f) indirect *= 1.0f - SpillAmount(lin, max(NVR_SpillMemory.w, 0.002f));
	lin += Strength * indirect * albedo;
	return delinearize(float4(lin, color.a));
}

float3 LastFrame(float3 position)
{
	float4 clip = mul(float4(position, 1.0f), NVR_BounceReproject);
	float w = max(clip.w, 0.001f);
	return float3(clip.x / w * 0.5f + 0.5f, 0.5f - clip.y / w * 0.5f, clip.w);
}

float DepthTolerance(float3 position, float3 normal)
{
	float facing = max(abs(dot(normal, normalize(position))), 0.05f);
	float texel = 2.0f * NVR_BounceLayout.z / TESR_ProjectionTransform[0][0];
	return position.z * (0.03f + 2.0f * texel * sqrt(1.0f - facing * facing) / facing) + 4.0f;
}

float SpillMemoryTolerance(float3 position, float3 normal)
{
	float facing = max(abs(dot(normal, normalize(position))), 0.45f);
	float texel = 2.0f * NVR_BounceLayout.z / TESR_ProjectionTransform[0][0];
	return position.z * (0.02f + 2.0f * texel * sqrt(1.0f - facing * facing) / facing) + 2.0f;
}

float HistoryAt(float3 last, float tolerance, out float3 history)
{
	float2 position = last.xy / NVR_BounceLayout.zw - 0.5f;
	float2 base = floor(position);
	float2 f = position - base;
	float4 t00 = tex2Dlod(NVR_BounceHistory, float4((base + 0.5f) * NVR_BounceLayout.zw, 0.0f, 0.0f));
	float4 t10 = tex2Dlod(NVR_BounceHistory, float4((base + float2(1.5f, 0.5f)) * NVR_BounceLayout.zw, 0.0f, 0.0f));
	float4 t01 = tex2Dlod(NVR_BounceHistory, float4((base + float2(0.5f, 1.5f)) * NVR_BounceLayout.zw, 0.0f, 0.0f));
	float4 t11 = tex2Dlod(NVR_BounceHistory, float4((base + 1.5f) * NVR_BounceLayout.zw, 0.0f, 0.0f));
	float4 w = float4((1.0f - f.x) * (1.0f - f.y), f.x * (1.0f - f.y), (1.0f - f.x) * f.y, f.x * f.y);
	w *= abs(float4(t00.a, t10.a, t01.a, t11.a) - last.z) < tolerance;
	float sum = dot(w, 1.0f);
	history = (t00.rgb * w.x + t10.rgb * w.y + t01.rgb * w.z + t11.rgb * w.w) / max(sum, 1.0e-4f);
	float inside = all(last.xy > 0.0f) && all(last.xy < 1.0f) && last.z > NearFade;
	return inside ? sum : 0.0f;
}

static const float SpillNothing = 1.0f;
static const float SpillBaseWidth = 320.0f;
static const int SpillDirections = 8;
static const float SpillAreaShare = 0.589f;
static const float SpillPlaneSpread = 0.5f;
static const float2 SpillQuad[4] = { float2(-1.0f, -1.0f), float2(1.0f, -1.0f), float2(-1.0f, 1.0f), float2(1.0f, 1.0f) };

float3 SpillLight(float3 c, float threshold)
{
	float brightness = SpillBrightness(c);
	float amount = saturate((brightness - threshold) / threshold);
	[flatten] if (NVR_SpillShape.z > 0.0f) amount *= min(1.0f, NVR_SpillShape.z * threshold / max(brightness, 1.0e-4f));
	return c * amount;
}

VSOUT SpillVS(VSIN IN)
{
	VSOUT OUT = FrameVS(IN);
	OUT.UVCoord += 0.5f * (NVR_SpillTarget.xy - TESR_ReciprocalResolution.xy);
	return OUT;
}

struct SpillOut0
{
	float4 color : COLOR0;
	float4 steady : COLOR1;
};

SpillOut0 SpillDown0(VSOUT IN)
{
	float threshold = max(NVR_SpillMemory.w, 0.002f);
	float3 light = 0.0f;
	float weightedDepth = 0.0f, weights = 0.0f, nearest = SpillNothing;
	[unroll] for (int y = 0; y < 4; y++) {
		[unroll] for (int x = 0; x < 4; x++) {
			float2 uv = IN.UVCoord + (float2(x, y) - 1.5f) * 0.25f * NVR_SpillTarget.xy;
			float linear01 = tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).x;
			float z = linear01 * farZ;
			bool counts = z > NearFade && z < DrawDistance * 1.5f;
			float3 tap = counts ? SpillLight(linearize(tex2Dlod(TESR_SourceBuffer, float4(uv, 0.0f, 0.0f)).rgb), threshold) : 0.0f;
			float weight = dot(tap, 1.0f);
			light += tap;
			weightedDepth += linear01 * weight;
			weights += weight;
			nearest = counts ? min(nearest, linear01) : nearest;
		}
	}
	float4 result = float4(light * (1.0f / 16.0f), weights > 0.0f ? weightedDepth / weights : nearest);
	SpillOut0 OUT;
	OUT.color = result;
	OUT.steady = result;
	[branch] if (NVR_SpillSteady.x > 0.0f) {
		float3 average = result.rgb;
		[branch] if (NVR_SpillSteady.y > 0.0f) {
			float3 last = 0.0f;
			[branch] if (result.a < 0.999f * SpillNothing) {
				float3 where = NVR_SpillSteady.w > 0.5f ? float3(IN.UVCoord, result.a * farZ) : LastFrame(PositionFromLinear(IN.UVCoord, result.a));
				[branch] if (all(where.xy > 0.0f) && all(where.xy < 1.0f)) {
					float2 position = where.xy / NVR_SpillTarget.xy - 0.5f;
					float2 base = floor(position);
					float2 f = position - base;
					float3 sum = 0.0f;
					float weights = 0.0f;
					[unroll] for (int k = 0; k < 4; k++) {
						float2 corner = float2(k == 1 || k == 3, k >= 2);
						float4 t = tex2Dlod(NVR_SpillSteadyBuffer, float4((base + 0.5f + corner) * NVR_SpillTarget.xy, 0.0f, 0.0f));
						float2 w2 = corner > 0.5f ? f : 1.0f - f;
						float w = w2.x * w2.y * (abs(t.a * farZ - where.z) < where.z * 0.1f + 20.0f);
						sum += t.rgb * w;
						weights += w;
					}
					last = weights > 1.0e-4f ? sum / weights : 0.0f;
				}
			}
			average = lerp(last, result.rgb, NVR_SpillSteady.x);
		}
		OUT.steady = float4(average, result.a);
		OUT.color.rgb = NVR_SpillSteady.z > 0.5f ? average : min(result.rgb, average * 1.5f);
	}
	return OUT;
}

float4 SpillDown(VSOUT IN, uniform sampler2D level) : COLOR0
{
	float3 light = 0.0f;
	float weightedDepth = 0.0f, weights = 0.0f, nearest = SpillNothing;
	[unroll] for (int i = 0; i < 4; i++) {
		float4 tap = tex2Dlod(level, float4(IN.UVCoord + SpillQuad[i] * 0.5f * NVR_SpillTarget.zw, 0.0f, 0.0f));
		float weight = dot(tap.rgb, 1.0f);
		light += tap.rgb;
		weightedDepth += tap.a * weight;
		weights += weight;
		nearest = min(nearest, tap.a);
	}
	return float4(light * 0.25f, weights > 0.0f ? weightedDepth / weights : nearest);
}

void SpillStep(uniform sampler2D level, uniform float share, float distance, float2 uv, float2 direction, float3 origin,
	float3 normal, float pixelWorld, inout float horizon, inout float3 light)
{
	float2 sampleUV = uv + direction * distance;
	[branch] if (any(sampleUV != saturate(sampleUV))) return;
	float4 tap = tex2Dlod(level, float4(sampleUV, 0.0f, 0.0f));
	[branch] if (tap.a >= 0.999f * SpillNothing) return;
	float z = tap.a * farZ;
	float3 s = float3((sampleUV.x * 2.0f - 1.0f) / TESR_ProjectionTransform[0][0], (1.0f - sampleUV.y * 2.0f) / TESR_ProjectionTransform[1][1], 1.0f) * z;
	float3 toSample = s - origin;
	float dist2 = dot(toSample, toSample) + 1.0f;
	float rise = dot(normal, toSample) * rsqrt(dist2);
	float visible = saturate(1.0f + (rise - horizon) * 6.0f);
	float ring = distance * pixelWorld * origin.z;
	horizon = dist2 < 9.0f * ring * ring ? max(horizon, rise) : horizon;
	float area = SpillAreaShare * distance * distance * pixelWorld * pixelWorld * z * z;
	light += tap.rgb * (saturate(rise) * visible * area / (3.14159265f * dist2 + area) * lerp(NVR_SpillShape.x, NVR_SpillShape.y, share));
}

void SpillStepSeparate(uniform sampler2D level, uniform float share, uniform float scale, float distance, float2 uv, float2 direction,
	float3 origin, float3 normal, float pixelWorld, inout float horizon, inout float3 light)
{
	float2 sampleUV = uv + direction * distance;
	[branch] if (any(sampleUV != saturate(sampleUV))) return;
	float2 size = ceil(NVR_SpillOptions.xy * scale);
	float2 position = sampleUV * size - 0.5f;
	float2 base = floor(position);
	float2 f = position - base;
	float3 tapLight = 0.0f;
	float depthMixed = 0.0f, litSum = 0.0f, litDepth = 0.0f;
	float2 litUV = 0.0f;
	[unroll] for (int k = 0; k < 4; k++) {
		float2 corner = float2(k == 1 || k == 3, k >= 2);
		float2 texelUV = (base + 0.5f + corner) / size;
		float4 t = tex2Dlod(level, float4(texelUV, 0.0f, 0.0f));
		float2 w2 = corner > 0.5f ? f : 1.0f - f;
		float w = w2.x * w2.y;
		float l = w * dot(t.rgb, 1.0f);
		tapLight += t.rgb * w;
		depthMixed += t.a * w;
		litSum += l;
		litDepth += t.a * l;
		litUV += texelUV * l;
	}
	[branch] if (depthMixed >= 0.999f * SpillNothing) return;
	float3 o = float3((sampleUV.x * 2.0f - 1.0f) / TESR_ProjectionTransform[0][0], (1.0f - sampleUV.y * 2.0f) / TESR_ProjectionTransform[1][1], 1.0f) * (depthMixed * farZ) - origin;
	float oDist2 = dot(o, o) + 1.0f;
	float oRise = dot(normal, o) * rsqrt(oDist2);
	float ring = distance * pixelWorld * origin.z;
	float newHorizon = oDist2 < 9.0f * ring * ring ? max(horizon, oRise) : horizon;
	[branch] if (litSum <= 0.0f) { horizon = newHorizon; return; }
	float z = litDepth / litSum * farZ;
	litUV /= litSum;
	float3 ray = float3((litUV.x * 2.0f - 1.0f) / TESR_ProjectionTransform[0][0], (1.0f - litUV.y * 2.0f) / TESR_ProjectionTransform[1][1], 1.0f);
	float3 toSample = ray * z - origin;
	float dist2 = dot(toSample, toSample) + 1.0f;
	float rise = dot(normal, toSample) * rsqrt(dist2);
	float visible = saturate(1.0f + (rise - horizon) * 6.0f);
	horizon = newHorizon;
	float spread = SpillPlaneSpread * (abs(normal.x) / (size.x * TESR_ProjectionTransform[0][0]) + abs(normal.y) / (size.y * TESR_ProjectionTransform[1][1]));
	float onPlane = dot(normal, origin) / z;
	float offPlane = saturate(abs(dot(normal, ray) - onPlane) / (spread + 0.002f * abs(onPlane) + 1.0e-6f) - 1.0f);
	float area = SpillAreaShare * distance * distance * pixelWorld * pixelWorld * z * z;
	light += tapLight * (saturate(rise) * visible * offPlane * area / (3.14159265f * dist2 + area) * lerp(NVR_SpillShape.x, NVR_SpillShape.y, share));
}

float3 NeonSpill(float2 uv, float3 origin, float3 normal, float3 noise, uniform bool separate)
{
	float pixelWorld = 2.0f * TESR_ReciprocalResolution.x / TESR_ProjectionTransform[0][0];
	float first = NVR_BounceSpill.z * 1.5f / (SpillBaseWidth * TESR_ReciprocalResolution.x);
	float3 light = 0.0f;
	[loop] for (int i = 0; i < SpillDirections; i++) {
		float angle = (i + noise.x) * (6.2831853f / SpillDirections);
		float2 direction = float2(cos(angle), sin(angle)) * TESR_ReciprocalResolution.xy;
		float step = first * (0.75f + 0.5f * frac(noise.y + 0.5f + i * 0.618034f));
		float horizon = 0.0f;
		if (separate) {
			SpillStepSeparate(NVR_Spill0, 0.0f, 1.0f, step, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill1, 1.0f / 6.0f, 0.5f, step * 2.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill2, 2.0f / 6.0f, 0.25f, step * 4.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill3, 3.0f / 6.0f, 0.125f, step * 8.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill4, 4.0f / 6.0f, 0.0625f, step * 16.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill5, 5.0f / 6.0f, 0.03125f, step * 32.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			SpillStepSeparate(NVR_Spill6, 1.0f, 0.015625f, step * 64.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
			continue;
		}
		SpillStep(NVR_Spill0, 0.0f, step, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill1, 1.0f / 6.0f, step * 2.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill2, 2.0f / 6.0f, step * 4.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill3, 3.0f / 6.0f, step * 8.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill4, 4.0f / 6.0f, step * 16.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill5, 5.0f / 6.0f, step * 32.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
		SpillStep(NVR_Spill6, 1.0f, step * 64.0f, uv, direction, origin, normal, pixelWorld, horizon, light);
	}
	return light;
}

float4 SpillGather(VSOUT IN, uniform bool separate) : COLOR0
{
	float2 uv = IN.UVCoord;
	float3 origin = PositionFromLinear(uv, tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).x);
	float fade = smoothstep(NearFade, NearFade * 2.0f, origin.z) * (1.0f - smoothstep(DrawDistance * 0.7f, DrawDistance, origin.z));
	[branch] if (fade <= 0.0f) return float4(0.0f, 0.0f, 0.0f, origin.z);
	float3 normal = NormalLod(uv);
	float3 noise = tex2Dlod(TESR_BlueNoiseSampler, float4(uv / (256.0f * NVR_BounceLayout.zw), 0.0f, 0.0f)).xyz;
	noise.xy = frac(noise.xy + NVR_BounceTemporal.z * float2(0.618034f, 0.754878f));
	float3 where = LastFrame(origin);
	float3 spill = NeonSpill(uv, origin, normal, noise, separate) * fade;
	[branch] if (NVR_SpillMemory.x > 0.0f) {
		float3 last;
		float matched = HistoryAt(where, SpillMemoryTolerance(origin, normal), last);
		float found = saturate(2.0f * matched);
		float whole = saturate((matched - 0.95f) * 20.0f);
		float moving = max(saturate(0.5f * length((where.xy - uv) / NVR_BounceLayout.zw)), NVR_SpillMemory.z);
		spill = max(lerp(spill, last, NVR_SpillMemory.x * found), last * (NVR_SpillMemory.y * moving * whole));
	}
	return float4(spill, origin.z);
}

float4 PreparePlus(VSOUT IN) : COLOR0
{
	float2 uv = IN.UVCoord;
	float linear01 = tex2Dlod(TESR_DepthBuffer, float4(uv, 0.0f, 0.0f)).x;
	float3 normal = NormalLod(uv);
	float3 scene = linearize(tex2Dlod(TESR_SourceBuffer, float4(uv, 0.0f, 0.0f)).rgb);
	float3 light = min(scene, 1.0f);
	[branch] if (NVR_BounceTemporal.y > 0.0f) {
		float3 position = PositionFromLinear(uv, linear01);
		float3 last;
		float found = HistoryAt(LastFrame(position), DepthTolerance(position, normal), last);
		[branch] if (found > 0.0f) {
			float peak = max(max(scene.r, scene.g), max(scene.b, 0.0001f));
			light = min(light + (NVR_BounceTemporal.y * saturate(found * 2.0f) * Strength * 0.6f / peak) * last * scene, 1.0f);
		}
	}
	return float4(linear01, Pack2(OctEncode(normal)), Pack2(sqrt(light.rg)), light.b);
}

float4 GatherPlus(VSOUT IN, uniform int samples, uniform bool temporal, uniform float motionPixels) : COLOR0
{
	float2 uv = IN.UVCoord;
	float4 center = tex2Dlod(NVR_BouncePrep, float4(uv, 0.0f, 0.0f));
	float3 origin = PositionFromLinear(uv, center.x);
	float fade = smoothstep(NearFade, NearFade * 2.0f, origin.z) * (1.0f - smoothstep(DrawDistance * 0.7f, DrawDistance, origin.z));
	[branch] if (fade <= 0.0f) return float4(0.0f, 0.0f, 0.0f, origin.z);

	float3 normal = OctDecode(Unpack2(center.y));
	float3 noise = tex2Dlod(TESR_BlueNoiseSampler, float4(uv / (256.0f * NVR_BounceLayout.zw), 0.0f, 0.0f)).xyz;
	if (temporal) noise.xy = frac(noise.xy + NVR_BounceTemporal.z * float2(0.618034f, 0.754878f));
	float3 up = abs(normal.z) < 0.99f ? float3(0.0f, 0.0f, 1.0f) : float3(1.0f, 0.0f, 0.0f);
	float3 tangent = normalize(cross(up, normal));
	float3 bitangent = cross(normal, tangent);
	float radius = min(Radius, MaxScreenRadius * 2.0f * origin.z / TESR_ProjectionTransform[0][0]);

	float3 indirect = 0.0f;
	float seenWeight = 0.0f, seen = 0.0f;
	[unroll]
	for (int i = 0; i < samples; i++) {
		float angle = (i + noise.x) * (6.2831853f / samples);
		float r = radius * (0.15f + 0.85f * frac(noise.y + i * 0.618034f));
		float3 p = origin + (tangent * cos(angle) + bitangent * sin(angle)) * r + normal * (r * 0.25f);
		float2 sampleUV = projectPosition(p).xy;
		float onScreen = step(0.0f, sampleUV.x) * step(sampleUV.x, 1.0f) * step(0.0f, sampleUV.y) * step(sampleUV.y, 1.0f);
		sampleUV = (floor(saturate(sampleUV) / NVR_BounceLayout.zw) + 0.5f) * NVR_BounceLayout.zw;

		float4 texel = tex2Dlod(NVR_BouncePrep, float4(sampleUV, 0.0f, 0.0f));
		float3 s = PositionFromLinear(sampleUV, texel.x);
		float3 toSample = s - origin;
		float dist = length(toSample) + 0.001f;
		float3 dir = toSample / dist;
		float nearAim = saturate(1.0f - length(s - p) / radius);
		float visible = onScreen * step(NearFade, s.z);
		float weight = saturate(dot(normal, dir)) * saturate(dot(OctDecode(Unpack2(texel.y)), -dir)) * nearAim * visible;
		float2 rg = Unpack2(texel.z);
		indirect += float3(rg * rg, texel.w) * weight;
		seenWeight += weight;
		seen += visible;
	}
	float3 seenLight = indirect / max(seenWeight, 1.0e-4f);
	float unknownWeight = (samples - seen) * seenWeight / max(seen, 1.0f);
	indirect += lerp(NVR_BounceAmbient.rgb, seenLight, seen / samples) * (unknownWeight * NVR_BounceAmbient.w);
	float3 result = indirect * (2.0f / samples * NVR_BounceSpill.y) * fade;
	[branch] if (NVR_BounceSpill.x > 0.0f) {
		float3 spill = tex2Dlod(NVR_Spill0, float4(uv, 0.0f, 0.0f)).rgb;
		[branch] if (NVR_SpillOptions.z > 0.0f) spill *= 1.0f - SpillAmount(linearize(tex2Dlod(TESR_SourceBuffer, float4(uv, 0.0f, 0.0f)).rgb), max(NVR_SpillOptions.w, 0.002f));
		result += spill * NVR_BounceSpill.x;
	}
	if (temporal) {
		float3 last;
		float3 where = LastFrame(origin);
		float found = HistoryAt(where, DepthTolerance(origin, normal), last);
		float moved = length((where.xy - uv) / NVR_BounceLayout.zw);
		result = lerp(result, last, NVR_BounceTemporal.x / (1.0f + moved / motionPixels) * saturate(found * 2.0f));
	}
	return float4(result, origin.z);
}

technique
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Prepare(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Gather(); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), false); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), false); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(false); }
}

technique BounceLightPlus
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(8, false, 1.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), false); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), false); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(false); }
}

technique BounceLightTemporal
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(8, true, 4.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), false); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), false); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(false); }
}

technique BounceLightTemporalHalf
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(4, true, 8.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), false); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), false); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(false); }
}

technique BounceLightPlusHardEdges
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(8, false, 1.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), true); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), true); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(true); }
}

technique BounceLightTemporalHardEdges
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(8, true, 4.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), true); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), true); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(true); }
}

technique BounceLightTemporalHalfHardEdges
{
	pass Prepare { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 PreparePlus(); }
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 GatherPlus(4, true, 8.0f); }
	pass BlurX { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(1.0f, 0.0f), true); }
	pass BlurY { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 Blur(float2(0.0f, 1.0f), true); }
	pass Combine { VertexShader = compile vs_3_0 FrameVS(); PixelShader = compile ps_3_0 Combine(true); }
}

technique BounceSpillPyramid
{
	pass Level0 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown0(); }
	pass Level1 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill0); }
	pass Level2 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill1); }
	pass Level3 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill2); }
	pass Level4 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill3); }
	pass Level5 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill4); }
	pass Level6 { VertexShader = compile vs_3_0 SpillVS(); PixelShader = compile ps_3_0 SpillDown(NVR_Spill5); }
}

technique BounceSpillGather
{
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 SpillGather(false); }
}

technique BounceSpillGatherSeparate
{
	pass Gather { VertexShader = compile vs_3_0 HalfVS(); PixelShader = compile ps_3_0 SpillGather(true); }
}
