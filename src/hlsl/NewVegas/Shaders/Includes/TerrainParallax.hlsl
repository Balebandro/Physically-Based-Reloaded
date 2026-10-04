// Terrain parallax occlusion mapping, height blending and parallax self-shadowing.
//
// Replaces the TERRAIN path of Parallax.hlsl, which looked up the height of every layer of the
// chunk at every step of the march and then marched a second time to refine: up to 32 lookups
// of up to 7 textures each, plus 5 more for the shadows, on most of the screen.
//
// What the engine guarantees shapes the rewrite (BSShaderPPLightingProperty::AddLandscapePasses_2x):
// a land chunk is drawn in ONE pass with up to 7 layers, and the shader variant is picked by its
// exact layer count, so TEX_COUNT is known at compile time. Each layer's weight is interpolated
// per vertex (blend_0, blend_1), so most pixels draw on one to three layers, and the march only
// needs the ones that dominate the height:
//
//   - The march samples the two strongest layers that have a height map, at most two texture
//     reads per lookup.
//   - It takes about one step per pixel the parallax can actually shift the texture by, so
//     distant or grazing ground that would shift by under half a pixel is skipped outright.
//   - One linear march with an early exit and one secant refinement, not a second march.
//   - The height-blend weights come from the same reads that fetch the colour.
//
// Same displacement convention, height-blend formula and settings as before, so it should look
// the same. ps_3_0 cannot index a sampler array at runtime, so "the strongest layers" are kept as
// a weight array with every other entry zero, and each layer's read sits behind a real branch.
//
// LandHeight (c34/c35) says per layer whether its diffuse alpha holds a height map; Vanilla Plus
// Terrain fills it. A layer without one takes no part in the march.

float4 TESR_TerrainParallaxData : register(c91);      // x: enabled, y: shadows, z: height blend, w: high quality
float4 TESR_TerrainParallaxExtraData : register(c92); // x: max distance, y: height, z: shadows intensity

// The two strongest layers that carry a height map, renormalised. All zero when none do.
void pickHeightLayers(float blends[7], float status[7], out float active[7]) {
    float best1 = 0.0f, best2 = 0.0f;
    float index1 = -1.0f, index2 = -1.0f;
    [unroll] for (int i = 0; i < TEX_COUNT; i++) {
        float w = status[i] ? blends[i] : 0.0f;
        bool first = w > best1;
        bool second = !first && w > best2;
        best2 = first ? best1 : (second ? w : best2);
        index2 = first ? index1 : (second ? (float)i : index2);
        best1 = first ? w : best1;
        index1 = first ? (float)i : index1;
    }

    float total = best1 + best2;
    float norm = total > 0.0f ? rcp(total) : 0.0f;
    [unroll] for (int j = 0; j < 7; j++) {
        active[j] = (j == index1) ? best1 * norm : ((j == index2) ? best2 * norm : 0.0f);
    }
}

// Height from the picked layers only. Explicit gradients: these reads sit in dynamic flow.
float sampleTerrainHeight(float2 uv, float2 dx, float2 dy, sampler2D tex[7], float active[7]) {
    float height = 0.0f;
    [unroll] for (int i = 0; i < TEX_COUNT; i++) {
        [branch] if (active[i] > 0.0f)
            height += active[i] * tex2Dgrad(tex[i], uv, dx, dy).a;
    }
    return height;
}

float terrainParallaxDistanceBlend(float distance) {
    return saturate(distance / TESR_TerrainParallaxExtraData.x);
}

// Parallax offset UV. viewDirTS is the tangent-space direction to the eye.
float2 getTerrainParallaxCoords(float distance, float2 coords, float2 dx, float2 dy, float3 viewDirTS, sampler2D tex[7], float active[7]) {
    float distanceBlend = terrainParallaxDistanceBlend(distance);
    if (!TESR_TerrainParallaxData.x || distanceBlend >= 1.0f || active[0] + active[1] + active[2] + active[3] + active[4] + active[5] + active[6] <= 0.0f)
        return coords;

    float maxHeight = TESR_TerrainParallaxExtraData.y;
    float minHeight = maxHeight * 0.5f;

    // Same angle correction as before.
    viewDirTS = normalize(viewDirTS);
    viewDirTS.z = viewDirTS.z * 0.7f + 0.3f;
    float2 shift = viewDirTS.xy / viewDirTS.z * maxHeight;   // full displacement across the height range, in UV

    // How many pixels that displacement spans on screen. Under half a pixel there is nothing to
    // see; otherwise one step per pixel, at least 4, at most the quality cap.
    float uvPerPixel = max(max(length(dx), length(dy)), 1e-6f);
    float shiftPixels = length(shift) / uvPerPixel * (1.0f - distanceBlend);
    if (shiftPixels < 0.5f)
        return coords;
    float maxSteps = TESR_TerrainParallaxData.w ? 16.0f : 8.0f;
    float numSteps = clamp(ceil(shiftPixels), 4.0f, maxSteps);
    float stepSize = rcp(numSteps);

    // March from the top of the height range down. At depth t the ray is at
    // coords + shift * (0.5 - t) and the surface is hit once height >= 1 - t.
    float2 start = coords + shift * 0.5f;
    float prevT = 0.0f;
    float prevDiff = sampleTerrainHeight(start, dx, dy, tex, active) - 1.0f;
    float hitT = 1.0f;
    float hitDiff = 0.0f;
    bool found = prevDiff >= 0.0f;
    if (found) { hitT = 0.0f; hitDiff = prevDiff; }

    [loop] for (float s = 1.0f; s <= numSteps && !found; s += 1.0f) {
        float t = s * stepSize;
        float diff = sampleTerrainHeight(start - shift * t, dx, dy, tex, active) - (1.0f - t);
        if (diff >= 0.0f) {
            found = true;
            hitT = t;
            hitDiff = diff;
        }
        else {
            prevT = t;
            prevDiff = diff;
        }
    }

    // Secant between the last miss and the hit, then one refinement sample at that guess.
    float t = hitT;
    if (found && hitT > 0.0f) {
        t = lerp(prevT, hitT, saturate(prevDiff / (prevDiff - hitDiff)));
        float diff = sampleTerrainHeight(start - shift * t, dx, dy, tex, active) - (1.0f - t);
        if (diff >= 0.0f) { hitT = t; hitDiff = diff; }
        else { prevT = t; prevDiff = diff; }
        t = lerp(prevT, hitT, saturate(prevDiff / (prevDiff - hitDiff)));
    }

    float2 parallaxUV = start - shift * t;
    return lerp(parallaxUV, coords, distanceBlend * distanceBlend);
}

