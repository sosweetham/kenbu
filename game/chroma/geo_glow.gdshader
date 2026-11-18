// A flat, unlit, unfogged surface of a map's own geometry: Chroma's Glowing material, and what it
// turns Standard and BTSPillar into when their keyword list is empty. Alpha is how much it glows.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;

#include "res://game/chroma/far.gdshaderinc"

uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform float glow = 1.5;

void vertex() {
	POSITION = far_clip(PROJECTION_MATRIX, MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	DEPTH = far_depth(PROJECTION_MATRIX, -VERTEX.z);
	ALBEDO = color.rgb * (1.0 + clamp(color.a, 0.0, 4.0) * glow);
}
