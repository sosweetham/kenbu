// A light of a map's own geometry that adds onto what lies behind it and vanishes when off:
// Chroma's TransparentLight, and BillieWater with `streak` (light falling in streaks).
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled;

#include "res://game/chroma/far.gdshaderinc"

instance uniform vec4 light : source_color = vec4(0.0);
uniform float streak = 0.0;

void vertex() {
	POSITION = far_clip(PROJECTION_MATRIX, MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	DEPTH = far_depth(PROJECTION_MATRIX, -VERTEX.z);
	float fall = 1.0;
	if (streak > 0.0) {
		float lane = fract(sin(floor(UV.x * 48.0) * 91.7) * 43758.5453);
		fall = mix(1.0, 0.35 + 0.65 * fract(UV.y * (1.0 + lane) + TIME * (0.6 + lane)), streak);
	}
	ALBEDO = light.rgb * light.a * fall;
}
