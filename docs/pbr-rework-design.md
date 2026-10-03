# PBR Rework: one lighting core, no compensating knobs

## Status

**Phase 1 in progress.** Review the decisions at the end and strike or change anything before
implementation begins.

## Decided: follow Community Shaders

*Supersedes the "one model for everything" core below where they differ.*

- **RMAOS follows OpenPBR** (Academy Software Foundation OpenPBR Surface, base substrate):
  - **R** `specular_roughness` (GGX, α = r²);
  - **G** `base_metalness`;
  - **B** ambient occlusion (a renderer term, not an OpenPBR parameter);
  - **A** `specular_weight`, default 1. This modulates the dielectric reflectivity of IOR 1.5
    (F0 0.04 at A = 1) through the spec's IOR modulation, and also scales the metal's Fresnel.

  Everything else is at the spec's defaults (`base_weight` 1, white `specular_color`, IOR 1.5,
  Lambertian base, no coat, fuzz, film, transmission or subsurface). The BRDF follows the spec:
  - **Dielectric Fresnel:** the exact Fresnel equations with the modulated IOR.
  - **Metal Fresnel:** `specular_weight` × Schlick(`base_color`). This is F82-tint at its default
    white edge tint.
  - **Diffuse:** albedo-scaled by (1 − E_dielectric(view)).
  - **Multiple scattering:** energy compensation on the specular lobes.

  Ambient occlusion keeps CS's multi-bounce AO and specular occlusion. **Community Shaders maps
  store F0 in A (≈0.04):** divide their alpha by 0.04 to use them here.
- **True PBR only for authored materials.** These are meshes whose diffuse texture has an
  `_rmaos` companion. They use Community Shaders' TruePBR maths exactly (`PBR.hlsli`,
  `PBRMath.hlsli`, `BRDF.hlsli`):
  - **Highlights:** GGX D, Smith joint visibility (Heitz approximation), Schlick F.
  - **Diffuse:** Lambert × (1 − F). (CS's 1/π is folded into NVR's light units, so a white
    surface lit head-on still returns the light.)
  - **Metal:** F0 = lerp(rmaos.a, albedo, metalness), with the diffuse albedo scaled by
    (1 − metalness).
  - **Ambient:** diffuse is irradiance × albedo × (1 − the specular lobe weight) ×
    multi-bounce AO; specular is environment × (F0·A + B) from Lazarov's EnvBRDF approximation
    × specular occlusion.
  - **Environment:** the sky outdoors, the room's ambient light indoors.
- **Everything else keeps vanilla shading, in linear space:**
  - Lambert diffuse;
  - vanilla's Blinn-Phong highlight (mask × N·H^shine), only on meshes the game flags as
    specular;
  - vanilla ambient (plus NVR's sky ambient, the equivalent of CS's Skylighting feature);
  - no sky reflections, no added highlights.
- **Removed:** VanillaMatchedHighlights, SpecularOnAll, DefaultRoughness, SkyReflectionScale,
  MaxSpecular, MaxSkyReflection, AmbientNormalDetail, SpecularOcclusion, Saturation.
- **The `_rmaos` texture slot moves into phase 1,** since nothing reaches the PBR path without it.

## Why

The object lighting grew in three layers, now tangled together:

1. **A physically based core:** GGX, linear lighting, sky light and reflections.
2. **Knobs that fight FNV's non-PBR assets:**
   - VanillaMatchedHighlights;
   - SpecularOnAll / DefaultRoughness;
   - SkyReflectionScale;
   - MaxSpecular / MaxSkyReflection;
   - Saturation;
   - AmbientNormalDetail.

   Each patched a symptom of the one before. The wet-looking road was VanillaMatched,
   SkyReflectionScale 5 and a glossy mask stacking up.
3. **Fixes for the engine's multi-pass pipeline:**
   - merged light passes;
   - texture compensation in light-only passes;
   - the FaceGen interior pass patch.

Layer 3 is necessary and stays, as internal machinery with no settings. Layer 2 goes. Layer 1 is
rewritten once, as a single shared library instead of copies spread across the object,
parallax, terrain and skin shaders.

## The lighting core (`Includes/Lighting.hlsl`, new)

All lit NVR shaders call this. Nothing in it is FNV-specific.

