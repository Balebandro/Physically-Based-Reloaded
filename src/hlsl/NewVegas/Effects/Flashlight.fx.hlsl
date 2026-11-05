// UNOFFICIAL 2026-11-05 (ported from Vegas Shaders; user: "get rid of the old code regarding flashlight, including flashlight beam"): the
// flashlight is no screen-space effect any more. The light is the deferred spot light (core/FlashlightDeferred.h,
// Shaders\FlashlightDeferred.hlsl); FlashlightEffect only places and colours it each frame. This file stays only so the effect loads (the
// effect framework counts an effect on when its .fx loaded) and keeps its menu switch: it is never drawn (FlashlightEffect::ShouldRender).

struct VSOUT { float4 vertPos : POSITION; };

VSOUT FrameVS(float4 vertPos : POSITION0) {
	VSOUT OUT;
	OUT.vertPos = vertPos;
	return OUT;
}

float4 Nothing(VSOUT IN) : COLOR0 { return 0.0f; }

technique
{
	pass
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader  = compile ps_3_0 Nothing();
	}
}
