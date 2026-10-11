// Shader to blend cloud layers from weathers transitions with the sky
//
// Parameters:

float2 Params : register(c4);
float ObjectID : register(c20);  // Set by hook. 0 == sun, 6 == moon.
sampler2D TexMap : register(s0);
sampler2D TexMapBlend : register(s1);

float4 TESR_SunColor : register(c6);
float4 TESR_SkyColor : register(c7);
float4 TESR_SkyLowColor : register(c8);
float4 TESR_HorizonColor : register(c9);
float4 TESR_SunDirection : register(c10);
float4 TESR_SkyData : register(c11);   // x:AthmosphereThickness y:SunInfluence z:SunStrength w:StarStrength
float4 TESR_CloudData : register(c12); // x:UseNormals y:SphericalNormals z:Transparency w: cloud Brightness
float4 TESR_SunAmount : register(c13); // x:isDayTime, w:GlareStrength
float4 TESR_SunPosition : register(c14);
float4 TESR_SunsetColor : register(c15);
float4 TESR_HDRBloomData : register(c16);
float4 TESR_SunDiskColor : register(c17);
float4 TESR_CloudVolumeData : register(c18);   // x:Volumetric y:Steps z:CloudHeight w:CloudThickness
float4 TESR_CloudVolumeData2 : register(c19);  // x:Density y:Absorption z:DetailScale w:UVScale (per game unit)
float4 TESR_CloudVolumeLight : register(c21);  // x:Scattering (g) y:SilverLining z:AmbientStrength w:DetailSpeed
float4 TESR_GameTime : register(c22);          // z: running time in seconds


// Registers:
//
//   Name         Reg   Size
//   ------------ ----- ----
//   Params       const_4       1
//   TexMap       texture_0       1
//   TexMapBlend  texture_1       1
//   TESR_CloudVolumeData   const_18       1
//   TESR_CloudVolumeData2  const_19       1
//   TESR_CloudVolumeLight  const_21       1
//   TESR_GameTime          const_22       1
//


static const float UseNormals = TESR_CloudData.x;
static const float SphericalNormals = 1;//TESR_CloudData.y;
static const float SUNINFLUENCE = 1/TESR_SkyData.y;
static const float SunStrength = TESR_SkyData.z;
static const float SkyMultiplier = TESR_SunsetColor.w;

// Structures:

struct VS_INPUT {
    float2 TexUV : TEXCOORD0;
    float2 position: VPOS;
    float2 TexBlendUV : TEXCOORD1;
    float3 location: TEXCOORD2;
    float4 color_0 : COLOR0;
    float4 color_1 : COLOR1;
};

struct VS_OUTPUT {
    float4 color_0 : COLOR0; // sunglare active region/suncolor
};


struct SunValues {
    float athmosphere;
    float sunHeight;
    float sunInfluence;
    float3 sunColor;
    float3 sunDir;
    float isDayTime;
};

// Code:
#include "Includes/Helpers.hlsl"
#include "Includes/Sky.hlsl"

static const float3 up = blue.xyz;

float3 getNormal(float2 partial, float3 eyeDir){

    // if spherical normals are not activated, we must convert the normals pointing up
    if (!SphericalNormals){
        float2 dir = normalize(eyeDir.xy);
        float2x2 R = {{dir.x, dir.y}, { dir.y, -dir.x}};
        partial = compress(mul(expand(partial.xy), R));
        partial.y = 1 - partial.y;
    }

    partial = expand(partial);

    // reconstruct Z component
    float z = sqrt(1 - saturate(dot(partial, partial)));
    float3 normal = normalize(float3(partial, z));

    // get TBN matrix by getting the plane perpendicular to the eye direction
    // http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-13-normal-mapping/
    float3 N = eyeDir;
    float3 T = float3(N.y, -N.x, 0);  // horizontal X axis. Maybe we could rotate it to get spherical normals?
    float3 B = cross(T, N);
    // float3 B = cross(N, T);

    float3x3 TBN = {T, B, N};
    return normalize(mul(normal, TBN));
}


