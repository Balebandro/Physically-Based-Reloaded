// Erosion relief on distant terrain ([Shaders.Terrain.Erosion], core/TerrainErosion.cpp): the badlands look of gullies
// branching down every slope, which the LOD meshes and normal maps are far too coarse to hold.
//
// Over the slope the LOD normal map gives, layers of ripples whose crests run downhill (jittered points in cells, so no
// regular stripes); each finer layer follows the slope the coarser ones left, so small gullies branch off the flanks of
// larger ones. Steep land erodes, flat land stays smooth. Layers finer than a few pixels fade out (no shimmer far off).
// Only the lighting changes (the normal, and darker gully floors), not the LOD mesh's outline.
//
// Registers: c180-c181 are free in the terrain shaders (Terrain.hlsl c89/c90/c134/c135, Shadow.hlsl c100-c133,
// SkyAmbient.hlsl c137-c145).

float4 TESR_CameraPosition : register(c180);
float4 TESR_TerrainErosionData : register(c181);	// x gully depth (0 off), y widest gully spacing (units), z gully floor darkening

// A hash without sin (after Dave Hoskins' hash22, MIT): steady for the large cell numbers of world positions.
float2 ErosionHash(float2 p) {
    float3 p3 = frac(p.xyx * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yzx + 33.33f);
    return frac((p3.xx + p3.yz) * p3.zy);
}

// One layer of gullies Spacing apart, their crests along Slope: the height (-1..1) in z, its rise per unit in xy.
float3 ErosionLayer(float2 position, float2 slope, float spacing) {
    float2 down = slope / max(length(slope), 1e-5f);
    float2 across = float2(-down.y, down.x);
    float2 cellPosition = position / spacing;
    float2 cell = floor(cellPosition);
    float2 inCell = cellPosition - cell;
    float height = 0.0f;
    float2 gradient = 0.0f;
    float weights = 0.0f;
    [unroll] for (int y = -1; y <= 1; y++) {
        [unroll] for (int x = -1; x <= 1; x++) {
            float2 offset = float2(x, y);
            float2 toPoint = inCell - offset - ErosionHash(cell + offset);
            float weight = exp(-2.0f * dot(toPoint, toPoint));
            float phase = 6.2831853f * dot(toPoint, across);
            height += cos(phase) * weight;
            gradient -= sin(phase) * 6.2831853f * across * weight;
            weights += weight;
        }
    }
    return float3(gradient / (weights * spacing), height / weights);
}

// The land's normal carved with gullies, from its world normal (z up) at a camera-relative position whose pixel covers
// Footprint units; Cavity how deep in a gully the point lies (0 on crests, 1 on gully floors).
float3 GetErodedNormal(float3 normal, float3 position, float footprint, out float cavity) {
    float2 slope = -normal.xy / max(normal.z, 0.1f);   // rise per unit, from the normal
    // In world units: the pattern stays on the land as the camera moves.
    float2 anchored = position.xy + TESR_CameraPosition.xy;
    float steepness = saturate(length(slope) * 2.5f);

    float2 gradient = slope;
    float depth = 0.0f;
    float total = 0.0f;
    float layerSpacing = TESR_TerrainErosionData.y;
    float amplitude = TESR_TerrainErosionData.x * 0.12f * layerSpacing;
    [loop] for (int i = 0; i < 4; i++) {
        float fade = saturate(layerSpacing / (4.0f * footprint) - 1.0f);
        [branch] if (fade <= 0.0f) break;
        float3 layer = ErosionLayer(anchored, gradient, layerSpacing);
        float weight = amplitude * fade * steepness;
        gradient += layer.xy * weight;
        depth += layer.z * weight;
        total += weight;
        layerSpacing *= 0.5f;
        amplitude *= 0.5f;
    }
    cavity = total > 0.0f ? saturate(-depth / total) : 0.0f;
    return normalize(float3(-gradient.x, -gradient.y, 1.0f));
}
