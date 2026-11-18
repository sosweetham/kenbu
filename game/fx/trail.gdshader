// A blade's trail: a ribbon through the recent poses of the blade's outer half, newest first. Each mesh vertex only
// says which pose it belongs to (VERTEX.x) and where along the blade it sits (VERTEX.y, 0 at the
// base); `bases` and `tips` hold the poses in world space with their song time in w.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

const int SAMPLES = 20;

uniform vec4 bases[SAMPLES];
uniform vec4 tips[SAMPLES];
uniform vec4 tint : source_color = vec4(1.0);
uniform float now = 0.0;
uniform float life = 0.14;

varying float age;
varying float along;

void vertex() {
	int i = int(VERTEX.x + 0.5);
	along = VERTEX.y;
	age = clamp((now - bases[i].w) / life, 0.0, 1.0);
	VERTEX = (VIEW_MATRIX * vec4(mix(bases[i].xyz, tips[i].xyz, along), 1.0)).xyz;
}

void fragment() {
	float fade = 1.0 - age;
	ALBEDO = tint.rgb;
	float outer = smoothstep(0.45, 1.0, along);
	ALPHA = fade * fade * outer * outer * tint.a;
}
