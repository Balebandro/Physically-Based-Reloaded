// Rain particles culled under cover: the rain meshes (3D Rain's strip particles, Honest Hearts' rain)
// drawn with the game's NoLighting shaders, plus one test -- is anything above this pixel?
//
// NVR binds this pair in place of the game's NOLIGHT pair for rain draws only (Hooks/Shaders.cpp,
// RainParticles): fire, glows and every other NoLighting mesh keep the game's shaders. It reproduces
// the game's shaders exactly, on the same registers, so the constants the engine uploads for its own
// pair land where this one reads them:
//   vertex: NOLIGHT000/002/016 (textured), 017 (+ particle sub-texture offsets), 018/019 (+ normal
//           falloff); VERTEX_COLOR where the game's has a colour stream
//   pixel:  NOLIGHTTEX, NOLIGHTTEXVC (fog to colour, fog to black or fog to white, by Toggles),
//           NOLIGHTTEXVCPMA (premultiplied)
// and adds the camera-relative position's place in NVR's top-down ortho depth map: under a roof, a
// porch, a bridge or an overhang the rain fades out over the map's edge.

// --- Soft particles --------------------------------------------------------------------------------
// The pair the rain is actually drawn with in this setup (vs_3_0/ps_3_0, read off the device): soft
// particles, fading where they meet the scene through its depth (DepthMap, SoftScaleAndScreenSize,
// DepthConstants). SOFT reproduces both seen: the streaks (no sub-textures, no falloff, premultiplied:
// PMA) and the mist (SUBTEX + FALLOFF, the fog modes of NOLIGHTTEXVC with MaterialAlpha as the toggles).

#if defined(VS) && defined(SOFT)

row_major float4x4 WorldViewProjMatrix : register(c0);
float4 TexCoordTranform[2] : register(c4);
float4 FogParam : register(c13);
float4 SubTexOffsets[16] : register(c15);
row_major float3x4 WorldViewMatrix : register(c36);
float4 Falloff : register(c40);
row_major float4x4 RainClipToOrtho : register(c200);

struct VS_INPUT {
    float4 position : POSITION;
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 soft : TEXCOORD1;      // x: soft scale, y: sub-texture index
#ifdef FALLOFF
    float3 normal : NORMAL;
#endif
};

struct VS_OUTPUT {
    float4 position : POSITION;
    float4 uv : TEXCOORD0;        // xy uv, z alpha (falloff), w fog
    float4 color : COLOR0;
    float2 soft : TEXCOORD1;      // x: clip w, y: soft scale
    float4 ortho : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;
    float4 clip = mul(WorldViewProjMatrix, IN.position);
    OUT.position = clip;
    OUT.soft = float2(clip.w, IN.soft.x);

    float fog = saturate((FogParam.x - length(float3(clip.xy, clip.w - clip.z))) / FogParam.y);
    OUT.uv.w = pow(abs(1.0f - fog), FogParam.z);

#ifdef SUBTEX
    float4 offsets = SubTexOffsets[(int)floor(IN.soft.y)];
    OUT.uv.xy = offsets.yw * IN.uv.xy + offsets.xz;
#else
    float3 uv1 = float3(IN.uv.xy, 1.0f);
    OUT.uv.x = dot(TexCoordTranform[0].xyz, uv1);
    OUT.uv.y = dot(TexCoordTranform[1].xyz, uv1);
#endif

#ifdef FALLOFF
    float3 viewPos = normalize(mul(WorldViewMatrix, float4(IN.position.xyz, 1.0f)));
    float3 viewNormal = normalize(mul((float3x3)WorldViewMatrix, IN.normal));
    float t = saturate((abs(dot(viewPos, viewNormal)) - Falloff.x) / (Falloff.y - Falloff.x));
    OUT.uv.z = t * t * (3.0f - 2.0f * t) * (Falloff.w - Falloff.z) + Falloff.z;
#else
    OUT.uv.z = 1.0f;
#endif

    OUT.color = IN.color;
    OUT.ortho = mul(clip, RainClipToOrtho);
    return OUT;
}

#endif // VS && SOFT

#if defined(VS) && !defined(SOFT)

row_major float4x4 ModelViewProj : register(c0);
float4 TexCoordTranform[2] : register(c4);
float4 FogParam : register(c13);
float4 SubTexOffsets[16] : register(c15);
row_major float3x4 WorldView : register(c36);
float4 Falloff : register(c40);

// NVR: clip space straight to the ortho map's space (inverse camera-relative view-projection x ortho).
row_major float4x4 RainClipToOrtho : register(c200);

struct VS_INPUT {
    float4 position : POSITION;
#ifdef FALLOFF
    float3 normal : NORMAL;
#endif
    float4 uv : TEXCOORD0;
#ifdef SUBTEX
    float4 subTex : TEXCOORD1;
#endif
#ifdef VERTEX_COLOR
    float4 color : COLOR0;
#endif
};

