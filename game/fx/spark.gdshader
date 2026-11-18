// A spark or a slash of light: a streak that is brightest along its middle, coloured per instance.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

void fragment() {
	vec2 q = abs(UV * 2.0 - 1.0);
	float a = (1.0 - q.x) * (1.0 - q.y * q.y);
	ALBEDO = COLOR.rgb * 1.6;
	ALPHA = a * a * COLOR.a;
}
