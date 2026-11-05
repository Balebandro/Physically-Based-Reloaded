// UNOFFICIAL 2026-11-05 deferred flashlight (core/FlashlightDeferred.h; ported from Vegas Shaders, user: "port over the new flashlight
// we did to PB NVR"). The player's flashlight as a real spot light: ONE full-screen pass right after the world's main opaque list, lighting
// each pixel's own surface from the G-buffer (core/GBuffer.h: its colour, material and normal) with the object shaders' own direct light
// (Object.hlsl directLight: OpenPBR / Anomaly for authored materials, Lambert + the vanilla highlight otherwise), times the cone (smooth
// from its outer edge in to half its angle), the falloff and the flashlight's shadow map (the spot map ShadowManager draws from the
// light, PCF). Added to the frame ONE / ONE as the difference it makes, enc(dec(frame) + light) - frame, from a copy of the frame (each
// MSAA sample keeps its own value). Depth-tested at the G-buffer's surface, so what was drawn over it without writing it is not lit as
// the surface behind. What is not in the G-buffer (grass, water, decals, alpha-blended things, the first-person view) is not lit by it.

#include "includes/Helpers.hlsl"
#include "includes/Object.hlsl"
#include "includes/GBuffer.hlsl"

// The pass's own constants (c0-c14; nothing the includes use lives there: FlashlightDeferred::Apply). Object.hlsl's c148 / c149 / c151
// (TESR_PBRData, TESR_PBRExtraData, TESR_PBRSpecularData) and c152 (MaterialMap, 0 here) are set by the pass too.
float4 FL_Depth    : register(c0);	// x, y the projection's _33, _43 (depth = x + y / view z), z the share and w the units the surface is pulled toward the camera
float4 FL_View     : register(c1);	// xy 1 / viewport size, zw the viewport's top-left corner (pixels)
float4 FL_Right    : register(c2);	// xyz the camera's right axis, w tan(half fov x)
float4 FL_Up       : register(c3);	// xyz up, w tan(half fov y)
float4 FL_Fwd      : register(c4);	// xyz forward
float4 FL_Pos      : register(c5);	// xyz the light, camera-relative, w its reach (game units)
float4 FL_Dir      : register(c6);	// xyz the beam's axis (unit), w cos of the cone's outer edge
float4 FL_Color    : register(c7);	// rgb the light (linear, times Dimmer), w cos of the full-strength edge
float4 FL_Gamma    : register(c8);	// x 1 = linear lighting (the frame is encoded with the gamma), z the gamma, w 1 / the gamma
float4 FL_Shadow   : register(c9);	// x 1 = the shadow map is there, y its texel size (0-1), z the depth bias (share of the reach), w PCF radius (texels)
float4 FL_Look     : register(c10);	// y DebugView (0 off, 1 the light alone, 2 the shadow, 3 the normal), z Falloff (0: the lamps' 1 - d^2 / r^2)
row_major float4x4 FL_LightViewProj : register(c11);	// c11-c14: camera-relative world -> the shadow map's clip space

sampler2D FL_Frame    : register(s0);	// the frame's copy
sampler2D FL_Albedo   : register(s1);	// TESR_GBufferAlbedo
sampler2D FL_Material : register(s4);	// TESR_GBufferMaterial
sampler2D FL_Normals  : register(s5);	// TESR_GBufferNormal
sampler2D FL_ShadowMap : register(s6);	// the flashlight's spot shadow map: r the distance to the light over its reach (1 nothing)

struct PS_IN { float2 uv : TEXCOORD0; float2 vpos : VPOS; };

// One bilinear PCF tap: the four texels round uv compared, weighted by uv's place between them (a smooth edge, not a texel step).
float FLShadowTap(float2 uv, float distShare, float bias) {
    const float size = 1.0f / FL_Shadow.y;
    const float2 t = uv * size - 0.5f;
    const float2 f = frac(t);
    const float2 base = (floor(t) + 0.5f) * FL_Shadow.y;
    const float s00 = tex2Dlod(FL_ShadowMap, float4(base, 0.0f, 0.0f)).r + bias > distShare ? 1.0f : 0.0f;
    const float s10 = tex2Dlod(FL_ShadowMap, float4(base + float2(FL_Shadow.y, 0.0f), 0.0f, 0.0f)).r + bias > distShare ? 1.0f : 0.0f;
    const float s01 = tex2Dlod(FL_ShadowMap, float4(base + float2(0.0f, FL_Shadow.y), 0.0f, 0.0f)).r + bias > distShare ? 1.0f : 0.0f;
    const float s11 = tex2Dlod(FL_ShadowMap, float4(base + FL_Shadow.yy, 0.0f, 0.0f)).r + bias > distShare ? 1.0f : 0.0f;
    return lerp(lerp(s00, s10, f.x), lerp(s01, s11, f.x), f.y);
}