/*
* Shades the sun, moon and sunglare textures
*/
float4 ShadeSun(SunValues Sun, float4 texColor, float4 vertexColor){
    Sun.isDayTime = smoothstep(0.498, 0.502, TESR_SunAmount.x); // very short transition time to get mostly a value about wether the sun is up or not

    bool isSun = ObjectID == 0.0f;
    bool isMoon = ObjectID == 6.0f;

    if (isSun){
        float isSunset = smoothstep(0.3, 0.0, Sun.sunHeight);
        texColor.rgb += isSunset * Sun.sunColor;
        texColor.rgb += Sun.sunColor * TESR_SunAmount.w;
        texColor.a *= Sun.isDayTime; // force alpha 1 for sun disk in the daytime
    }else{
        texColor.rgb *= vertexColor.rgb * Params.y * lerp(TESR_SunAmount.w, 1, isMoon); // vertex color (animated by the engine)
        texColor.a *= vertexColor.a;
    }

    return delinearize(texColor);
}


/*
* Shades the cloud textures
*/
float4 ShadeClouds(float4 finalColor, float4 vertexColor, float3 skyColor, SunValues Sun, float3 eyeDir){
    // shade clouds 
    float greyScale = lerp(luma(finalColor), 1.0, saturate(TESR_CloudData.w));
    float alpha = finalColor.w * TESR_CloudData.z;

    // calculate sky color to blend in the clouds
    float3 scattering = pows(Sun.sunInfluence, 20) * smoothstep(0.5, 1, 1.0 - alpha) * Sun.sunColor;
    float sunDir = Sun.sunDir;
    float3 baseSkyColor = linearize(TESR_SkyColor).rgb;

    if (!UseNormals){
        // simply tint the clouds
        greyScale = (greyScale - 0.5) * 1.5 + 0.5; // tests for increasing cloud contrast before shading
        float3 cloudTint = lerp(pows(baseSkyColor * 0.5, 5.0), lerp(baseSkyColor, Sun.sunColor * 5, 0.7 * Sun.sunDir + 0.3), (1 - saturate(Sun.sunInfluence)) * greyScale).rgb;
        cloudTint = lerp(white.rgb, cloudTint * TESR_CloudData.w * 1.333, (1 - Sun.sunHeight) * Sun.isDayTime); // tint the clouds less when the sun is high in the sky and at night

        // finalColor.rgb *= lerp(1.0, cloudTint * TESR_CloudData.w * 1.333, isDayTime); // cancel tint at night
        finalColor.rgb *= cloudTint;
        finalColor.rgb += lerp(black.rgb, scattering * 4.0, (1 - Sun.sunHeight) * Sun.isDayTime);
    } else {
        // Tests for normals lit cloud
        float2 normal2D = finalColor.xy; // normal x and y are in red and green, blue is reconstructed
        float3 normal = getNormal(normal2D, -eyeDir); // reconstruct world normal from red and green

        greyScale = lerp(saturate(TESR_CloudData.w), 1.0f, finalColor.z); // greyscale is stored in blue channel
        float3 ambient = skyColor * greyScale * lerp(0.5, 0.7, Sun.sunDir); // fade ambient with sun direction
        float3 diffuse = compress(dot(normal, TESR_SunPosition.xyz)) * Sun.sunColor * (1.0 - luma(ambient)) * lerp(0.8, 1, Sun.sunDir); // scale diffuse if ambient is high
        float3 fresnel = pows(1.0 - shade(-eyeDir, normal), 4.0) * pows(saturate(expand(Sun.sunDir)), 2.0) * shade(normal, up) * (Sun.sunColor + skyColor) * 0.2;
        float3 bounce = shade(normal, -up) * pows(TESR_HorizonColor.rgb, 2.2) * 0.1 * Sun.sunHeight; // linearise, light from the ground bouncing up to the underside of clouds

        finalColor = float4(ambient + diffuse + fresnel + scattering + bounce, alpha);
        // finalColor.rgb = selectColor(TESR_DebugVar.x, finalColor, ambient, diffuse, fresnel, bounce, scattering, sunColor, skyColor, normal, float3(IN.TexUV, 1));
    }

    finalColor = float4(finalColor.rgb * vertexColor.rgb * Params.y, pows(saturate(finalColor.w * vertexColor.a), 1/TESR_CloudData.z)); // scale alpha with setting

    return delinearize(float4(finalColor.rgb * SkyMultiplier * TESR_CloudData.a, finalColor.a));
}


// ---- Volumetric clouds (TESR_CloudVolumeData.x = 1) -------------------------------------------
//
// The cloud layer becomes a slab CloudThickness deep, its base CloudHeight above the camera. Each
// cloud pixel marches the slab along its view direction, so the clouds gain depth and parallax as
// you look across them. The game's cloud textures stay the coverage source: their alpha, blended
// between weathers exactly as the flat path blends it, decides where cloud is.