struct VS_OUTPUT {
    float4 position : POSITION;
    float4 uv : TEXCOORD0;        // xy uv, z alpha (falloff), w fog
    float4 color : COLOR0;
    float4 ortho : TEXCOORD1;     // homogeneous, divided in the pixel shader
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;
    float4 clip = mul(ModelViewProj, IN.position);
    OUT.position = clip;

#ifdef SUBTEX
    float4 offsets = SubTexOffsets[(int)floor(IN.subTex.x)];
    OUT.uv.xy = offsets.yw * IN.uv.xy + offsets.xz;
#else
    float3 uv1 = float3(IN.uv.xy, 1.0f);
    OUT.uv.x = dot(TexCoordTranform[0].xyz, uv1);
    OUT.uv.y = dot(TexCoordTranform[1].xyz, uv1);
#endif

#ifdef FALLOFF
    float3 viewPos = normalize(mul(WorldView, float4(IN.position.xyz, 1.0f)));
    float3 viewNormal = normalize(mul((float3x3)WorldView, IN.normal));
    float t = saturate((abs(dot(viewNormal, viewPos)) - Falloff.x) / (Falloff.y - Falloff.x));
    OUT.uv.z = t * t * (3.0f - 2.0f * t) * (Falloff.w - Falloff.z) + Falloff.z;
#else
    OUT.uv.z = 1.0f;
#endif

    float fog = saturate((FogParam.x - length(clip.xyz)) / FogParam.y);
    OUT.uv.w = pow(abs(1.0f - fog), FogParam.z);

#ifdef VERTEX_COLOR
    OUT.color = IN.color;
#else
    OUT.color = 1.0f;
#endif

    OUT.ortho = mul(clip, RainClipToOrtho);
    return OUT;
}

#endif // VS

#ifdef PS

sampler2D DiffuseMap : register(s0);
float4 MaterialColor : register(c0);
float4 Toggles : register(c1);
float4 FogColor : register(c2);

// NVR: x ortho map texel size (0: no map, keep the rain), y bias.
float4 RainCoverData : register(c200);
sampler2D RainOrthoMap : register(s8);

#ifdef SOFT
// The soft particles' scene depth (s1, the engine's own) and its constants.
sampler2D DepthMap : register(s1);
float4 SoftScaleAndScreenSize : register(c8);   // x: soft scale, zw: 1 / screen size
float4 DepthConstants : register(c9);

struct PS_INPUT {
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float2 soft : TEXCOORD1;      // x: clip w, y: soft scale
    float4 ortho : TEXCOORD2;
    float2 screen : VPOS;
};

// Faded where the particle meets the scene, as the engine's soft particles.
float SoftFade(PS_INPUT IN) {
    float depth = tex2D(DepthMap, (IN.screen + 0.5f) * SoftScaleAndScreenSize.zw).x;
    float sceneW = DepthConstants.w / (depth * DepthConstants.z + DepthConstants.x);
    return saturate((sceneW - IN.soft.x) / (SoftScaleAndScreenSize.x * IN.soft.y));
}
#else
struct PS_INPUT {
    float4 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 ortho : TEXCOORD1;
};
#endif

// 1 open to the sky, 0 under something; four taps so a roof's edge is a short fade, not a stair.
float OpenSky(float4 ortho) {
    float texel = RainCoverData.x;
    [branch] if (texel <= 0.0f) return 1.0f;
    float3 o = ortho.xyz / ortho.w;
    if (any(abs(o.xy) > 1.0f) || o.z < 0.0f || o.z > 1.0f) return 1.0f;
    float2 uv = float2(o.x * 0.5f + 0.5f, o.y * -0.5f + 0.5f);
    float bias = RainCoverData.y;
    float open = 0.0f;
    open += tex2Dlod(RainOrthoMap, float4(uv + float2(-0.5f, -0.5f) * texel, 0.0f, 0.0f)).r > o.z - bias ? 0.25f : 0.0f;
    open += tex2Dlod(RainOrthoMap, float4(uv + float2( 0.5f, -0.5f) * texel, 0.0f, 0.0f)).r > o.z - bias ? 0.25f : 0.0f;
    open += tex2Dlod(RainOrthoMap, float4(uv + float2(-0.5f,  0.5f) * texel, 0.0f, 0.0f)).r > o.z - bias ? 0.25f : 0.0f;
    open += tex2Dlod(RainOrthoMap, float4(uv + float2( 0.5f,  0.5f) * texel, 0.0f, 0.0f)).r > o.z - bias ? 0.25f : 0.0f;
    return open;
}

float4 main(PS_INPUT IN) : COLOR0 {
    float4 texel = tex2D(DiffuseMap, IN.uv.xy);
    float4 c = texel * IN.color * MaterialColor;
    // Most of a rain quad is see-through: those pixels add nothing, so they skip the cover test's
    // taps (and the soft fade's depth read) and are dropped. Premultiplied, the alpha alone says so;
    // otherwise the colour must be black too, in case the pass blends additively.
#ifdef PMA
    float visible = c.a * IN.uv.z;
#else
    float visible = max(c.a * IN.uv.z, max(c.r, max(c.g, c.b)));
#endif
    float open = 0.0f;
    [branch] if (visible > 0.002f) open = OpenSky(IN.ortho);
    clip(open - 0.001f);
    float fog = IN.uv.w;
#ifdef SOFT
    open *= SoftFade(IN);
#endif

#ifdef PMA
    // NOLIGHTTEXVCPMA: premultiplied, faded by the fog.
    float alpha = c.a * IN.uv.z * open;
    return float4(c.rgb * (1.0f - fog) * alpha, 1.0f);
#else
    // NOLIGHTTEX / NOLIGHTTEXVC.
    float3 fogged = lerp(c.rgb, FogColor.rgb, fog);     // fog to the fog colour
    float3 faded = c.rgb * (1.0f - fog);                 // fog to black (additive)
    float3 mode = lerp(fogged, faded, Toggles.x);
    float3 bright = c.rgb + saturate(fog * 1.5f) * (1.0f - c.rgb);   // fog to white
    return float4(lerp(mode, bright, Toggles.y), c.a * IN.uv.z * open);
#endif
}

#endif // PS
