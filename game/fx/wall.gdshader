// A wall: glass that glows towards its edges, drawn on a unit cube scaled to the wall's size. The
// edge lines keep their width in metres whatever the scale; `edges` 0 leaves them out (a custom
// wall's overlay with its frame hidden, game/wall_view.gd). A Chroma map's colour for this wall
// (`chroma`, alpha 0 for none) replaces `tint`, its edges glowing by `chroma_glow` (the colour's
// alpha, which is a wall's glow in the original game). A Noodle Extensions `dissolve` fades it (0 is
// gone).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform vec4 tint : source_color = vec4(1.0);
uniform float edges = 1.0;
instance uniform vec4 chroma : source_color = vec4(0.0);
instance uniform float chroma_glow = 1.0;
instance uniform float dissolve = 1.0;

varying vec3 local;
varying vec3 size;

void vertex() {
	local = VERTEX;
	size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
}

void fragment() {
	vec3 d = (0.5 - abs(local)) * size;
	float nearest = min(d.x, min(d.y, d.z));
	float farthest = max(d.x, max(d.y, d.z));
	// On a face the nearest distance is to the face itself; the next is to the face's edge.
	float to_edge = d.x + d.y + d.z - nearest - farthest;
	float width = max(0.009, fwidth(to_edge) * 1.2);
	float edge = (1.0 - smoothstep(width * 0.5, width, to_edge)) * edges;
	float inner = exp(-to_edge * 4.0);
	vec3 m = local * size;
	float hatch = smoothstep(0.9, 1.0, sin((m.x + m.y - m.z) * 7.0 + TIME * 1.5) * 0.5 + 0.5);
	vec3 base = chroma.a > 0.0 ? chroma.rgb : tint.rgb;
	float glow = chroma.a > 0.0 ? chroma_glow : 1.0;
	ALBEDO = mix(base, vec3(1.0), edge * 0.2) * (1.0 + edge * 0.4);
	ALPHA = (0.025 + inner * 0.11 + hatch * 0.03 + edge * 0.7 * glow) * dissolve;
}