// CLOUD_EXTINCTION is the optical depth, seen from the zenith, of a fully covered slab
// CLOUD_REF_THICKNESS thick. Absorption, Transparency and CloudThickness scale it from there.
static const float CLOUD_REF_THICKNESS = 2500.0;
static const float CLOUD_EXTINCTION = 3.0;
// Flat below CLOUD_HORIZON_LO (the sine of the view elevation), volumetric above CLOUD_HORIZON_HI,
// and the two blended in linear light between them, so there is no seam at the horizon.
static const float CLOUD_HORIZON_LO = 0.05;
static const float CLOUD_HORIZON_HI = 0.15;
// How far the procedural erosion may eat into the coverage (0 none, 1 everything).
static const float CLOUD_ERODE = 0.35;
// Scale of the sun's in-scatter. GetSunColor already doubles the sun colour at noon.
static const float CLOUD_SUN = 0.3;
// Direction the erosion noise drifts in. No wind constant is registered with the shaders.
static const float2 CLOUD_WIND = float2(0.6, 0.8);

// Hash without sine (Dave Hoskins), 0..1. Stays precise in ps_3_0 for the coordinates used here.
float CloudHash(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

// Value noise, 0..1: a smooth trilinear blend of hashed lattice corners.
float CloudNoise(float3 p) {
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float4 x0 = float4(CloudHash(i), CloudHash(i + float3(0.0, 1.0, 0.0)), CloudHash(i + float3(0.0, 0.0, 1.0)), CloudHash(i + float3(0.0, 1.0, 1.0)));
    float4 x1 = float4(CloudHash(i + float3(1.0, 0.0, 0.0)), CloudHash(i + float3(1.0, 1.0, 0.0)), CloudHash(i + float3(1.0, 0.0, 1.0)), CloudHash(i + float3(1.0, 1.0, 1.0)));
    float4 x = lerp(x0, x1, f.x);
    float2 y = lerp(x.xz, x.yw, f.y);
    return lerp(y.x, y.y, f.z);
}

// Two octaves of value noise for the erosion, 0..1 around 0.5.
float CloudDetail(float3 q) {
    float n = 0.0;
    float amp = 0.65;
    [unroll] for (int o = 0; o < 2; o++) {
        n += amp * CloudNoise(q);
        q = q * 2.03 + 17.1;
        amp = 0.35;
    }
    return saturate((n - 0.5) * 1.5 + 0.5);
}

// Vertical profile of the slab, h = 0 at its base and 1 at its top: rounded at both ends.
float CloudProfile(float h) {
    return smoothstep(0.0, 0.2, h) * (1.0 - smoothstep(0.6, 1.0, h));
}

// Henyey-Greenstein phase, 1 on average over the sphere. cosT is the dot product of the view
// direction and the direction to the sun, so +1 is looking into the sun, where g > 0 peaks.
float CloudPhase(float cosT, float g) {
    float g2 = g * g;
    return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosT, 0.01), 1.5);
}

// Cloud coverage from the game's textures: alpha, blended between the weathers as the flat path does.
float CloudCoverage(float2 uv, float2 uvBlend, float lod) {
    float a = tex2Dlod(TexMap, float4(uv, 0.0, lod)).a;
    float b = tex2Dlod(TexMapBlend, float4(uvBlend, 0.0, lod)).a;
    return lerp(a, b, Params.x);
}

