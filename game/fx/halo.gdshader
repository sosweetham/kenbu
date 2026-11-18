// A soft glow around a blade: brightest where the shell faces the eye, gone at its silhouette.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;

uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = tint.rgb;
	ALPHA = facing * facing * facing * tint.a;
}