**Surface inputs** (built by each shader's material adapter):

| Field | Meaning |
|---|---|
| `albedo` | linear base colour |
| `normal` | shading normal, world space |
| `roughness` | perceptual roughness, 0.04–1 |
| `specular` | specular intensity, scaling F0: 1 means F0 0.04 |
| `metalness` | 0 everywhere for now; the hook for the deferred metallic map work (see `derived-metallicness.md`) |
| `occlusion` | ambient and specular occlusion, 1 if none |

**BRDF:**
- Lambert diffuse.
- GGX specular with height-correlated Smith visibility and Schlick Fresnel.
- F0 = lerp(0.04 × specular, albedo, metalness).
- Diffuse scaled by (1 − F) × (1 − metalness), so diffuse and specular together never exceed
  the light that arrives.

**Lights:**
- **Sun:** a disc (Karis' representative point plus normalisation, as now) × NVR's shadow
  visibility.
- **Point lights:** vanilla's 1 − d²/r² falloff. Lamp radii and brightness were authored for it;
  physical inverse-square would relight every interior.
- **Ambient:**
  - diffuse from the weather ambient plus the spherical-harmonic sky;
  - specular from the split-sum sky reflection (EnvBRDF approximation);
  - the reflected share is taken out of the diffuse ambient (the current skyReflectedFraction
    idea, kept).
  - Interiors: no sky term. Nothing occludes it, so indoors it would light rooms from a sky they
    can't see.
- **Horizon / specular occlusion:** reflections fade where the normal map tilts them below the
  geometric surface. Kept as physics, not a setting.

**Space:** linear lighting is always on. Albedo and light colours are decoded on input and the
result is encoded once. Gamma mode and its fallback paths are removed.

**World normal:** the vertex shaders send the world tangent frame wherever interpolators allow;
the merged-light work already does this for the light-only passes. That replaces the
AmbientNormalDetail approximation, which only had "world up" to work with.

## Material adapters (per shader family)

These turn FNV's data into surface inputs. This is the only place FNV conventions live.

| Family | albedo | roughness | specular |
|---|---|---|---|
| Objects (flagged specular) | diffuse texture | from the mesh glossiness (shine → roughness, as now) | normal map alpha mask × 2 (a 50% mask reads as plain dielectric) |
| Objects (unflagged) | diffuse texture | one fixed value (0.6) | 0.5: every real dielectric reflects; no mask data to use |
| Parallax | at the parallax offset | as objects | as objects |
| Terrain | layer blend | per-layer glossiness | per-layer specular |
| Hair | as now (hair keeps its own specular model) | | |
| Skin | (separate skin layer, below) | | |

The ×2 and the fixed values are constants in the adapter, not settings.

## Metallic and authored material maps

A metal has no diffuse term: light that enters is absorbed at once, so all its colour comes from
its reflection, tinted by the metal (F0 = albedo). Today every surface is treated as non-metal,
which is why bare metal reads as grey plastic. FNV ships no metal data, so the material
adapter gets metalness (and, optionally, authored roughness and occlusion) from three sources,
in priority order.

**1. Authored maps: a new texture slot, by naming convention.**
- **The file:** a material gets authored PBR data if a texture named after its diffuse texture
  with an `_rmaos` suffix exists, e.g. `armor/leather01.dds` → `armor/leather01_rmaos.dds`.
  Loose files and BSAs both count.
- **The channels**, Community Shaders' layout for Skyrim, so existing tools and authoring
  habits carry over:
  - R roughness;
  - G metalness;
  - B ambient occlusion;
  - A specular (F0 scale).
- **No NIF editing:** authors only add the file.
- **How NVR finds it:** the per-geometry hooks (ShadowLightShader, ParallaxShader, HairShader)
  read the material's diffuse texture path (`NiSourceTexture::ddsPath1`, through
  `BSShaderPPLightingProperty::ppTextures[0][0]`) and look up the companion once per texture,
  through the engine's own file system and texture loader (entry points to be traced in IDA),
  so BSAs work.
- **Caching:** a texture that has no companion is remembered as such, so the lookup is never
  repeated.
- **Binding:** the companion goes to a free sampler for the draw, and a per-draw constant tells
  the shader it is present.
- **Loading cost:** a missing companion costs one cached lookup. Loading happens the first time
  a texture is seen, and can move to the engine's background loader if it stutters.
- **Overrides:** an authored map replaces the adapter's roughness, specular and occlusion as
  well as its metalness. A fully authored material ignores FNV's glossiness and mask.

**2. Derived metalness** (`derived-metallicness.md`), for every asset without an authored map: a
strong specular mask on a low-saturation colour usually means metal (weapons, armour plates,
cans, casings). One `MetallicStrength` setting (0 off) plus a debug view showing the derived mask,
for tuning against false positives (glossy ceramic, lacquered wood, painted signs).

**3. Metalness 0** when both are off.

**Indoor reflections:** metals are only as bright as what they reflect. Outdoors that's the sky;
indoors there is currently nothing (the sky reflection is off and there are no reflection
probes), so metals would go nearly black. The core therefore reflects the room's ambient light
as a uniform environment indoors. This is physically the right answer for a surface lit evenly
from all sides, and it gives non-metals back the ambient sheen they currently lose indoors.

## Skin

The skin shader keeps its own diffusion (spherical-Gaussian scattering, screen-space blur,
transmission), but takes its specular, sky reflection and light handling from the core, instead
of borrowing PBR.hlsl pieces and PBR settings piecemeal as now. That also makes "skin with PBR
off" a non-question: the core belongs to every lit shader, not to a PBR toggle.

## Settings

**Before → after, `[Shaders.PBR.*]`:**

| Current | After |
|---|---|
| LinearLighting | removed (always on) |
| SpecularStrength | kept: global specular intensity |
| RoughnessScale | kept: global roughness multiplier (rain lowers it) |
| LightingScale | kept: direct light strength |
| AmbientScale, SkylightingScale | merged into one `AmbientStrength` |
| SkyReflectionScale | removed (physically fixed; SpecularStrength covers taste) |
| VanillaMatchedHighlights | removed |
| SpecularOnAll, DefaultRoughness | removed (built in) |
| MaxSpecular, MaxSkyReflection | removed (no boosts left to clamp) |
| Saturation | removed (grading belongs to the LUT/tonemapper) |
| AmbientNormalDetail | removed (real world normal) |
| SpecularOcclusion | removed (always on) |
| MergeLightPasses | removed (always on; internal) |
| DebugView | kept (adds metalness and authored-map views) |
| (new) MetallicStrength | strength of derived metalness, 0 off; authored maps are unaffected |

**Profiles:** Main/Night/Rain/NightRain/Interiors keep only the surviving four values
(SpecularStrength, RoughnessScale, LightingScale, AmbientStrength). Terrain gets the same four.

**Migration:** removed keys are ignored if found in a user's settings file (no errors). The
four surviving values keep their current numbers.

## What stays as internal machinery

- **Merged light passes:** lamps, and highlights from extra passes, lit in the first pass.
  Required while the engine splits lighting across passes and the frame is gamma-encoded.
- **Texture compensation** in light-only passes, and FaceGen colour for faces.
- **The FaceGen interior pass patch.**
- **Per-draw ObjectMaterial** (specular flag, highlight distance fade).

## Expected look change

- Matte surfaces: unchanged.
- Flagged-shiny assets (metal, glossy props, roads with strong masks): dimmer than now. Vanilla
  matching was multiplying them up to 12×. SpecularStrength is the single knob to bring shine
  back to taste.
- Glancing-angle sheen: physically sized. No more mirror roads.
- Faces and bodies: lit by the same rules as their surroundings, so they match.

## Implementation phases

1. **Core + objects + parallax:**
   - write `Lighting.hlsl`, with the metalness input and indoor ambient reflection;
   - rewrite the object and parallax templates onto it;
   - remove the layer-2 settings for objects;
   - verify every variant with the runtime-compiler test (`d3dx9_43` with the user's defines),
     plus register headroom.
2. **Metallic:**
   - the `_rmaos` texture slot: lookup, caching, binding, and engine loader entry points traced
     in IDA;
   - then derived metalness with its setting and debug view.
3. **Terrain** onto the core; its settings reduced to the same four.
4. **Skin** specular and ambient onto the core. Diffusion unchanged.
5. **Clean-up:** delete the old helpers, rewrite the defaults-file descriptions, update the
   debug views.

Each phase is installed and tested in game before the next starts.

## Decisions for you

Strike or change any of these:

1. Remove VanillaMatchedHighlights entirely (shiny assets get dimmer; SpecularStrength
   compensates).
2. Remove SkyReflectionScale, MaxSpecular and MaxSkyReflection.
3. Remove Saturation from lighting (use the LUTs).
4. Linear lighting always on (no gamma mode).
5. Unflagged meshes always get a dull dielectric highlight (no SpecularOnAll toggle).
6. Merge AmbientScale and SkylightingScale into one AmbientStrength.
7. Keep vanilla's point-light falloff rather than inverse-square.
8. Skin specular moves onto the core (same highlight model as everything else).
9. Authored maps by the `_rmaos` naming convention, Community Shaders' channel layout (R
   roughness, G metal, B AO, A specular).
10. Derived metalness for assets without an authored map, behind `MetallicStrength`.
11. Indoor ambient reflection (the room's ambient light as a uniform environment).

## Dynamic cubemaps (what authored materials reflect)

A port of Community Shaders' Dynamic Cubemaps to D3D9 pixel shaders (`src/effects/DynamicCubemaps.*`,
`Effects/DynamicCubemaps.fx.hlsl`), run on the scene as drawn at the start of
`RenderEffectsPreTonemapping`:

- Capture: each texel of a 128 px FP16 cube looks up its direction on screen (depth > 24 units, not the
  view model) and blends the linear colour 50/50 over last frame's (two cubes, ping-ponged). Stored
  premultiplied by coverage; off-screen texels keep their colour while their coverage decays 0.5% a frame.
- Infer: unseen texels walk the capture's mips until covered, then take the sky SH outdoors, or the room's
  average (else the ambient colour) indoors.
- Prefilter: GGX importance sampling (16 Hammersley samples, mip-filtered), roughness = mip / 7, 8 mips.
- Objects sample it at `roughness * 7` along R (s11, `MaterialMap.y`), bound per draw for authored
  materials only; it replaces the sky SH reflection outdoors and the flat-ambient reflection indoors.
- The vanilla env map passes (0x244-0x24A) are muted on authored materials, so nothing reflects twice.
- Reset on interior/exterior change or a camera jump over 1500 units. One frame of latency.
- `[Shaders.PBR.Main] DebugView = 5` shows the cube along the normal.
