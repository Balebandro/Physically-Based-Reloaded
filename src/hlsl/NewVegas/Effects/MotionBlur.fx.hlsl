// Motion Blur fullscreen shader for Oblivion/Skyrim Reloaded

#define BlurSamples 24

float4 TESR_ReciprocalResolution;
float4 TESR_MotionBlurParams;
float4 TESR_MotionBlurData;
float4 TESR_MotionBlurWeapon;		// mode 3: xy the weapon's centre, zw its move (aspect-scaled uv)
float4 TESR_MotionBlurWeaponSpin;	// mode 3: x scale change, y turn, z longest blur (fraction of the screen height)

sampler2D TESR_RenderedBuffer : register(s0) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = LINEAR; MINFILTER = LINEAR; MIPFILTER = LINEAR; };
// The first-person weapon's own depth: non-zero exactly on its pixels (as CombineDepth and TAA tell them apart).
sampler2D TESR_DepthBufferViewModel : register(s1) = sampler_state { ADDRESSU = CLAMP; ADDRESSV = CLAMP; MAGFILTER = POINT; MINFILTER = POINT; MIPFILTER = NONE; };

// TESR_MotionBlurParams.w, the mode (first person): 0 the whole screen, 1 the weapon (viewmodel) only, 2 all
// but the weapon, 3 the weapon along its own movement (WeaponMotionPS).
float IsViewModel(float2 uv) { return tex2Dlod(TESR_DepthBufferViewModel, float4(uv, 0.0f, 0.0f)).x > 0.0f ? 1.0f : 0.0f; }

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

// Mode 3: the weapon blurred along its own on-screen motion this frame, the world kept sharp. The motion is the
// field v = Move + [scale -turn; turn scale] (p - Center), p the uv with x scaled by the aspect ratio.
float4 WeaponMotionPS(float2 uv)
{
	float aspect = TESR_ReciprocalResolution.z;
	float2 p = float2(uv.x * aspect, uv.y) - TESR_MotionBlurWeapon.xy;
	float2 velocity = TESR_MotionBlurWeapon.zw + float2(TESR_MotionBlurWeaponSpin.x * p.x - TESR_MotionBlurWeaponSpin.y * p.y,
		TESR_MotionBlurWeaponSpin.y * p.x + TESR_MotionBlurWeaponSpin.x * p.y);
	float speed = length(velocity);
	float maxLength = TESR_MotionBlurWeaponSpin.z;
	if (speed > maxLength) velocity *= maxLength / speed;
	velocity.x /= aspect;

	float3 sharp = tex2D(TESR_RenderedBuffer, uv).rgb;
	[branch] if (dot(velocity, velocity) < 1e-10f) return float4(sharp, 1);

	// Samples spread evenly along the motion, centred on the pixel (the trail runs both ways, as a shutter
	// open across the frame would see it); only the weapon's own samples count.
	float3 weaponColor = 0;
	float weaponSum = 0, total = 0;
	for (int i = 0; i < BlurSamples; i++) {
		float t = (i + 0.5f) / BlurSamples - 0.5f;
		float2 lookup = uv + velocity * t;
		float weight = 1.0f - abs(t);   // a little more of the middle of the trail
		float viewModel = IsViewModel(lookup);
		weaponColor += tex2Dlod(TESR_RenderedBuffer, float4(lookup, 0, 0)).rgb * weight * viewModel;
		weaponSum += weight * viewModel;
		total += weight;
	}
	// Over the world, as much of the blurred weapon as its samples cover: a trail that fades out at its ends.
	float coverage = weaponSum / total;
	float3 weapon = weaponSum > 0 ? weaponColor / weaponSum : sharp;
	return float4(lerp(sharp, weapon, coverage), 1);
}

float4 MotionBlurPS(VSOUT IN) : COLOR0
{
	[branch] if (TESR_MotionBlurParams.w > 2.5f) return WeaponMotionPS(IN.UVCoord);

    float2 offsetBlurDirection;
    float3 blurredColor = 0;
	float gaussianSum = 0;
	// Weapon and world samples summed apart, for the modes that blur one of them only.
	float3 weaponColor = 0, worldColor = 0;
	float weaponSum = 0, worldSum = 0;
	float mode = TESR_MotionBlurParams.w;

    offsetBlurDirection.x = clamp(TESR_MotionBlurData.x, -TESR_MotionBlurParams.z, TESR_MotionBlurParams.z);
    offsetBlurDirection.y = clamp(TESR_MotionBlurData.y, -TESR_MotionBlurParams.z, TESR_MotionBlurParams.z);

    for(int i = 0; i < BlurSamples / 2; i++)
    {
        float2 lookup;
        float4 offsetColor;
        float weight = exp((i*i) / (5.0 * TESR_MotionBlurParams.x * TESR_MotionBlurParams.x)) / TESR_MotionBlurParams.x;
        float viewModel;

        lookup = offsetBlurDirection * TESR_ReciprocalResolution.xy * TESR_MotionBlurParams.y;
        lookup = lookup * i / BlurSamples + IN.UVCoord;
        offsetColor = tex2Dlod(TESR_RenderedBuffer, float4(lookup, 0, 0));
        gaussianSum += weight;
        blurredColor += (offsetColor.rgb * weight);
        viewModel = IsViewModel(lookup);
        weaponColor += offsetColor.rgb * weight * viewModel;  weaponSum += weight * viewModel;
        worldColor += offsetColor.rgb * weight * (1 - viewModel);  worldSum += weight * (1 - viewModel);

        lookup = -offsetBlurDirection * TESR_ReciprocalResolution.xy * TESR_MotionBlurParams.y;
        lookup = lookup * i / BlurSamples + IN.UVCoord;
        offsetColor = tex2Dlod(TESR_RenderedBuffer, float4(lookup, 0, 0));
        gaussianSum += weight;
        blurredColor += (offsetColor.rgb * weight);
        viewModel = IsViewModel(lookup);
        weaponColor += offsetColor.rgb * weight * viewModel;  weaponSum += weight * viewModel;
        worldColor += offsetColor.rgb * weight * (1 - viewModel);  worldSum += weight * (1 - viewModel);
    }

	blurredColor = blurredColor / gaussianSum;
	[branch] if (mode < 0.5f) return float4(blurredColor, 1);

	float3 sharp = tex2D(TESR_RenderedBuffer, IN.UVCoord).rgb;
	if (mode < 1.5f) {
		// The weapon only: its own samples blurred, nothing of the world in them; over the world, as much of the
		// blurred weapon as its samples cover, a trail that fades away from its edges.
		float coverage = weaponSum / gaussianSum;
		float3 weapon = weaponSum > 0 ? weaponColor / weaponSum : sharp;
		return float4(lerp(sharp, weapon, coverage), 1);
	}
	// All but the weapon: the weapon stays sharp, the world blurs from world samples only (no weapon smeared over it).
	if (IsViewModel(IN.UVCoord) > 0) return float4(sharp, 1);
	return float4(worldSum > 0 ? worldColor / worldSum : sharp, 1);
}

technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 MotionBlurPS();
	}
 
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 MotionBlurPS();
	}
}
