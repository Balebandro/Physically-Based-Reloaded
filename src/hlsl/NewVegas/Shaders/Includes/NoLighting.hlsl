// UNOFFICIAL 2026-11-05 soft particles on every unlit (NoLighting) draw: the NOLIGHT vertex and pixel shaders without NVR's lighting
// (glows, muzzle flashes, fire, sparks, lamp cards, the dust storm walls, particle systems with falloff), ported from Vanilla Plus
// Particles' NoLighting.hlsl (pr0bability, github.com/pr0bability/fnv-vanilla-plus-particles, GPL-3.0, as this project). The math is
// the game's as LOD Flicker Fix draws it (its fog distance from the reversed depth); the only addition is the soft fade
// (Includes/SoftParticle.hlsl): alpha-blended draws fade where the scene behind them is nearer than their size x SoftScale. The
// lit particle shaders (NOLIGHT006/016/017.vso, NOLIGHTTEXVC.pso) keep their own files and share the outputs below.
//
// Defines: VS or PS; TEX, VC, FALLOFF, PSYS (TEX + VC, the size on the vertices: core/ParticleSize.h), SUBTEX (with PSYS: the
// texture-sheet frame), PREMULT_ALPHA (PS). Skinned variants (NOLIGHT008-015) are not here: they stay the game's, and the pairing
// guard (Render.cpp SetShadersHook) gives their draws the game's pixel shader too.

#ifdef PSYS
    #define TEX
    #define VC
#endif

#ifdef VS

row_major float4x4 WorldViewProj : register(c0);
row_major float3x3 TexCoordTranform : register(c4); // the engine's spelling; rows 0 and 1 (c4, c5) are used
float4 FogParam : register(c13);                     // x: fog start, y: fog range, z: fog power
float4 SubTexOffsets[16] : register(c15);            // per frame of the sheet: xz offset, yw scale
row_major float4x4 WorldView : register(c36);        // rows 0-2 (c36-c38) are used
float4 Falloff : register(c40);                      // x, y: edge-on .. face-on range of |N.V|, z, w: alpha there
float4 NVR_SoftSize : register(c41);                 // set per draw (effects/Particles ForDraw): x: the mesh's size (world bound radius), y: 1 when alpha-blended

struct VS_INPUT {
    float4 position : POSITION;
#ifdef TEX
    float4 uv : TEXCOORD0;
#endif
#ifdef SUBTEX
    float4 frame : TEXCOORD1;   // x: frame of the texture sheet
#endif
#ifdef PSYS
    float size : TEXCOORD2;     // the particle's size (core/ParticleSize.h; 0 without it)
#endif
#ifdef VC
    float4 color : COLOR0;
#endif
#ifdef FALLOFF
    float4 normal : NORMAL;
#endif
};

struct VS_OUTPUT {
    float4 sPosition : POSITION;
    float4 uv : TEXCOORD0;             // xy: texture, z: falloff alpha, w: fog
#ifdef VC
    float4 color : COLOR0;
#endif
    float4 shadowWorldPos : TEXCOORD1; // 0: not lit (NOLIGHTTEXVC.pso lights only behind the sentinel of NOLIGHT006/016/017)
    float4 vertexLight : TEXCOORD2;
    float2 depthSize : TEXCOORD3;      // x: view depth (clip w), y: soft size (0: not soft)
};

VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float4 position = mul(WorldViewProj, IN.position);
    OUT.sPosition = position;

    // UNOFFICIAL 2026-11-05 (user: far smoke not fogged): the fog distance as the scene's shaders take it (ObjectTemplate, TerrainTemplate):
    // the clip position, its z turned back with reversed depth (REVERSED_DEPTH, ShaderRecord::AppendGlobalDefines)
    float3 fogPos = position.xyz;
#ifdef REVERSED_DEPTH
    fogPos.z = position.w - position.z;
#endif
    float fog = pow(1.0f - saturate((FogParam.x - length(fogPos)) / FogParam.y), FogParam.z);

#ifdef FALLOFF
    float3 toVertex = normalize(mul(WorldView, float4(IN.position.xyz, 1.0f)).xyz);
    float3 normal = normalize(mul((float3x3)WorldView, IN.normal.xyz));
    float t = saturate((abs(dot(toVertex, normal)) - Falloff.x) / (Falloff.y - Falloff.x));
    float falloff = t * t * (3.0f - 2.0f * t) * (Falloff.w - Falloff.z) + Falloff.z;
#else
    float falloff = 1.0f;
#endif

#if defined(SUBTEX)
    float4 frame = SubTexOffsets[(int)(IN.frame.x - frac(IN.frame.x))];
    OUT.uv.xy = frame.yw * IN.uv.xy + frame.xz;
#elif defined(TEX)
    float3 uv = float3(IN.uv.xy, 1.0f);
    OUT.uv.x = dot(TexCoordTranform[0], uv);
    OUT.uv.y = dot(TexCoordTranform[1], uv);
#else
    OUT.uv.xy = 0.0f;
#endif
    OUT.uv.z = falloff;
    OUT.uv.w = fog;

#ifdef VC
    OUT.color = IN.color;
#endif
    OUT.shadowWorldPos = 0.0f;
    OUT.vertexLight = 0.0f;
#ifdef PSYS
    OUT.depthSize = float2(position.w, IN.size * NVR_SoftSize.y);
#else
    OUT.depthSize = float2(position.w, NVR_SoftSize.x);
#endif
    return OUT;
}

#else // PS

#include "includes/SoftParticle.hlsl"

float4 MaterialColor : register(c0);
float4 Toggles : register(c1);  // x: fog fades to black (premultiplied), y: fog fades to white (additive)
float4 FogColor : register(c2);

#ifdef TEX
sampler2D DiffuseMap : register(s0);
#endif

struct PS_INPUT {
    float4 uv : TEXCOORD0;             // xy: texture, z: alpha scale, w: fog
#ifdef VC
    float4 color : COLOR0;
#endif
    float2 depthSize : TEXCOORD3;
    float2 screenPos : VPOS;
};

struct PS_OUTPUT {
    float4 color_0 : COLOR0;
};

PS_OUTPUT main(PS_INPUT IN) {
    PS_OUTPUT OUT;

#ifdef TEX
    float4 base = tex2D(DiffuseMap, IN.uv.xy);
#else
    float4 base = 1.0f;
#endif
#ifdef VC
    base *= IN.color;
#endif
    base *= MaterialColor;

    float alpha = base.a * IN.uv.z * SoftParticleFade(IN.screenPos, IN.depthSize);
    float fog = IN.uv.w;
#ifdef PREMULT_ALPHA
    OUT.color_0.rgb = base.rgb * (1.0f - fog) * alpha;
    OUT.color_0.a = 1.0f;
#else
    float3 fogged = lerp(base.rgb, FogColor.rgb, fog);
    float3 premultiplied = base.rgb * (1.0f - fog);
    float3 additive = lerp(base.rgb, 1.0f, saturate(fog * 1.5f));
    OUT.color_0.rgb = lerp(lerp(fogged, premultiplied, Toggles.x), additive, Toggles.y);
    OUT.color_0.a = alpha;
#endif
    return OUT;
}

#endif