/*
* Shades the cloud layer as a volume. flatColor is what ShadeClouds gives for this pixel and is
* returned unchanged where the sky is clear and below the horizon band. Elsewhere the result has the
* same form ShadeClouds returns (sRGB, colour not premultiplied, alpha for SRC_ALPHA blending) and
* takes the same vertex colour, Params.y, sky multiplier and brightness.
*/
float4 ShadeVolumetricClouds(float4 flatColor, float coverage, float2 uv, float2 uvBlend, float2 pixel, float4 vertexColor, float3 skyColor, SunValues Sun, float3 dir){
    float band = smoothstep(CLOUD_HORIZON_LO, CLOUD_HORIZON_HI, dir.z);
    if (band <= 0.0) return flatColor;

    float slabBase = TESR_CloudVolumeData.z;          // CloudHeight, game units above the camera
    float thickness = TESR_CloudVolumeData.w;         // CloudThickness, game units
    float steps = TESR_CloudVolumeData.y;             // Steps, 1-16
    float density = TESR_CloudVolumeData2.x;          // Density
    float absorption = TESR_CloudVolumeData2.y;       // Absorption
    float detailScale = TESR_CloudVolumeData2.z;      // erosion noise, cells per game unit
    float uvScale = TESR_CloudVolumeData2.w;          // texture units per game unit of horizontal travel
    float g = TESR_CloudVolumeLight.x;                // Scattering
    float silverLining = TESR_CloudVolumeLight.y;     // SilverLining
    float ambientStrength = TESR_CloudVolumeLight.z;  // AmbientStrength
    float detailSpeed = TESR_CloudVolumeLight.w;      // DetailSpeed, cells per second
    float transparency = TESR_CloudData.z;            // Transparency
    float brightness = TESR_CloudData.w;              // Brightness

    // Geometry. The camera is at the origin, so the point at height z on this ray is slope * z,
    // where slope = dir.xy / dir.z is the horizontal travel per unit of height.
    float2 slope = dir.xy / dir.z;
    float2 uvSlope = slope * uvScale;                 // texture travel per unit of height
    float3 slopeXYZ = float3(slope, 1.0);

    // Clear sky: no coverage at the entry or across the slab, read from the coarse mips.
    float midHeight = 0.5 * thickness;
    float coarse = max(CloudCoverage(uv, uvBlend, 4.0), CloudCoverage(uv + uvSlope * midHeight, uvBlend + uvSlope * midHeight, 4.0));
    if (coverage < 0.01 && coarse < 0.01) return flatColor;

    // Light. The sun ray is clamped to climb at least 0.15 per unit, so a low sun still gives a
    // finite light step. At night there is no sun term; the ambient carries the clouds.
    float3 sunDir = TESR_SunPosition.xyz;
    float sunZ = max(sunDir.z, 0.15);
    float2 lightUV = sunDir.xy / sunZ * uvScale * (0.35 * thickness);   // texture travel per light sample
    float cosT = dot(dir, sunDir);
    float sunOn = Sun.isDayTime;
    float3 sunLight = Sun.sunColor * (CLOUD_SUN * sunOn * CloudPhase(cosT, g));
    float facing = saturate(cosT);
    float backW = facing * facing;
    backW *= backW;                                   // looking into the sun: silver lining
    float frontW = saturate(-cosT);                   // the sun on the viewer's side: powder
    // Ambient: neutral by day, tinted toward the horizon by the sky as the flat path tints it, and
    // the flat path's full white at night.
    float ambientWhite = saturate(brightness) * lerp(1.0, 0.35, sunOn);
    float3 ambient = lerp(float3(ambientWhite, ambientWhite, ambientWhite), skyColor, (1.0 - Sun.sunHeight) * sunOn) * ambientStrength;

    // Extinction per unit of density along the view ray (a step is thickness / (steps * dir.z) long),
    // and toward the sun per light sample (0.35 thickness apart along the sun ray).
    float thicknessRatio = thickness / CLOUD_REF_THICKNESS;
    float viewExt = absorption * CLOUD_EXTINCTION * transparency * thicknessRatio / (steps * dir.z);
    float lightExt = absorption * CLOUD_EXTINCTION * transparency * density * thicknessRatio * 0.35 / sunZ;

    // March front to back, from the base of the slab to its top. The start offset is per pixel,
    // which turns the banding of the steps into noise.
    float jitter = CloudHash(float3(pixel, 0.5));
    float3 drift = float3(CLOUD_WIND * (TESR_GameTime.z * detailSpeed), 0.0);
    float3 inScatter = 0.0;
    float transmittance = 1.0;
    float stepI = 0.0;
    [loop] for (int k = 0; k < 16; k++) {
        if (stepI >= steps) break;

        float h = (stepI + jitter) / steps;           // 0 at the base, 1 at the top
        float zAbove = h * thickness;
        float2 uvK = uv + uvSlope * zAbove;           // texture uv of this point of the slab
        float2 uvBK = uvBlend + uvSlope * zAbove;

        // Density: coverage x vertical profile x Density, eroded by the detail noise where there is any
        float dens = CloudCoverage(uvK, uvBK, 0.0) * CloudProfile(h) * density;
        float shape = 0.0;
        if (dens > 0.001) {
            float n = CloudDetail(slopeXYZ * (slabBase + zAbove) * detailScale + drift);
            shape = saturate((dens - (1.0 - n) * CLOUD_ERODE) / (1.0 - CLOUD_ERODE));
        }

        // Sun: coverage and profile at two samples toward the sun. No detail noise, to keep it cheap.
        float lit = 0.0;
        [unroll] for (int j = 0; j < 2; j++) {
            float along = float(j + 1);
            lit += CloudCoverage(uvK + lightUV * along, uvBK + lightUV * along, 1.0) * CloudProfile(h + 0.35 * along);
        }
        float sunT = exp(-lightExt * lit);

        // In-scatter. Powder: thin cloud is darker with the sun on the viewer's side, and its thin
        // edges glow with the sun behind it (silver lining).
        float powder = 1.0 - exp(-2.0 * shape);
        float silver = 1.0 + silverLining * backW * (1.0 - powder);
        float3 S = sunLight * (sunT * silver * lerp(1.0, powder, frontW)) + ambient * (0.5 + 0.5 * h);

        // This step adds S, attenuated by the cloud in front of it
        float stepT = exp(-viewExt * shape);
        inScatter += transmittance * S * (1.0 - stepT);
        transmittance *= stepT;
        stepI += 1.0;
    }

    // Composite as ShadeClouds does. Transparency is already in the extinction, so the flat path's
    // final pow is not applied here.
    float opacity = 1.0 - transmittance;
    float3 colour = inScatter / max(opacity, 0.0001);
    float4 volume = float4(colour * vertexColor.rgb * Params.y * SkyMultiplier * brightness, opacity * vertexColor.a);

    // Across the horizon band the two are mixed in linear light, then encoded as ShadeClouds encodes.
    return delinearize(lerp(linearize(flatColor), volume, band));
}


