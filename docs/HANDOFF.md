# Handoff: savings and findings from NVR Unofficial Optimized

Short notes from [adeesababa/NVR-Unofficial-Optimized](https://github.com/adeesababa/NVR-Unofficial-Optimized) (tag `p77`), in case any of it helps your build. Full details: [`docs/UNOFFICIAL-TECHNICAL.md`](https://github.com/adeesababa/NVR-Unofficial-Optimized/blob/p77/docs/UNOFFICIAL-TECHNICAL.md) and [`docs/OPTIMIZATION-ROADMAP.md`](https://github.com/adeesababa/NVR-Unofficial-Optimized/blob/p77/docs/OPTIMIZATION-ROADMAP.md) there.

All numbers were measured on one PC (GTX 1070, 2560x1440, native Direct3D 9) with the F10 GPU/CPU profiler in that build. Other hardware will differ.

## 1. Biggest savings, same image

| What | Change | Measured |
|---|---|---|
| Ambient occlusion | Half-res `G16R16F` ping-pong targets, both kernels in one pass, depth-aware 4-tap upsample | 2.3 -> 0.5 ms |
| God rays | Half-res targets, early exit in the radial march; the sky-mask pass returns black at once for non-sky pixels | 1.6 -> 0.5 ms |
| SMAA, contact shadows | Combined edge detection and explicit stencil state; contact shadows ping-pong through scratch targets (also removes a read/write feedback loop) | about 40-50% each |
| Effect chain copies | Two textures that swap roles instead of a whole-frame copy after every effect; the last effect writes the game's target directly; `SourceBuffer` refreshed only for effects that sample it | not measured separately (about one full-screen copy per enabled effect; commit 1 of this PR does the `SourceBuffer` part) |
| Volumetric fog | Half-res estimate stored as multiply/add coefficients in two MRTs, applied at full res; closed-form height-fog integral instead of a 32-step loop | not measured separately |
| Shadow + AO apply | Sun-shadow composite and AO combine done inside the fog reconstruct pass instead of two extra full-res passes | not measured separately (two full-res passes fewer) |
| Depth buffer | One `R32F` channel; the projected value is recomputed in the shaders | not measured separately (half the depth bytes read) |
| Interior point shadows | Blur on `G16R16` scratch targets, touching the HDR frame only once; cube-map read skipped beyond the light's radius; cube-map slots kept stable per light (swapping ranks forced both cubes to redraw); a light whose casters are all static keeps its cube map | static-light reuse: -0.13 to -0.17 ms GPU in one interior (1-2 of 11 lights qualified) |
| Shader constants (CPU) | Skip `SetPixel/VertexShaderConstantF` calls that set what the device already holds | indoors 88% of pixel-constant calls were redundant |
| Characters in lamp shadows (CPU) | Draw a skinned caster only into the cube faces its skeleton bounds reach, not all six | not measured separately; in crowd tests lamp shadow maps were the fastest-growing cost, about 0.1 ms per actor |

Opt-in, slightly lossy switches that were worth it:

| Switch | Measured |
|---|---|
| `ParallaxLite`: 8 steps plus one secant step instead of 16 plus refinement, 2 parallax-shadow taps on terrain | desert terrain 3.7 -> 2.6 ms; rocky terrain 6.2 -> 4.1 ms |
| `CheapUnderwaterTerrain`: no parallax below the water line | submerged terrain 51-78% cheaper |
| `CachedDistantShadows`: middle/far/LOD sun cascades on a slower schedule unless a character is in them | up to 1.2 ms GPU + 0.7 ms CPU where nobody is around |

## 2. Bugs worth knowing (they exist in upstream NVR too)

- **Actor sun shadows wrong or garbled.** Skinned vertex shaders kept `Shadow.hlsl`'s inverse projection/view at c100-c107, just past `Bones[54]` (c44-c97). The game's bone upload reaches further and overwrites them. Fix: pin them at c240/c244 in the skinned shaders (c180/c184 in GDECALS). Upstream PR: macrimmon12-tech/TESReloaded10#79.
- **Water reflections lose far buildings** (looking level or up). The clip plane is set before the pass binds shaders and must be re-issued after the bind. This is commit 2 of this PR.
- **OPT light passes use a different light order.** In passes `0xCA` (Setup_ADT4_Opt) and `0xD1` (Setup_ADTS10_Opt) the game writes pass light k to `PSLightColor[k-1]` (light 0, the directional light, is not in the shader); everywhere else light k is `PSLightColor[k]`. Anything per light in the object shaders must offset there. Also, only 4 PS light positions are uploaded, so in the `LIGHTS 9` variants lights 4 and 5 read stale registers.
- **`TESR_` samplers bind in declaration order, not by `register(sN)`.** Declaring them out of order silently swaps textures.
- **`AvgLuma` reads the 1x1 texture it renders to.** That's undefined in D3D9 and works by luck. A two-texture swap is the safe form.
- **Exposure flicker.** Adapt speeds of 50 caused pumping; 0.2 fixed it.
- **Contact shadows drew horizontal black lines** on sunlit surfaces. Fixed with an N.L fade and a distance-scaled bias.

## 3. Where the frame goes (what's worth optimizing)

- **Interiors are about the game's extra lighting passes.** In the Rivet City hangar these passes (diffuse point, specular, light passes) were about 5 ms of the 7 ms world scene. The game draws about 5 passes per object, and about half of the light-pass draws pass 0 pixels. The CPU was also busy: about 10 ms submitting about 5,500 draws.
- **Exteriors are GPU-bound.** Lit objects and terrain cost about 1.9 ms each; the water reflection map about 1.1 ms.
- **PBR's own cost is small:** about 9% of lit-object shading indoors, 4% of the frame.
- **DXVK** was about 35% slower than native D3D9 on this GTX 1070. Check that DXVK's `d3d9.dll` is the 32-bit one; a 64-bit one silently never loads.
- **`bForceMultiPass` is never read by the game.** The single-pass (OPT) lighting is chosen per object, in `GetRenderPasses_2x` 0x00BDF790, by lamp count (about 6 or fewer) and material flags.

## 4. Tried and rejected (measured slower or not worth it)

- Cached static plus live overlay cube maps (MIN-blended). Slower: the caster lists change order every frame and the static layers rebuilt anyway.
- Branching around unused light slots in the 4+ light shaders. Only 3-4% of slots were unused, and the branch cost more.
- A skip mask for the contact-shadow blur: bit-identical but slower.
- Folding exposure into the god-ray pass changes the image, because the luma pass reads the scene after god rays.
- Depth pre-pass for the world scene: too risky without control of the game's draw order.

Engine names and addresses come from WallSoGB's IDA database.
