// The eclipsed moon over the horizon and the halo around it: a dark disc with a bright rim and a
// corona that swells with the bass, inside three broken arcs that turn and widen with the map's
// spin and zoom triggers.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_premul_alpha, depth_draw_never, cull_disabled;

uniform vec4 halo : source_color = vec4(0.0);
uniform vec3 disc : source_color = vec3(0.004, 0.005, 0.012);
uniform vec3 turn = vec3(0.0);
uniform float zoom = 1.0;
uniform float bass = 0.0;
uniform float pulse = 0.0;
// 0 while the halo's rings are drawn one by one instead (game/env/halo.gdshader).
uniform float arcs = 1.0;
// 1 on a moon a Chroma map places (game/chroma/stage.gd): drawn however far, as the map's geometry is.
instance uniform float far = 0.0;

#include "res://game/chroma/far.gdshaderinc"

const float RADIUS = 0.24;
const vec3 ARC_RADIUS = vec3(0.37, 0.48, 0.6);
const vec3 ARC_COUNT = vec3(3.0, 5.0, 8.0);

void vertex() {
	vec4 view_vertex = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION = far > 0.5 ? far_clip(PROJECTION_MATRIX, view_vertex) : PROJECTION_MATRIX * view_vertex;
}

void fragment() {
	DEPTH = far > 0.5 ? far_depth(PROJECTION_MATRIX, -VERTEX.z) : FRAGCOORD.z;
	vec2 q = (UV - 0.5) * 2.0;
	float r = length(q);
	float angle = atan(q.y, q.x);
	float edge = fwidth(r);
	float inside = 1.0 - smoothstep(RADIUS - edge, RADIUS + edge, r);
	float rim = exp(-abs(r - RADIUS) * 70.0);
	float corona = exp(-max(r - RADIUS, 0.0) * (11.0 - 5.0 * bass)) * (1.0 - inside);
	float crescent = 0.55 + 0.45 * cos(angle - 2.2);
	vec3 light = halo.rgb * halo.a;
	vec3 col = light * (rim * 1.8 * crescent + corona * (0.45 + 0.3 * pulse));
	for (int k = 0; k < 3; k++) {
		float radius = ARC_RADIUS[k] * zoom;
		float width = 0.006 + edge;
		float band = 1.0 - smoothstep(width * 0.5, width, abs(r - radius));
		float gap = smoothstep(-0.1, 0.1, sin(angle * ARC_COUNT[k] + turn[k]));
		col += light * band * gap * (1.3 - 0.25 * float(k)) * arcs;
	}
	col *= 1.0 - smoothstep(0.9, 1.0, r);
	ALBEDO = disc * inside + col;
	ALPHA = inside;
}