VS_OUTPUT main(VS_INPUT IN) {
    VS_OUTPUT OUT;

    float4 color = IN.color_0;
    color = linearize(color);

    float3 eyeDir = normalize(IN.location);
    float verticality = pows(compress(dot(eyeDir, up)), 3);

    SunValues Sun;
    Sun.sunHeight = shade(TESR_SunPosition.xyz, up);
    Sun.sunDir = compress(dot(eyeDir, TESR_SunPosition.xyz)); // stores wether the camera is looking in the direction of the sun in range 0/1
    Sun.athmosphere = pows(1 - verticality, 8) * TESR_SkyData.x;
    Sun.sunInfluence = pows(Sun.sunDir, SUNINFLUENCE);
    Sun.isDayTime = smoothstep(0, 0.5, TESR_SunAmount.x);
    Sun.sunColor = GetSunColor(Sun.sunHeight, TESR_SkyData.x, TESR_SunAmount.x, TESR_SunColor.rgb, TESR_SunsetColor.rgb);

    float cloudsPower = Params.x;
    float4 cloudsWeather1 = linearize(tex2D(TexMap, IN.TexUV.xy));
    float4 cloudsWeather2 = linearize(tex2D(TexMapBlend, IN.TexBlendUV.xy));
    float4 cloudsWeatherBlend = lerp(cloudsWeather1, cloudsWeather2, cloudsPower); // weather transition

    float4 finalColor = (weight(cloudsWeather1.xyz) == 0.0 ? cloudsWeather2 : (weight(cloudsWeather2.xyz) == 0.0 ? cloudsWeather1 : cloudsWeatherBlend)); // select either weather or blend
    finalColor.a = cloudsWeatherBlend.a;
    
    if (IN.color_1.r){ // early out if this texture is sun/moon*
        OUT.color_0 = ShadeSun(Sun, finalColor, color);
        return OUT;
    } else {
        float3 skyColor = GetSkyColor(verticality, Sun.athmosphere, Sun.sunHeight, Sun.sunInfluence, TESR_SkyData.z, TESR_SkyColor.rgb, TESR_SkyLowColor.rgb, TESR_HorizonColor.rgb, Sun.sunColor);
        OUT.color_0 = ShadeClouds(finalColor, color, skyColor, Sun, eyeDir);
        // Volumetric = 0 leaves the flat result above exactly as it is
        if (TESR_CloudVolumeData.x > 0.5) OUT.color_0 = ShadeVolumetricClouds(OUT.color_0, finalColor.w, IN.TexUV, IN.TexBlendUV, IN.position, color, skyColor, Sun, eyeDir);
        return OUT;
    }
};
