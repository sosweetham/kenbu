// One bar of light per MultiMesh instance (the ground's lights, standing beside the runway): a
// bright core line with a soft glow either side, fading at its ends. The instance colour (COLOR) is
// its light: rgb hue, a brightness; the hue is linearised as a `source_color` uniform would be
// (beam.gdshader). UV.x runs along the strip, UV.y across it.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, depth_draw_never, cull_disabled;

void vertex() {
	COLOR.rgb = mix(COLOR.rgb / 12.92, pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), COLOR.rgb));
}

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float core = 1.0 - smoothstep(0.15, 0.3, across);
	float glow = exp(-across * 4.0) * 0.4;
	float ends = smoothstep(0.0, 0.05, UV.x) * smoothstep(1.0, 0.95, UV.x);
	ALBEDO = COLOR.rgb * COLOR.a * (core * 2.2 + glow);
	ALPHA = ends;
}