// Diffuse colour and the final layer weights in one go. Height blending sharpens the blend toward
// whichever layer stands taller at this pixel; the heights come from the same reads as the colour.
float3 blendTerrainDiffuse(float3 vertexColor, float2 uv, float2 dx, float2 dy, sampler2D tex[7], float blends[7], float status[7], float distance, out float weights[7]) {
    float blendFactor = TESR_TerrainParallaxData.x ? (TESR_TerrainParallaxData.z ? 1.0f - terrainParallaxDistanceBlend(distance) : 0.25f) : 0.0f;
    float blendPower = blendFactor * 4.0f;

    float3 color = 0.0f;
    float total = 0.0f;
    [unroll] for (int i = 0; i < TEX_COUNT; i++) {
        weights[i] = 0.0f;
        [branch] if (blends[i] > 0.0f) {
            float4 texel = tex2Dgrad(tex[i], uv, dx, dy);
            float height = status[i] ? texel.a : 0.5f;
            float w = pow(max(blends[i], 0.0f), 1.0f + blendFactor) * (blendPower > 0.0f ? 0.001f + pow(max(height, 0.0001f), blendPower) : 1.0f);
            weights[i] = w;
            color += texel.rgb * w;
            total += w;
        }
    }
    [unroll] for (int k = TEX_COUNT; k < 7; k++) weights[k] = 0.0f;

    float norm = total > 0.0f ? rcp(total) : 0.0f;
    [unroll] for (int j = 0; j < TEX_COUNT; j++) weights[j] *= norm;
    return color * norm * vertexColor;
}

// Normal, gloss and specular exponent from the final weights, skipping layers that carry none.
float3 blendTerrainNormals(float2 uv, float2 dx, float2 dy, sampler2D tex[7], float weights[7], float spec[7], out float gloss, out float specExponent) {
    gloss = 0.0f;
    specExponent = 0.0f;
    float3 blendedNormal = 0.0f;
    [unroll] for (int i = 0; i < TEX_COUNT; i++) {
        [branch] if (weights[i] > 0.0f) {
            float4 normal = tex2Dgrad(tex[i], uv, dx, dy);
            blendedNormal += normal.xyz * weights[i];
            gloss += normal.w * weights[i] * (spec[i] > 0 ? 1.0f : 0.0f);
            specExponent += spec[i] * weights[i];
        }
    }
    gloss = saturate(gloss);
    return normalize(expand(blendedNormal));
}

// Height-based self-shadowing toward the sun, from the picked layers. Its own switch
// ([Shaders.Terrain.Parallax] Shadows, TESR_TerrainParallaxData.y): it works with parallax itself
// off too, on the flat (unshifted) texture coordinates.
float getTerrainParallaxShadow(float distance, float2 coords, float2 dx, float2 dy, float3 lightTS, sampler2D tex[7], float active[7]) {
    float quality = 1.0f - distance / TESR_TerrainParallaxExtraData.x;
    if (!TESR_TerrainParallaxData.y || quality <= 0.0f || active[0] + active[1] + active[2] + active[3] + active[4] + active[5] + active[6] <= 0.0f)
        return 1.0f;

    // The old version summed four samples at 1, 1/2, 1/3 and 1/4 of the ray; two at 1/2 and 1/4
    // carry most of it near the surface, doubled to keep the same strength.
    float2 rayDir = lightTS.xy * 0.1f;
    float h0 = sampleTerrainHeight(coords, dx, dy, tex, active);
    float h1 = sampleTerrainHeight(coords + rayDir * 0.5f, dx, dy, tex, active);
    float h2 = sampleTerrainHeight(coords + rayDir * 0.25f, dx, dy, tex, active);
    float occlusion = (max(0.0f, h1 - h0) + max(0.0f, h2 - h0)) * 2.0f;

    return 1.0f - saturate(occlusion * TESR_TerrainParallaxExtraData.z) * quality;
}