// The spot map's lit share at a camera-relative point: 16 bilinear PCF taps on a Vogel spiral over a disc of FL_Shadow.w texels. 1 outside the map.
float FLShadow(float3 position, float distShare) {
    const float4 clip = mul(float4(position, 1.0f), FL_LightViewProj);
    const float2 mapUV = clip.xy / max(clip.w, 1.0e-4f) * float2(0.5f, -0.5f) + 0.5f;
    [branch] if (FL_Shadow.x < 0.5f || clip.w <= 0.0f || any(mapUV < 0.0f) || any(mapUV > 1.0f)) return 1.0f;
    const float radius = FL_Shadow.y * FL_Shadow.w;
    const float bias = FL_Shadow.z * (1.0f + 4.0f * distShare);
    float2 dir = float2(1.0f, 0.0f);
    const float2x2 golden = float2x2(-0.7373688f, -0.6754904f, 0.6754904f, -0.7373688f);	// a turn by the golden angle (2.39996 rad)
    float lit = 0.0f;
    [unroll] for (int i = 0; i < 16; i++) {
        lit += FLShadowTap(mapUV + dir * (radius * sqrt((i + 0.5f) / 16.0f)), distShare, bias);
        dir = mul(golden, dir);
    }
    return lit / 16.0f;
}

float3 FLDecode(float3 c) { return FL_Gamma.x > 0.5f ? pow(max(c, 0.0f), FL_Gamma.z) : c; }
float3 FLEncode(float3 c) { return FL_Gamma.x > 0.5f ? pow(max(c, 0.0f), FL_Gamma.w) : c; }

float4 main(PS_IN IN, out float depth : DEPTH) : COLOR0 {
    const float4 uv4 = float4(IN.uv, 0.0f, 0.0f);
    const float4 stored = tex2Dlod(FL_Normals, uv4);
    depth = 0.0f;
    clip(stored.b - 1.0e-3f);	// nothing the G-buffer holds here
    const float4 m = tex2Dlod(FL_Material, uv4);
    const float4 a = tex2Dlod(FL_Albedo, uv4);
    // 1 - fog: the share of added light the draw's fog lets through. The land (class 4) takes it whole: in terrain blending's fade it is
    // drawn alpha-blended, so its G-buffer values blend toward what is behind (Vegas Shaders 2026-11-05: the beam skipped faded land).
    const float materialClass = floor(m.r + 0.01f);
    const float keep = abs(materialClass - 4.0f) < 0.5f ? 1.0f : a.a;
    clip(keep - 1.0e-4f);

    // the pixel's camera-relative position along its view ray
    const float2 local = (IN.vpos - FL_View.zw + 0.5f) * FL_View.xy;
    const float3 ray = normalize(FL_Fwd.xyz + FL_Right.xyz * ((local.x * 2.0f - 1.0f) * FL_Right.w) + FL_Up.xyz * ((1.0f - local.y * 2.0f) * FL_Up.w));
    const float3 position = ray * stored.b;
    // depth-tested at the G-buffer's surface (a little nearer, for its own precision): where something nearer was drawn, it fails
    const float viewZ = max(dot(position, FL_Fwd.xyz) * (1.0f - FL_Depth.z) - FL_Depth.w, 1.0f);
    depth = saturate(FL_Depth.x + FL_Depth.y / viewZ);

    // the cone and the reach
    const float3 toLight = FL_Pos.xyz - position;
    const float dist = length(toLight);
    clip(FL_Pos.w - dist);
    const float coneCos = dot(-toLight / max(dist, 1.0e-3f), FL_Dir.xyz);
    clip(coneCos - FL_Dir.w);
    const float cone = smoothstep(FL_Dir.w, FL_Color.w, coneCos);
    // Falloff > 0, a windowed inverse square, (1 - d^2/r^2)^2 / (1 + F d^2/r^2); 0 the lamps' 1 - d^2/r^2
    const float reachShare2 = dot(toLight, toLight) / (FL_Pos.w * FL_Pos.w);
    const float window = saturate(1.0f - reachShare2);
    const float falloff = FL_Look.z > 0.0f ? window * window / (1.0f + FL_Look.z * reachShare2) : window;
    const float att = falloff * cone * cone;

    const float shadow = FLShadow(position, dist / FL_Pos.w);

    // The surface as the object shaders lit it (Object.hlsl setupMaterial's state, from the G-buffer).
    linearLighting = FL_Gamma.x > 0.5f;
    lightingGamma = FL_Gamma.z;
    const float3 N = GBufferDecodeNormal(stored.rg);
    const float3 albedo = FLDecode(a.rgb);
    pbrMaterial = m.b >= 0.0f;
    pbrMetalness = saturate((m.r - materialClass) / 0.49f);
    pbrSpecularWeight = saturate(m.g);
    pbrRoughness = clamp(m.b, 0.04f, 1.0f);
    pbrEta = OpenPBR_ModulatedIOR(pbrSpecularWeight);
    pbrAlbedo = albedo;
    vanillaMask = pbrMaterial ? 0.0f : saturate(m.g);
    vanillaShine = max(-m.b, 1.0f);
    mergedSpecular = !pbrMaterial;	// the vanilla highlight with the diffuse (directLight's base-pass path)
    const float3 light = directLight(toLight, FL_Color.rgb * (att * shadow * keep) * LIGHT_SCALE, -ray, N, albedo);

    [branch] if (FL_Look.y > 0.5f) {	// the debug views, written over the frame (blend off: FlashlightDeferred::Apply)
        const float3 dbg = FL_Look.y < 1.5f ? light : FL_Look.y < 2.5f ? shadow.xxx : N * 0.5f + 0.5f;
        return float4(FLEncode(dbg), 1.0f);
    }
    const float3 frame = max(tex2Dlod(FL_Frame, uv4).rgb, 0.0f);
    return float4(max(FLEncode(FLDecode(frame) + light) - frame, 0.0f), 0.0f);
}
